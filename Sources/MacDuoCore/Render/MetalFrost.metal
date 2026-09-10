//
//  MetalFrost.metal
//  MacDuo
//
//  The picture stays where it would be at 90°: a flat panel hinged along the
//  bottom edge of the display, tipped away from the viewer. Seen head-on it is a
//  trapezoid — full width at the hinge, narrower at the top, sides slanting
//  straight in, rows drawn together as they recede.
//
//  The fold is geometry: the quad is drawn as the trapezoid and the picture
//  coordinates are squeezed to match, so the picture itself is *clipped*, never
//  rescaled. Everything the panel no longer covers shows the surface behind it.
//
//  On top of that geometry the frost is deepest where the panel is furthest
//  away, so it is heaviest along the top edge and thinnest down at the hinge.
//

#include <metal_stdlib>
using namespace metal;

struct FrostVertexOut {
    float4 position [[position]];
    float2 uv;              // picture coordinates (may fall outside 0...1)
    float  ramped;          // 0 at the hinge, 1 at the top: frost strength ramp
};

// Layout is 16-byte clean in both languages. Keep the Swift twin in
// MetalFrostRenderer.swift in sync — a mismatch here shifts every uniform.
struct FrostUniforms {
    // Target geometry
    float4 targetSize;      // xy = render target size in pixels, zw = reciprocals

    // Fold geometry
    //   v     = 0 at the hinge row (bottom), 1 at the top
    //   scale = 1 + v * fold      width of the panel at that row
    float  fold;
    float  fold2;           // fold * fold (reserved)
    float2 displaySize;     // display size in pixels

    // Frost ramp: ramp = smoothstep(nearClear, 1, v), then
    //   ramp_curved = 1 - (1 - ramp)^(1 + blurSoftness * 2)
    float  nearClear;       // fraction of the panel kept clear at the hinge
    float  blurSoftness;    // 0 = crisp stacked levels, 1 = one smooth ramp
    float  frostOpacity;    // milky wash strength
    float  saturation;      // colour kept in the frosted area

    // More look
    float  dim;             // luminance pull-down in the frosted area
    float  globalMix;       // overall strength
    float  backgroundDim;   // how dark the surface behind the panel is
    float  pad0;

    // Blur radii of the three stacked levels, in pixels
    float  radius0;
    float  radius1;
    float  radius2;
    float  geometryDebug;   // 1 = output the panel coverage mask, not colour
};

// MARK: - Helpers

static inline float luminance(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

// MARK: - Vertex

/// Folds the screen rectangle into the panel trapezoid and hands the fragment
/// stage the matching picture coordinates.
///
/// Corner 0 is the top-left, then top-right, bottom-left, bottom-right, matching
/// a triangle strip. Metal's texture space has (0,0) at the top-left with y
/// growing downwards; `t` below is 0 at the bottom edge and 1 at the top so the
/// fold reads the same way it does in the world.
vertex FrostVertexOut frost_vertex(uint vertexID [[vertex_id]],
                                   constant FrostUniforms &u [[buffer(0)]]) {
    const float2 corners[4] = {
        float2(-1.0, -1.0),   // 0 top-left
        float2( 1.0, -1.0),   // 1 top-right
        float2(-1.0,  1.0),   // 2 bottom-left
        float2( 1.0,  1.0),   // 3 bottom-right
    };
    float2 corner = corners[vertexID];

    // Height on the screen: 0 at the hinge (bottom edge), 1 at the top.
    float t = (corner.y + 1.0) * 0.5;

    // How wide the panel is at this height, as a fraction of the screen.
    //
    // The panel keeps its full width at the hinge and loses `fold` of it at the
    // top, so the flat picture has to be drawn wider than the screen up at the
    // hinge and narrower than it at the top. Drawing it that way and mapping the
    // picture 0...1 across the quad is what makes the sides read as *clipped*
    // rather than squashed.
    float scale = (1.0 + u.fold * (1.0 - t)) / (1.0 + u.fold);

    FrostVertexOut out;
    out.position = float4(corner.x * scale, corner.y, 0.0, 1.0);

    // Picture coordinates: the whole picture across the quad, laid down so the
    // top-left corner of the quad is the top-left of the picture.
    out.uv = float2((corner.x + 1.0) * 0.5 * scale, (corner.y + 1.0) * 0.5);

    // Frost ramp: 0 at the hinge, 1 at the top, softened towards the hinge.
    float width = max(1.0 - u.nearClear, 0.05);
    float ramp = clamp((t - u.nearClear) / width, 0.0, 1.0);
    ramp = ramp * ramp * (3.0 - 2.0 * ramp);
    out.ramped = ramp;

    return out;
}

/// Plain full-screen quad, used by the blur passes: they work on the screen's
/// own pixel grid and must not see the fold at all.
vertex FrostVertexOut frost_vertex_flat(uint vertexID [[vertex_id]]) {
    const float2 corners[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0),
    };
    float2 corner = corners[vertexID];

    FrostVertexOut out;
    out.position = float4(corner, 0.0, 1.0);
    out.uv = float2((corner.x + 1.0) * 0.5, (corner.y + 1.0) * 0.5);
    out.ramped = 0.0;
    return out;
}

// MARK: - Downscale

// Downscaling through a quad (instead of a blit) lets the rasteriser do the
// averaging, which removes high-frequency detail before the big Gaussian passes
// and keeps the wide blur cheap.
fragment float4 frost_downscale(FrostVertexOut in [[stage_in]],
                                texture2d<float> source [[texture(0)]]) {
    constexpr sampler linearSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    return float4(source.sample(linearSampler, in.uv).rgb, 1.0);
}

// MARK: - Composite

fragment float4 frost_fragment(FrostVertexOut in [[stage_in]],
                               constant FrostUniforms &u [[buffer(0)]],
                               texture2d<float> sharp [[texture(0)]],
                               texture2d<float> blur1 [[texture(1)]],
                               texture2d<float> blur2 [[texture(2)]],
                               texture2d<float> blur3 [[texture(3)]]) {
    // Clamped taps outside the picture give the screen's own edge colours, which
    // is the nearest thing to the surface behind the panel we can know about.
    constexpr sampler linearSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;

    // Does the panel still cover this pixel? The fold leaves the upper corners
    // and the area above the panel empty.
    bool outside = uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0;

    float2 sampleUV = clamp(uv, float2(0.0), float2(1.0));
    float3 dim = float3(u.backgroundDim);

    // Verification hooks. Both bypass the frost so the fold and the blur can be
    // measured independently of each other.
    if (u.geometryDebug > 2.5) {
        // Coverage mask: the panel's footprint, nothing else.
        return float4(outside ? float3(0.0) : float3(1.0), 1.0);
    }
    if (u.geometryDebug > 1.5) {
        // Fold applied, sharp picture only — no blur anywhere. Comparing this
        // with the frosted render isolates what the frost removed.
        float3 sample = sharp.sample(linearSampler, sampleUV).rgb;
        return float4(outside ? sample * dim : sample, 1.0);
    }
    if (u.geometryDebug > 0.5) {
        // Fold applied, but the sharp picture only — no blur at all.
        return float4(sharp.sample(linearSampler, sampleUV).rgb * (outside ? dim : float3(1.0)), 1.0);
    }

    // Blur ramp: heaviest at the top, thinning out towards the hinge.
    float ramp = in.ramped;

    float3 color = sharp.sample(linearSampler, sampleUV).rgb;
    if (outside) { color *= dim; }

    // Stacked levels, each taking over further up the ramp. Low blurSoftness
    // keeps the steps crisp (layered glass); high melts them into one ramp.
    float curve = 1.0 + u.blurSoftness * 2.0;
    float curved = 1.0 - pow(max(1.0 - ramp, 0.0), curve);

    float w1 = smoothstep(0.18, 0.18 + u.blurSoftness * 0.45 + 0.03, curved);
    float w2 = smoothstep(0.50, 0.50 + u.blurSoftness * 0.45 + 0.03, curved);
    float w3 = smoothstep(0.82, 0.82 + u.blurSoftness * 0.16 + 0.02, curved);

    float3 level;
    if (w1 > 0.0) {
        level = blur1.sample(linearSampler, sampleUV).rgb;
        color = mix(color, outside ? level * dim : level, w1);
    }
    if (w2 > 0.0) {
        level = blur2.sample(linearSampler, sampleUV).rgb;
        color = mix(color, outside ? level * dim : level, w2);
    }
    if (w3 > 0.0) {
        level = blur3.sample(linearSampler, sampleUV).rgb;
        color = mix(color, outside ? level * dim : level, w3);
    }

    // Frosted-glass wash: desaturate, lift towards white, pull luminance down,
    // all masked by the same ramp.
    float luma = luminance(color);
    float3 desaturated = mix(float3(luma), color, clamp(u.saturation, 0.0, 1.0));
    float3 frosted = mix(desaturated, float3(1.0), clamp(u.frostOpacity, 0.0, 1.0));
    frosted *= (1.0 - clamp(u.dim, 0.0, 1.0));

    float frostMask = smoothstep(0.0, 0.85, ramp);
    float3 result = mix(color, frosted, frostMask * u.globalMix);

    // Keep the reserved slots live so the packed layout stays honest.
    result *= 1.0 + 0.0 * (u.fold2 + u.pad0 + u.radius0 + u.radius1 + u.radius2
                           + u.displaySize.x + u.targetSize.x);

    return float4(result, 1.0);
}
