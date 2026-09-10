//
//  MetalFrostRenderer.swift
//  MacDuo
//
//  Three-level Gaussian pyramid composited along a gradient axis, which is what
//  produces the "progressive blur" look of a folding display: crisp at one edge,
//  frosted glass at the other, with the whole thing driven by the lid angle.
//

import Foundation
import Metal
import MetalKit
import MetalPerformanceShaders
import CoreVideo
import simd

/// Mirrors `FrostUniforms` in MetalFrost.metal.
///
/// The scalar block is laid out as 4-float rows so MSL and Swift agree without
/// padding guesswork: unaligned scalars occupy the tail slots of the float2 rows.
public struct FrostUniforms {
    // Row 1: render target size (xy = pixels, zw = reciprocal)
    var targetSize: SIMD4<Float> = .zero

    // Row 2: fold geometry. `displaySize` is carried for diagnostics only.
    var fold: Float = 0
    var fold2: Float = 0
    var displaySize: SIMD2<Float> = .zero

    // Row 2: look
    var nearClear: Float = 0.2
    var blurSoftness: Float = 0.45
    var frostOpacity: Float = 0.14
    var saturation: Float = 0.55

    // Row 3: more look
    var dim: Float = 0.06
    var globalMix: Float = 0
    var backgroundDim: Float = 0.6
    var pad0: Float = 0

    // Row 4: reserved
    var radius0: Float = 0
    var radius1: Float = 0
    var radius2: Float = 0
    var geometryDebug: Float = 0
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
    private let downscalePipeline: MTLRenderPipelineState
    private let flatVertexFunction: MTLFunction
    /// One kernel per level, because MPSImageGaussianBlur's sigma is read-only.
    private var blurKernels: [MPSImageGaussianBlur] = []
    private var textureCache: CVMetalTextureCache?

    private let downsampleFactor = 2

    /// True while rendering into a read-back texture rather than a drawable.
    private var isRenderingOffscreen = false

    /// Debug output modes, used by the verification harness.
    public enum GeometryDebug: Float {
        case off = 0
        /// Fold applied, blurred picture (the normal effect).
        case folded = 1
        /// Fold applied, sharp picture only: isolates the geometry from the blur.
        case foldedSharp = 2
        /// Panel coverage mask: isolates the geometry from everything else.
        case coverage = 3
    }

    private var geometryDebugMode: Float = 0

    private var textures: [MTLTexture] = []
    private var textureSize = CGSize.zero
    private var cachedSigmas: [Float?] = [nil, nil, nil]

    /// Pixel format of the captured frames, needed to build a compatible pipeline.
    public nonisolated static let capturePixelFormat: MTLPixelFormat = .bgra8Unorm

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

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "MacDuo Frost Composite"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = Self.capturePixelFormat
        compositePipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        guard let downscaleFunction = library.makeFunction(name: "frost_downscale") else {
            throw FrostRendererError.noFunction("frost_downscale")
        }
        guard let flatVertex = library.makeFunction(name: "frost_vertex_flat") else {
            throw FrostRendererError.noFunction("frost_vertex_flat")
        }
        flatVertexFunction = flatVertex

        let downscaleDescriptor = MTLRenderPipelineDescriptor()
        downscaleDescriptor.label = "MacDuo Downscale"
        downscaleDescriptor.vertexFunction = flatVertex
        downscaleDescriptor.fragmentFunction = downscaleFunction
        downscaleDescriptor.colorAttachments[0].pixelFormat = Self.capturePixelFormat
        downscalePipeline = try device.makeRenderPipelineState(descriptor: downscaleDescriptor)

        // Radii are re-derived every frame, so keep a kernel per level and only
        // recreate one when its sigma actually changes.
        blurKernels = [MPSImageGaussianBlur(device: device, sigma: 1),
                       MPSImageGaussianBlur(device: device, sigma: 1),
                       MPSImageGaussianBlur(device: device, sigma: 1)]

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw FrostRendererError.noTextureCache
        }
        textureCache = cache
    }

    /// Renders one frame into `drawable`.
    ///
    /// - Parameters:
    ///   - pixelBuffer: the captured frame of the built-in display.
    ///   - intensity: 0 = untouched, 1 = fully frosted.
    ///   - settings: current look/anchor configuration.
    ///   - viewSize: drawable size in pixels.
    @discardableResult
    public func render(pixelBuffer: CVPixelBuffer,
                       intensity: Double,
                       settings: FrostSettings,
                       drawable: CAMetalDrawable,
                       viewSize: CGSize) -> Bool {
        let ok = render(into: drawable.texture,
                        pixelBuffer: pixelBuffer,
                        intensity: intensity,
                        settings: settings,
                        pixelSize: viewSize)
        if ok { drawable.present() }
        return ok
    }

    /// The same pipeline writing into an arbitrary texture, so the offscreen
    /// verification harness exercises exactly the path the app uses.
    ///
    /// - Parameter geometryOnly: writes the panel coverage mask instead of the
    ///   frosted picture, so the trapezoid can be measured without the blur
    ///   smearing its edges.
    @discardableResult
    public func renderOffscreen(pixelBuffer: CVPixelBuffer,
                         intensity: Double,
                         settings: FrostSettings,
                         target: MTLTexture,
                         debug: GeometryDebug = .off) -> Bool {
        let size = CGSize(width: target.width, height: target.height)
        let previous = isRenderingOffscreen
        let previousDebug = geometryDebugMode
        isRenderingOffscreen = true
        geometryDebugMode = debug.rawValue
        defer {
            isRenderingOffscreen = previous
            geometryDebugMode = previousDebug
        }

        return render(into: target,
                      pixelBuffer: pixelBuffer,
                      intensity: intensity,
                      settings: settings,
                      pixelSize: size)
    }

    private func render(into target: MTLTexture,
                        pixelBuffer: CVPixelBuffer,
                        intensity: Double,
                        settings: FrostSettings,
                        pixelSize: CGSize) -> Bool {

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0, pixelSize.width > 0, pixelSize.height > 0 else { return false }

        guard let sourceTexture = makeTexture(from: pixelBuffer, width: width, height: height) else {
            return false
        }

        let workWidth = max(width / downsampleFactor, 2)
        let workHeight = max(height / downsampleFactor, 2)
        let workSize = CGSize(width: workWidth, height: workHeight)

        ensureTextures(size: workSize)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
        commandBuffer.label = "MacDuo Frost Frame"

        // The blur radii are authored in points; convert to work-texture pixels.
        let pointScale = Double(width) / max(pixelSize.width, 1) / Double(downsampleFactor)
        let radii = Self.levelRadii(nearPoints: settings.minBlurPoints,
                                    farPoints: settings.maxBlurPoints)
        let sigmas = Self.chainedSigmas(radii: radii, pixelScale: pointScale)

        // Pass 1: scale the full-resolution capture down into level 1.
        let downscaleDescriptor = MTLRenderPassDescriptor()
        downscaleDescriptor.colorAttachments[0].texture = textures[0]   // downsample
        downscaleDescriptor.colorAttachments[0].loadAction = .dontCare
        downscaleDescriptor.colorAttachments[0].storeAction = .store

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: downscaleDescriptor) {
            encoder.label = "MacDuo Downsample"
            encoder.setRenderPipelineState(downscalePipeline)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        // Pass 2: three chained Gaussian passes. Each one starts from the
        // previous result with a larger radius, which is what produces the
        // deep frosted look without a 90 pt single-pass kernel. Every pass has
        // its own destination texture because MPS cannot work in place.
        var previousResult = textures[0]
        for (index, sigma) in sigmas.enumerated() {
            let destination = textures[1 + index]
            let kernel = blurKernel(for: index, sigma: Float(sigma))
            kernel.encode(commandBuffer: commandBuffer,
                          sourceTexture: previousResult,
                          destinationTexture: destination)
            previousResult = destination
        }

        // Pass 3: composite along the gradient.
        var uniforms = makeUniforms(intensity: intensity,
                                    settings: settings,
                                    pixelWidth: width,
                                    pixelHeight: height,
                                    targetWidth: target.width,
                                    targetHeight: target.height)

        if isRenderingOffscreen {
            print("[dbg] mode=\(uniforms.geometryDebug) fold=\(uniforms.fold)")
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return false }
        encoder.label = "MacDuo Composite"
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrostUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrostUniforms>.stride, index: 0)
        encoder.setFragmentTexture(sourceTexture, index: 0)      // crisp, full resolution
        encoder.setFragmentTexture(textures[1], index: 1)   // blur level 1 output
        encoder.setFragmentTexture(textures[2], index: 2)   // blur level 2 output
        encoder.setFragmentTexture(textures[3], index: 3)   // blur level 3 output
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        if !isRenderingOffscreen {
            // Only the live overlay presents; offscreen targets are read back.
            // (present() lives in the drawable entry point above.)
        }
        if !isRenderingOffscreen {
            // Only the live overlay presents; offscreen targets are read back.
            // (present() lives in the drawable entry point above.)
        }
        commandBuffer.commit()
        if isRenderingOffscreen { commandBuffer.waitUntilCompleted() }

        return true
    }

    public func invalidateCache() {
        textureCache.flatMap { CVMetalTextureCacheFlush($0, 0) }
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

    private func blurKernel(for index: Int, sigma: Float) -> MPSImageGaussianBlur {
        let existing = blurKernels[index]
        // Rebuild only when the requested radius has drifted from the cached one.
        if let cached = cachedSigmas[index], abs(cached - sigma) < 0.25 { return existing }

        let kernel = MPSImageGaussianBlur(device: device, sigma: sigma)
        blurKernels[index] = kernel
        cachedSigmas[index] = sigma
        return kernel
    }

    /// Radii of the three stacked levels, in points.
    ///
    /// The levels are evenly spaced between "almost sharp" and the user's maximum
    /// radius, so a low `blurSoftness` yields three clearly separated layers and a
    /// high one melts them into a single ramp.
    private static func levelRadii(nearPoints: Double, farPoints: Double) -> [Double] {
        let near = max(nearPoints, 0.2)
        let far = max(farPoints, near + 0.5)
        return [near, (near + far) / 2, far]
    }

    /// Turns the desired per-level radii into the sigma of each chained Gaussian.
    ///
    /// Chained blurs accumulate variance, so sigma_n = sqrt(r_n^2 - r_(n-1)^2)
    /// after converting the radius to a standard deviation. Without this the
    /// three passes would overshoot and the deepest level would be much wider
    /// than requested.
    static func chainedSigmas(radii: [Double], pixelScale: Double) -> [Double] {
        var result: [Double] = []
        var previousRadius: Double = 0
        for radius in radii {
            let wanted = max(radius, 0.25) * pixelScale
            let previous = previousRadius * pixelScale
            let sigma = (wanted * wanted - previous * previous).squareRoot() / 2.0
            result.append(max(sigma, 0.35))
            previousRadius = radius
        }
        return result
    }

    private func makeUniforms(intensity: Double,
                              settings: FrostSettings,
                              pixelWidth: Int,
                              pixelHeight: Int,
                              targetWidth: Int,
                              targetHeight: Int) -> FrostUniforms {
        var uniforms = FrostUniforms()

        let safeWidth = max(targetWidth, 1)
        let safeHeight = max(targetHeight, 1)
        uniforms.targetSize = SIMD4<Float>(Float(safeWidth),
                                           Float(safeHeight),
                                           1.0 / Float(safeWidth),
                                           1.0 / Float(safeHeight))

        // The hinge runs along the bottom edge of the display, so the picture is
        // only ever folded about that axis. `fold` is the trapezoid amount; it
        // grows with the closing angle so the whole illusion fades in together.
        let mix = Float(min(max(intensity, 0), 1))
        let fold = Float(min(max(settings.trapezoidAmount * intensity, 0), 0.6))

        uniforms.fold = fold
        uniforms.fold2 = fold * fold
        uniforms.displaySize = SIMD2(Float(pixelWidth), Float(pixelHeight))
        uniforms.nearClear = Float(min(max(settings.nearClearFraction, 0), 0.8))
        uniforms.globalMix = mix
        uniforms.blurSoftness = Float(min(max(settings.frostSoftness, 0), 1))
        uniforms.frostOpacity = Float(min(max(settings.frostOpacity, 0), 1))
        uniforms.saturation = Float(min(max(settings.frostSaturation, 0), 1))
        uniforms.dim = Float(min(max(settings.frostDim, 0), 1))
        uniforms.backgroundDim = Float(min(max(settings.backgroundDim, 0), 1))
        uniforms.geometryDebug = geometryDebugMode
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

    /// One downsample target plus one texture per chained blur pass.
    private func ensureTextures(size: CGSize) {
        if size == textureSize, textures.count == 4 { return }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.capturePixelFormat,
            width: max(Int(size.width), 1),
            height: max(Int(size.height), 1),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private

        textures = (0..<4).compactMap { index in
            let texture = device.makeTexture(descriptor: descriptor)
            texture?.label = index == 0 ? "MacDuo Downsample" : "MacDuo Blur Pass \(index)"
            return texture
        }
        textureSize = size
        // The cached kernels still hold the right radii; nothing else to reset.
    }
}
