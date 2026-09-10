//
//  MetalFrost.metal
//  MacDuo
//
//  A port of the screen shader in https://github.com/chuspeeism/iphone-duo
//  (main.js, `screenShader`) to a laptop lid, geometry included.
//
//  His construction, in his order, with his constants:
//
//    progress        fold amount, 0 = flat, 1 = shut       -> the lid angle
//    foldAngle       progress * pi/2
//    screenColor()   fixed front-view projection: the ray from the eye through
//                    the fragment meets the *unfolded* screen plane, and the
//                    picture is read there — so content on a folded panel is
//                    foreshortened the way a real panel is.
//    edge            0 at the hinge, 1 at the far edge, measured on the panel
//    motion          smoothstep(0, 1, progress)
//    blurGradient    clamp(edge, 0, 1)
//    darkenGradient  clamp((edge - 0.2) / 0.8, 0, 1)
//    radius          72 * motion * pow(blurGradient, 1.35)          [source px]
//    effect          motion * pow(darkenGradient, 1.35)
//    color          *= 1 - min(1, effect * 2)
//    blur            5x5 taps, weights 1:4:6:4:1 (normalised by 256), spacing =
//                    radius, each tap read from mip level max(baseLod, log2(radius))
//                    and pre-multiplied by how much of the panel it is on, so
//                    colour dissolves into the margin past the panel's edge.
//
//  Three things differ, because this is a laptop whose screen *is* the display
//  rather than a 3D model of a folding phone:
//
//    1. his fold axis is the phone's vertical book hinge and he has two screens
//       (inner and outer); a MacBook hinges along the bottom edge and has one
//       screen, so the panel tips away about the display's bottom edge and
//       `edge` runs bottom (hinge) -> top (far edge);
//    2. `progress` comes from the lid-angle sensor instead of a slider;
//    3. his margin is a black border inside his image; here the picture fills
//       the display, so only the panel's far edge dissolves into black — the
//       display's own left, right and bottom edges clamp instead.
//

#include <metal_stdlib>
using namespace metal;

struct FrostVertexOut {
    float4 position [[position]];
    float2 uv;              // picture coordinates: (0,0) is the picture's top-left
};

// Layout is three 16-byte rows in both languages. Keep the Swift twin in
// MetalFrostRenderer.swift in sync — a mismatch here shifts every uniform.
struct FrostUniforms {
    // Picture geometry
    float2 pictureSize;     // captured picture size in pixels
    float  progress;        // 0 = standing at 90°, 1 = fully folded
    float  blurRadiusPx;    // strongest blur radius, in picture pixels

    // Ramp
    float  falloff;         // exponent of the ramp; 1.35 in the reference
    float  hingeClear;      // fraction of the panel at the hinge kept clear
    float  darkenStart;     // where the shadow begins along the ramp; 0.2 there
    float  darkenGain;      // shadow strength; 2.0 there

    // Glass
    float  frostOpacity;    // milky wash, 0...1 (0 = the reference's look)
    float  frostSaturation; // colour kept, 0...1 (1 = the reference's look)

    // The viewer, in units of screen heights — his `uiReferenceEye` sits 40 units
    // away from a screen about 11 units tall, so D is about 3.6.
    float  eyeDistance;     // viewing distance
    float  eyeHeight;       // height of the eye above the hinge
};

// MARK: - Vertex

/// A plain full-screen quad. Metal's NDC has y = +1 at the top of the target,
/// and the picture's own first row is its top, so `uv.y` is flipped here and
/// nowhere else: uv = (0,0) is the picture's top-left no matter what.
vertex FrostVertexOut frost_vertex(uint vertexID [[vertex_id]]) {
    const float2 corners[4] = {
        float2(-1.0, -1.0),   // bottom-left
        float2( 1.0, -1.0),   // bottom-right
        float2(-1.0,  1.0),   // top-left
        float2( 1.0,  1.0),   // top-right
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
    float motion = smoothstep(0.0, 1.0, progress);
    float exponent = max(u.falloff, 0.05);

    float phi = progress * 1.5707963268;          // 0 = at 90°, pi/2 = shut
    float sinPhi = sin(phi);
    float cosPhi = cos(phi);

    // Height on the *display* above the hinge: 0 at the bottom edge, 1 at the
    // top. Everything below is in these units, so `panelDistance` is directly
    // the panel coordinate the reference calls `edge`.
    float screenUp = 1.0 - uv.y;

    // His fixed front-view projection, inverted: the ray from the eye through
    // this pixel meets the tipped panel at
    //
    //     h = D * s / (D * cos(phi) + (E - s) * sin(phi))
    //
    // which is exactly `s` while the lid stands at 90° — the picture then passes
    // through pixel for pixel — and grows past 1 as the lid folds, so the picture
    // is foreshortened towards the hinge and what lies past the panel's far edge
    // is whatever is behind the lid.
    float denominator = max(u.eyeDistance * cosPhi + (u.eyeHeight - screenUp) * sinPhi, 1e-5);
    float panelDistance = u.eyeDistance * screenUp / denominator;

    // The panel's far edge, feathered by half a screen pixel's worth of panel and
    // scaled by the fold, so a lid standing at 90° has no edge to antialias and
    // stays exact to the last pixel.
    float panelAA = 0.5 * max(fwidth(panelDistance), 1e-6) * smoothstep(0.0, 0.05, progress);
    float onPanel = 1.0 - smoothstep(1.0 - panelAA, 1.0 + panelAA, panelDistance);
    if (onPanel <= 0.0) {
        // Behind the lid.
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    // The picture lives on the panel, so its coordinates follow the panel: the
    // hinge keeps the picture's own bottom edge.
    float2 pictureUV = float2(uv.x, 1.0 - panelDistance);

    float edge = clamp((panelDistance - u.hingeClear) / max(1.0 - u.hingeClear, 1e-4), 0.0, 1.0);
    float blurGradient = clamp(edge, 0.0, 1.0);
    float darkenGradient = clamp((edge - u.darkenStart) / max(1.0 - u.darkenStart, 1e-4), 0.0, 1.0);

    float effect = motion * pow(darkenGradient, exponent);
    float radius = max(u.blurRadiusPx, 0.0) * motion * pow(blurGradient, exponent);

    // His `baseLod`: how many picture texels one screen pixel covers. A tap must
    // never be finer than the input can resolve — and the fold minifies the
    // picture towards the hinge, which this picks up for free.
    float2 texel = 1.0 / max(u.pictureSize, float2(1.0));
    float2 duvdx = dfdx(pictureUV);
    float2 duvdy = dfdy(pictureUV);
    float baseLod = log2(max(1.0, max(length(duvdx * u.pictureSize),
                                      length(duvdy * u.pictureSize))));

    float3 color;
    if (radius < 0.35) {
        // Hinge side, and the whole screen while the lid stands at 90°: mip level
        // 0, explicitly — an implicit level would blend in the prefiltered chain
        // and soften the one part of the picture that has to stay exact.
        color = picture.sample(linearSampler, pictureUV, level(0.0)).rgb;
    } else {
        float maxLod = floor(log2(max(max(u.pictureSize.x, u.pictureSize.y), 2.0)));
        float lod = clamp(max(baseLod, log2(max(radius, 1.0))), 0.0, maxLod);
        float2 spacing = radius * texel;
        // How far a tap spreads, in picture coordinates: the screen pixel's own
        // footprint, or the tap's radius, whichever is larger. Both have to be
        // in uv units — the coverage below is compared against a uv value.
        float footprint = max(0.5 * abs(duvdy.y), radius * 0.75 * texel.y);

        float3 sum = float3(0.0);
        for (int y = -2; y <= 2; ++y) {
            for (int x = -2; x <= 2; ++x) {
                float wx = (x == 0) ? 6.0 : (abs(x) == 1 ? 4.0 : 1.0);
                float wy = (y == 0) ? 6.0 : (abs(y) == 1 ? 4.0 : 1.0);
                float2 tapUV = pictureUV + float2(float(x), float(y)) * spacing;
                // How much of the panel this tap is on: past the far edge the
                // picture gives way to the dark behind it, exactly as his taps
                // fade into his margin.
                float tapCoverage = 1.0 - smoothstep(1.0 - footprint, 1.0 + footprint,
                                                     1.0 - tapUV.y);
                sum += picture.sample(linearSampler, clamp(tapUV, float2(0.0), float2(1.0)),
                                      level(lod)).rgb * tapCoverage * (wx * wy);
            }
        }
        color = sum * (1.0 / 256.0);
    }

    // Darkening: his `color *= 1 - min(1, effect * 2)`, with the doubling folded
    // into `darkenGain` (2.0 is his value).
    color *= 1.0 - min(1.0, effect * u.darkenGain);

    // Optional frosting on top (both default to the reference's look: none).
    // Like everything else here it is masked by the fold, so the hinge — and the
    // whole picture while the lid stands at 90° — passes through untouched.
    float glass = motion * blurGradient;
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float saturation = mix(1.0, clamp(u.frostSaturation, 0.0, 1.0), clamp(glass, 0.0, 1.0));
    color = mix(float3(luma), color, saturation);
    color = mix(color, float3(1.0), clamp(u.frostOpacity * glass, 0.0, 1.0));

    return float4(color * onPanel, 1.0);
}
