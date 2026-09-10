//
//  MipLodProbe.swift
//  MacDuo (standalone experiment, not part of any build target)
//
//  Run with:  swift Tools/MipLodProbe.swift
//
//  Answers one question: does `sample(sampler, uv, level(lod))` with
//  mip_filter::linear blend between the two neighbouring mip levels, or does it
//  snap to the nearest one? The progressive blur picks its prefilter level that
//  way (level = log2(radius)), and the answer decides whether the blur radius
//  can vary continuously or has to be snapped to powers of two.
//
//  Measured on an M1 Pro: level 0 black, level 1 white, lod 0.25 / 0.5 / 0.75
//  reads back 64 / 128 / 191 — trilinear, so the ramp is smooth.
//

import Foundation
import Metal

let src = """
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 position [[position]]; };

vertex VOut v_main(uint vid [[vertex_id]]) {
    const float2 c[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    VOut o; o.position = float4(c[vid], 0, 1); return o;
}

fragment float4 f_main(VOut in [[stage_in]],
                       constant float &lod [[buffer(0)]],
                       texture2d<float> source [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        mip_filter::linear, address::clamp_to_edge);
    float value = source.sample(s, float2(0.5, 0.5), level(lod)).r;
    return float4(value, value, value, 1.0);
}
"""

guard let device = MTLCreateSystemDefaultDevice() else { print("no device"); exit(1) }
let lib = try! device.makeLibrary(source: src, options: nil)
let queue = device.makeCommandQueue()!

let pipelineDescriptor = MTLRenderPipelineDescriptor()
pipelineDescriptor.vertexFunction = lib.makeFunction(name: "v_main")
pipelineDescriptor.fragmentFunction = lib.makeFunction(name: "f_main")
pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
let pipeline = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)

// 64x64 mipmapped source: level 0 black, level 1 white (level 2+ generated is
// irrelevant because the sampler is asked for levels around 0.5).
let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: true)
sourceDescriptor.usage = [.shaderRead, .renderTarget]
sourceDescriptor.storageMode = .shared
let source = device.makeTexture(descriptor: sourceDescriptor)!

let black = [UInt8](repeating: 0, count: 64 * 64 * 4)
let white = [UInt8](repeating: 255, count: 32 * 32 * 4)
source.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0,
               withBytes: black, bytesPerRow: 64 * 4)
source.replace(region: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 1,
               withBytes: white, bytesPerRow: 32 * 4)
// Lower levels: keep them mid grey so a "snap" to level 2 would also be visible.
for level in 2..<source.mipmapLevelCount {
    let size = 64 >> level
    let grey = [UInt8](repeating: 128, count: size * size * 4)
    source.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: level,
                   withBytes: grey, bytesPerRow: size * 4)
}

let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: 4, height: 1, mipmapped: false)
targetDescriptor.usage = [.renderTarget, .shaderRead]
targetDescriptor.storageMode = .shared
let target = device.makeTexture(descriptor: targetDescriptor)!

let lods: [Float] = [0.0, 0.25, 0.5, 0.75]
for (index, lod) in lods.enumerated() {
    var value = lod
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = index == 0 ? .clear : .load
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    pass.renderTargetWidth = 4
    pass.renderTargetHeight = 1

    let buffer = queue.makeCommandBuffer()!
    let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)!
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBytes(&value, length: MemoryLayout<Float>.size, index: 0)
    encoder.setFragmentBytes(&value, length: MemoryLayout<Float>.size, index: 0)
    encoder.setFragmentTexture(source, index: 0)
    encoder.setViewport(MTLViewport(originX: Double(index), originY: 0, width: 1, height: 1,
                                    znear: 0, zfar: 1))
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encoder.endEncoding()
    buffer.commit()
    buffer.waitUntilCompleted()
}

var pixels = [UInt8](repeating: 0, count: 4 * 4)
target.getBytes(&pixels, bytesPerRow: 4 * 4,
                from: MTLRegionMake2D(0, 0, 4, 1), mipmapLevel: 0)

print("mip levels:", source.mipmapLevelCount, "(0 = black, 1 = white, 2+ = grey 128)")
for (index, lod) in lods.enumerated() {
    let red = Int(pixels[index * 4 + 2])
    let interpretation = red > 250 ? "level 1 (white)"
        : red < 5 ? "level 0 (black)"
        : red > 120 && red < 136 ? "level 2+ (grey)"
        : "blend"
    print(String(format: "lod %.2f -> red %3d  (%@)", lod, red, interpretation))
}
