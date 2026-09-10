//
//  EmbeddedShader.swift  —  GENERATED FILE, DO NOT EDIT
//
//  Produced by Tools/embed-shader.py from MetalFrost.metal so the shader can
//  be compiled at run time, without the optional Xcode Metal toolchain.
//

enum EmbeddedShader {
    static let source = """
//
//  MetalFrost.metal
//  MacDuo
//
//  One screenshot, stretched into a trapezoid, with a blur that is heaviest at
//  the far edge and gone at the hinge. Nothing else.
//
//  Geometry (vertex stage): the picture is drawn as a trapezoid whose *bottom*
//  edge is the bottom edge of the display and does not move. Only the top two
//  corners come in as the lid folds, so the picture narrows towards the far end
//  exactly like the inner screen of the folding reference; the picture is
//  stretched to fill that trapezoid rather than cropped. Whatever the trapezoid
//  does not cover is the space behind the lid, and the target is cleared to
//  black, so that is what shows there.
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

/// The trapezoid. Metal's NDC has y = +1 at the top of the target and the
/// picture's own first row is its top, so `uv.y` is flipped here and nowhere
/// else: uv = (0,0) is the picture's top-left no matter what.
vertex FrostVertexOut frost_vertex(uint vertexID [[vertex_id]],
                                   constant FrostUniforms &u [[buffer(0)]]) {
    const float2 corners[4] = {
        float2(-1.0, -1.0),   // bottom-left  (hinge, pinned to the screen edge)
        float2( 1.0, -1.0),   // bottom-right (hinge, pinned to the screen edge)
        float2(-1.0,  1.0),   // top-left     (comes in as the lid folds)
        float2( 1.0,  1.0),   // top-right    (comes in as the lid folds)
    };
    float2 corner = corners[vertexID];

    // 只有"远端"那一对顶点会动，另一条边钉死在屏幕边缘上。
    // anchor = 0：远端是顶端（盖子往下合，底边不动，这是需求里的那一种）。
    // anchor = 1：远端是底端（往后展开时镜像过来的那一种）。
    float towardFarEdge = u.anchor < 0.5 ? 1.0 : -1.0;
    float scale = (corner.y * towardFarEdge > 0.0) ? clamp(u.topScale, 0.02, 1.0) : 1.0;

    FrostVertexOut out;
    out.position = float4(corner.x * scale, corner.y, 0.0, 1.0);
    out.uv = float2((corner.x + 1.0) * 0.5, (1.0 - corner.y) * 0.5);
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

fragment float4 frost_fragment(FrostVertexOut in [[stage_in]],
                               constant FrostUniforms &u [[buffer(0)]],
                               texture2d<float> picture [[texture(0)]]) {
    constexpr sampler linearSampler(mag_filter::linear, min_filter::linear,
                                    mip_filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float progress = clamp(u.progress, 0.0, 1.0);

    // 渐变从"远端"开始：远端最糊，钉住的那条边完全不糊。
    float towardFarEdge = clamp(1.0 - uv.y, 0.0, 1.0);
    float alongRamp = u.anchor < 0.5 ? towardFarEdge : (1.0 - towardFarEdge);
    float ramp = pow(alongRamp, clamp(u.falloff, 0.05, 4.0));
    float radius = max(u.blurRadiusPx, 0.0) * progress * ramp;

    float3 color;
    if (radius < 0.35) {
        // Hinge side. Level 0 explicitly, so with the lid standing at 90° the
        // picture is passed through pixel for pixel.
        color = picture.sample(linearSampler, uv, level(0.0)).rgb;
    } else {
        float2 texel = 1.0 / max(u.pictureSize, float2(1.0));
        // Never sample finer than a screen pixel can resolve: without this the
        // wide kernel aliases into strips on high-frequency content.
        float baseLod = log2(max(1.0, max(length(dfdx(uv) * u.pictureSize),
                                          length(dfdy(uv) * u.pictureSize))));
        float maxLod = floor(log2(max(max(u.pictureSize.x, u.pictureSize.y), 2.0)));
        float lod = clamp(max(baseLod, log2(max(radius, 1.0))), 0.0, maxLod);
        float2 spacing = radius * texel;

        // Weights 1 : 4 : 6 : 4 : 1 in both axes, normalised by 256. Spacing the
        // taps by the radius turns that kernel into a Gaussian of about that
        // radius.
        float3 sum = float3(0.0);
        for (int y = -2; y <= 2; ++y) {
            for (int x = -2; x <= 2; ++x) {
                float wx = (x == 0) ? 6.0 : (abs(x) == 1 ? 4.0 : 1.0);
                float wy = (y == 0) ? 6.0 : (abs(y) == 1 ? 4.0 : 1.0);
                float2 tap = uv + float2(float(x), float(y)) * spacing;
                sum += picture.sample(linearSampler, tap, level(lod)).rgb * (wx * wy);
            }
        }
        color = sum * (1.0 / 256.0);
    }

    // Optional extentions, both off at their defaults.
    color *= 1.0 - min(1.0, progress * max(u.darkenGain, 0.0) * ramp);

    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float saturation = mix(1.0, clamp(u.frostSaturation, 0.0, 1.0), clamp(progress * ramp, 0.0, 1.0));
    color = mix(float3(luma), color, saturation);
    color = mix(color, float3(1.0), clamp(u.frostOpacity * progress * ramp, 0.0, 1.0));

    return float4(color, 1.0);
}
"""
}
