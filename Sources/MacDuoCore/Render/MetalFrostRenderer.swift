//
//  MetalFrostRenderer.swift
//  MacDuo
//
//  Progressive blur, driven by the lid angle.
//
//  Per frame:
//    1. the captured display is copied 1:1 into a mipmapped working picture
//       (no resize, no crop, no keystone: the picture stays where it would be at
//       90°);
//    2. the mip chain is generated for it;
//    3. the composite samples that chain with a blur radius that is zero at the
//       hinge and maximal at the far edge, and darkens the far edge on top.
//
//  Sampling a prefiltered level per tap (level = log2(radius)) is what lets the
//  radius vary continuously with position without aliasing, which is what makes
//  the ramp read as one sheet of frosted glass rather than as stacked blur
//  levels.
//

import Foundation
import Metal
import MetalKit
import CoreVideo
import simd

/// Mirrors `FrostUniforms` in MetalFrost.metal.
///
/// The block is laid out as three 16-byte rows so MSL and Swift agree without
/// padding guesswork. The probe asserts `MemoryLayout<FrostUniforms>.stride`.
public struct FrostUniforms {
    // Row 1: picture geometry and fold strength
    var pictureSize: SIMD2<Float> = .zero
    var progress: Float = 0
    var blurRadiusPx: Float = 0

    // Row 2: ramp shape
    var falloff: Float = 1.35
    var hingeClear: Float = 0
    var darkenStart: Float = 0.2
    var darkenGain: Float = 1.6

    // Row 3: glass, then the viewer (screen heights, as in the reference)
    var frostOpacity: Float = 0
    var frostSaturation: Float = 1
    var eyeDistance: Float = 2.5
    var eyeHeight: Float = 0.5
}

enum FrostRendererError: Error {
    case noDevice
    case noFunction(String)
    case noTextureCache
    case textureCreationFailed
    case noDrawable

    var localizedDescription: String {
        switch self {
        case .noDevice: "没有可用的 Metal 设备。"
        case .noFunction(let name): "着色器函数缺失：\(name)"
        case .noTextureCache: "无法创建 Metal 纹理缓存。"
        case .textureCreationFailed: "无法从捕获画面创建纹理。"
        case .noDrawable: "没有可用的绘制目标。"
        }
    }
}

@MainActor
public final class MetalFrostRenderer {

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue

    private let compositePipeline: MTLRenderPipelineState
    private let copyPipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    /// Working picture: mip level 0 is the captured frame at full resolution,
    /// every level below it is the prefiltered version of the one above.
    private var picture: MTLTexture?
    private var pictureSize = CGSize.zero

    /// True while rendering into a read-back texture rather than a drawable.
    private var isRenderingOffscreen = false

    /// Pixel format of the captured frames, needed to build compatible pipelines.
    public nonisolated static let capturePixelFormat: MTLPixelFormat = .bgra8Unorm

    /// Pixels per point assumed when the caller does not say otherwise.
    public nonisolated static let defaultDisplayScale: CGFloat = 2

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw FrostRendererError.noDevice
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw FrostRendererError.noDevice
        }
        commandQueue = queue

        let library = try Self.makeShaderLibrary(device: device)
        guard let vertexFunction = library.makeFunction(name: "frost_vertex") else {
            throw FrostRendererError.noFunction("frost_vertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "frost_fragment") else {
            throw FrostRendererError.noFunction("frost_fragment")
        }
        guard let copyFunction = library.makeFunction(name: "frost_copy") else {
            throw FrostRendererError.noFunction("frost_copy")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "MacDuo Frost Composite"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = Self.capturePixelFormat
        compositePipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let copyDescriptor = MTLRenderPipelineDescriptor()
        copyDescriptor.label = "MacDuo Picture Copy"
        copyDescriptor.vertexFunction = vertexFunction
        copyDescriptor.fragmentFunction = copyFunction
        copyDescriptor.colorAttachments[0].pixelFormat = Self.capturePixelFormat
        copyPipeline = try device.makeRenderPipelineState(descriptor: copyDescriptor)

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw FrostRendererError.noTextureCache
        }
        textureCache = cache
    }

    // MARK: - Entry points

    /// Renders one frame into `drawable`.
    ///
    /// - Parameters:
    ///   - pixelBuffer: the captured frame of the built-in display.
    ///   - progress: 0 = the picture standing at 90°, 1 = fully folded.
    ///   - settings: current look/anchor configuration.
    ///   - viewSize: drawable size in pixels.
    ///   - displayScale: drawable pixels per display point, so that the blur
    ///     radius stays the same physical size on any display.
    @discardableResult
    public func render(pixelBuffer: CVPixelBuffer,
                       progress: Double,
                       settings: FrostSettings,
                       drawable: CAMetalDrawable,
                       viewSize: CGSize,
                       displayScale: CGFloat = MetalFrostRenderer.defaultDisplayScale) -> Bool {
        let ok = render(into: drawable.texture,
                        pixelBuffer: pixelBuffer,
                        progress: progress,
                        settings: settings,
                        pixelSize: viewSize,
                        displayScale: displayScale)
        if ok { drawable.present() }
        return ok
    }

    /// The same pipeline writing into an arbitrary texture, so the offscreen
    /// verification harness exercises exactly the path the app uses.
    @discardableResult
    public func renderOffscreen(pixelBuffer: CVPixelBuffer,
                                progress: Double,
                                settings: FrostSettings,
                                target: MTLTexture,
                                displayScale: CGFloat = MetalFrostRenderer.defaultDisplayScale) -> Bool {
        let size = CGSize(width: target.width, height: target.height)
        let previous = isRenderingOffscreen
        isRenderingOffscreen = true
        defer { isRenderingOffscreen = previous }

        return render(into: target,
                      pixelBuffer: pixelBuffer,
                      progress: progress,
                      settings: settings,
                      pixelSize: size,
                      displayScale: displayScale)
    }

    public func invalidateCache() {
        textureCache.flatMap { CVMetalTextureCacheFlush($0, 0) }
    }

    // MARK: - Frame

    private func render(into target: MTLTexture,
                        pixelBuffer: CVPixelBuffer,
                        progress: Double,
                        settings: FrostSettings,
                        pixelSize: CGSize,
                        displayScale: CGFloat) -> Bool {

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0, pixelSize.width > 0, pixelSize.height > 0 else { return false }

        guard let sourceTexture = makeTexture(from: pixelBuffer, width: width, height: height),
              let picture = ensurePicture(width: width, height: height) else {
            return false
        }

        var uniforms = makeUniforms(progress: progress,
                                    settings: settings,
                                    pictureWidth: width,
                                    pictureHeight: height,
                                    displayScale: displayScale)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
        commandBuffer.label = "MacDuo Frost Frame"

        // Pass 1: the captured frame at full resolution, pixel for pixel.
        let copyDescriptor = MTLRenderPassDescriptor()
        copyDescriptor.colorAttachments[0].texture = picture
        copyDescriptor.colorAttachments[0].level = 0
        copyDescriptor.colorAttachments[0].loadAction = .dontCare
        copyDescriptor.colorAttachments[0].storeAction = .store

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: copyDescriptor) {
            encoder.label = "MacDuo Picture Copy"
            encoder.setRenderPipelineState(copyPipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrostUniforms>.stride, index: 0)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        // Pass 2: prefiltered levels for the blur taps to read from.
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "MacDuo Mip Chain"
            blit.generateMipmaps(for: picture)
            blit.endEncoding()
        }

        // Pass 3: the fold itself — blur ramp plus shadow ramp.
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return false
        }
        encoder.label = "MacDuo Composite"
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrostUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrostUniforms>.stride, index: 0)
        encoder.setFragmentTexture(picture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.commit()
        if isRenderingOffscreen { commandBuffer.waitUntilCompleted() }

        return true
    }

    // MARK: - Shader library

    /// Builds the shader library.
    ///
    /// A prebuilt `default.metallib` is used when present (that is what build.sh
    /// produces when the Xcode Metal toolchain is installed). Otherwise the
    /// shader is compiled at run time from the embedded source, so a plain
    /// `swift build` is enough to get a working app.
    public nonisolated static func makeShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let library = try? device.makeDefaultLibrary(bundle: Bundle.main),
           library.makeFunction(name: "frost_fragment") != nil {
            return library
        }
        if let library = device.makeDefaultLibrary(),
           library.makeFunction(name: "frost_fragment") != nil {
            return library
        }

        let options = MTLCompileOptions()
        options.languageVersion = .version3_0
        do {
            return try device.makeLibrary(source: EmbeddedShader.source, options: options)
        } catch {
            throw FrostRendererError.noFunction("无法编译内嵌着色器：\(error.localizedDescription)")
        }
    }

    // MARK: - Internals

    private func makeUniforms(progress: Double,
                              settings: FrostSettings,
                              pictureWidth: Int,
                              pictureHeight: Int,
                              displayScale: CGFloat) -> FrostUniforms {
        var uniforms = FrostUniforms()

        uniforms.pictureSize = SIMD2(Float(max(pictureWidth, 1)), Float(max(pictureHeight, 1)))
        uniforms.progress = Float(min(max(progress, 0), 1))
        // The radius is authored in points so the effect looks the same on any
        // display; the picture is in pixels.
        uniforms.blurRadiusPx = Float(max(settings.blurRadiusPoints, 0) * Double(max(displayScale, 0.1)))
        uniforms.falloff = Float(min(max(settings.rampFalloff, 0.05), 4))
        uniforms.hingeClear = Float(min(max(settings.hingeClearFraction, 0), 0.8))
        uniforms.darkenStart = Float(min(max(settings.darkeningStart, 0), 0.9))
        uniforms.darkenGain = Float(min(max(settings.farDarkening, 0), 4))
        uniforms.frostOpacity = Float(min(max(settings.frostOpacity, 0), 1))
        uniforms.frostSaturation = Float(min(max(settings.frostSaturation, 0), 1))
        // Screen heights, so the eye is described the same way the reference
        // describes its camera.
        uniforms.eyeDistance = Float(min(max(settings.eyeDistance, 0.5), 12))
        uniforms.eyeHeight = Float(min(max(settings.eyeHeight, -1), 3))
        return uniforms
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> MTLTexture? {
        guard let textureCache else { return nil }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            Self.capturePixelFormat,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    /// Allocates (or reuses) the mipmapped working picture.
    private func ensurePicture(width: Int, height: Int) -> MTLTexture? {
        let size = CGSize(width: width, height: height)
        if let picture, pictureSize == size { return picture }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.capturePixelFormat,
            width: max(width, 1),
            height: max(height, 1),
            mipmapped: true
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "MacDuo Picture"
        picture = texture
        pictureSize = size
        return texture
    }
}
