//
//  MetalFrost.metal
//  MacDuo
//
//  One screenshot, stretched into a trapezoid, with a blur that is heaviest at
//  the far edge and gone at the hinge. Nothing else.
//
//  Geometry (vertex stage): the picture is projected into a trapezoid whose
//  *bottom* edge is the bottom edge of the display and does not move. Only the
//  top two corners come in as the lid folds. The clip-space w values describe
//  one homography for the whole quad, like projecting a planar screen from a
//  fixed eye; this is deliberately not two affine triangle warps. The quad is
//  enlarged by the blur support so the picture edge can scatter into the black
//  around it instead of being clipped at the trapezoid boundary.
//
//  Blur (fragment stage): a radius that is the full amount at the top of the
//  picture, zero at the bottom (the hinge), shaped by an exponent, and scaled by
//  the fold — so the soft end deepens as the lid closes and sharpens back up as
//  it opens. The blur itself is a weighted 5x5 tap kernel whose spacing *is* the
//  radius, read from a generated mip chain, which keeps the radius continuous
//  from row to row instead of stepping between discrete blur levels.
//

#include <metal_stdlib>
using namespace metal;

struct FrostVertexOut {
    float4 position [[position]];
    float2 uv;              // picture coordinates: (0,0) is the picture's top-left
};

// Three 16-byte rows. Keep the Swift twin in MetalFrostRenderer.swift in sync —
// a mismatch here shifts every uniform.
struct FrostUniforms {
    float2 pictureSize;     // captured picture size in pixels
    float  progress;        // 0 = standing at 90°, 1 = fully folded
    float  blurRadiusPx;    // strongest blur radius (at the top, fully folded)

    float  falloff;         // shape of the top-to-bottom ramp
    float  darkenGain;      // extra darkening at the far end, 0 = off
    float  topScale;        // trapezoid: top edge width / bottom edge width
    float  frostOpacity;    // milky wash, 0 = off

    float  frostSaturation; // colour kept, 1 = untouched
    float  anchor;          // 0 = 底边不动（顶端是远端），1 = 顶端不动（底端是远端）
    float  pad1;
    float  pad2;
};

// MARK: - Vertex

/// The projective trapezoid. Metal's NDC has y = +1 at the top of the target
/// and the picture's own first row is its top, so `uv.y` is flipped here and
/// nowhere else: uv = (0,0) is the picture's top-left no matter what.
///
/// A tempting implementation is `position = float4(x * edgeScale, y, 0, 1)`.
/// That gets the outline right but makes the rasterizer interpolate the picture
/// independently and affinely in the quad's two triangles. It is not a planar
/// projection and leaves a derivative seam along their diagonal.
///
/// For a top width `s`, the homography from source NDC (x,y) to the trapezoid is
///
///     X = (1-|c|) x / (1+c y), Y = (y+c) / (1+c y)
///     c = (1-s) / (1+s)
///
/// Emitting its homogeneous numerator and denominator as clip position makes
/// Metal's perspective-correct varying interpolation recover the same mapping
/// for `uv`. Negating c mirrors it: top pinned, bottom narrow.
vertex FrostVertexOut frost_vertex(uint vertexID [[vertex_id]],
                                   constant FrostUniforms &u [[buffer(0)]]) {
    const float2 corners[4] = {
        float2(-1.0, -1.0),   // bottom-left  (hinge, pinned to the screen edge)
        float2( 1.0, -1.0),   // bottom-right (hinge, pinned to the screen edge)
        float2(-1.0,  1.0),   // top-left     (comes in as the lid folds)
        float2( 1.0,  1.0),   // top-right    (comes in as the lid folds)
    };
    float2 corner = corners[vertexID];

    float edgeScale = clamp(u.topScale, 0.02, 1.0);
    float c = (1.0 - edgeScale) / (1.0 + edgeScale);
    if (u.anchor >= 0.5) c = -c;

    // The reference blurs image colour and image coverage together. Give the
    // 5x5 kernel room to shade outside the original picture: its outer taps are
    // two radii away. This is overdraw only; coverage in the fragment stage
    // keeps everything beyond the scattered picture black.
    float motion = smoothstep(0.0, 1.0, clamp(u.progress, 0.0, 1.0));
    float support = 2.0 * max(u.blurRadiusPx, 0.0) * motion;
    float2 sourceExtent = 1.0 + 2.0 * support / max(u.pictureSize, float2(1.0));
    if (abs(c) > 0.0001) {
        // Keep every homogeneous denominator positive even at the UI sliders'
        // most extreme narrowing/blur combination.
        sourceExtent.y = min(sourceExtent.y, 0.98 / abs(c));
    }
    float2 sourceCorner = corner * sourceExtent;

    FrostVertexOut out;
    out.position = float4(sourceCorner.x * (1.0 - abs(c)),
                          sourceCorner.y + c,
                          0.0,
                          1.0 + c * sourceCorner.y);
    out.uv = float2((sourceCorner.x + 1.0) * 0.5,
                    (1.0 - sourceCorner.y) * 0.5);
    return out;
}

/// The same quad with no keystone at all, for the pass that fills the working
/// picture. The copy has to be 1:1: if it went through the trapezoid above, the
/// picture would be squeezed once on the way in and again on the way out.
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
    out.uv = float2((corner.x + 1.0) * 0.5, (1.0 - corner.y) * 0.5);
    return out;
}

// MARK: - Picture copy

/// Fills mip level 0 of the working picture from the captured frame.
///
/// The coordinate comes from `[[position]]` rather than the interpolated uv, so
/// this pass cannot flip or shift the picture even if the vertex mapping above
/// were wrong: fragment (x, y) reads texel (x, y).
fragment float4 frost_copy(FrostVertexOut in [[stage_in]],
                           constant FrostUniforms &u [[buffer(0)]],
                           texture2d<float> source [[texture(0)]]) {
    constexpr sampler linearSampler(mag_filter::linear, min_filter::linear,
                                    address::clamp_to_edge);
    float2 uv = in.position.xy / max(u.pictureSize, float2(1.0));
    return float4(source.sample(linearSampler, uv).rgb, 1.0);
}

// MARK: - Composite

static float pictureCoverage(float2 uv, float2 footprint) {
    float2 inside = smoothstep(-footprint, footprint, uv)
        * (1.0 - smoothstep(1.0 - footprint, 1.0 + footprint, uv));
    return inside.x * inside.y;
}

fragment float4 frost_fragment(FrostVertexOut in [[stage_in]],
                               constant FrostUniforms &u [[buffer(0)]],
                               texture2d<float> picture [[texture(0)]]) {
    constexpr sampler linearSampler(mag_filter::linear, min_filter::linear,
                                    mip_filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float progress = clamp(u.progress, 0.0, 1.0);
    float motion = smoothstep(0.0, 1.0, progress);

    // Keep the open state a literal pixel copy. Besides being cheaper, this
    // avoids applying edge coverage to the first/last captured pixel.
    if (motion <= 0.000001) {
        return float4(picture.sample(linearSampler, uv, level(0.0)).rgb, 1.0);
    }

    // 渐变从"远端"开始：远端最糊，钉住的那条边完全不糊。
    float towardFarEdge = clamp(1.0 - uv.y, 0.0, 1.0);
    float alongRamp = u.anchor < 0.5 ? towardFarEdge : (1.0 - towardFarEdge);
    float ramp = pow(alongRamp, clamp(u.falloff, 0.05, 4.0));
    float radius = max(u.blurRadiusPx, 0.0) * motion * ramp;
    float2 texel = 1.0 / max(u.pictureSize, float2(1.0));
    float2 aa = max(fwidth(uv), texel * 0.5);

    float3 color;
    if (radius < 0.35) {
        // Hinge side. Level 0 explicitly, so with the lid standing at 90° the
        // picture is passed through pixel for pixel.
        color = picture.sample(linearSampler, clamp(uv, 0.0, 1.0), level(0.0)).rgb
            * pictureCoverage(uv, aa);
    } else {
        // Never sample finer than a screen pixel can resolve: without this the
        // wide kernel aliases into strips on high-frequency content.
        float baseLod = log2(max(1.0, max(length(dfdx(uv) * u.pictureSize),
                                          length(dfdy(uv) * u.pictureSize))));
        float maxLod = floor(log2(max(max(u.pictureSize.x, u.pictureSize.y), 2.0)));
        float lod = clamp(max(baseLod, log2(max(radius, 1.0))), 0.0, maxLod);
        float2 spacing = radius * texel;
        float2 footprint = max(aa, texel * radius * 0.75);

        // Weights 1 : 4 : 6 : 4 : 1 in both axes, normalised by 256. Spacing the
        // taps by the radius turns that kernel into a Gaussian of about that
        // radius.
        float3 sum = float3(0.0);
        for (int y = -2; y <= 2; ++y) {
            for (int x = -2; x <= 2; ++x) {
                float wx = (x == 0) ? 6.0 : (abs(x) == 1 ? 4.0 : 1.0);
                float wy = (y == 0) ? 6.0 : (abs(y) == 1 ? 4.0 : 1.0);
                float2 tap = uv + float2(float(x), float(y)) * spacing;
                float coverage = pictureCoverage(tap, footprint);
                sum += picture.sample(linearSampler, clamp(tap, 0.0, 1.0), level(lod)).rgb
                    * coverage * (wx * wy);
            }
        }
        color = sum * (1.0 / 256.0);
    }

    // Match the reference's delayed darkening: the first fifth stays bright,
    // then the far edge falls off faster than the blur itself.
    float darkenGradient = clamp((alongRamp - 0.2) / 0.8, 0.0, 1.0);
    float darken = motion * max(u.darkenGain, 0.0) * pow(darkenGradient, 1.35);
    color *= 1.0 - min(1.0, darken);

    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float saturation = mix(1.0, clamp(u.frostSaturation, 0.0, 1.0), clamp(motion * ramp, 0.0, 1.0));
    color = mix(float3(luma), color, saturation);
    color = mix(color, float3(1.0), clamp(u.frostOpacity * motion * ramp, 0.0, 1.0));

    return float4(color, 1.0);
}
