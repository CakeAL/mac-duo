//
//  main.swift
//  MacDuo (verification harness)
//
//  Exercises everything the overlay needs at runtime, without opening a window:
//  the shader library, both pipelines, the fold geometry and the frost ramp. Run
//  it with ./verify.sh — a broken shader or a Metal regression then fails before
//  the app is ever launched.
//
//  Every pixel access goes through the channel helpers below. The capture format
//  is BGRA, and reading the wrong offset silently shifts the whole sample, which
//  once cost an afternoon: x=0,y=2 read back as x=640,y=400.
//

import Foundation
import Metal
import MetalKit
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
import MacDuoCore

enum RuntimeProbe {

    // MARK: - Test frame

    /// A synthetic stand-in for a captured display.
    ///
    /// - Red: exact 0...255 horizontal ramp. A red read-out is therefore a
    ///   picture column position, which makes the "clipped, not rescaled" check
    ///   an exact numeric comparison.
    /// - Green: alternates every 4 px horizontally, blue every 4 px vertically.
    ///   Together they carry enough detail that any real blur shows up.
    /// - Alpha: fully opaque.
    static let width = 1280
    static let height = 800
    static let rowBytes = width * 4

    static func makeTestFrame() -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var created: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary,
                                  &created) == kCVReturnSuccess,
              let buffer = created else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * stride + x * 4
                    let cell = ((x >> 2) ^ (y >> 2)) & 1 == 0
                    pointer[offset + 0] = cell ? 255 : 0                       // B
                    pointer[offset + 1] = cell ? 255 : 0                       // G
                    pointer[offset + 2] = UInt8((x * 255) / (width - 1))       // R
                    pointer[offset + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    // MARK: - Pixel access (BGRA)

    @inline(__always)
    static func blue(_ buffer: [UInt8], row: Int, x: Int) -> Int {
        index(buffer, row: row, x: x, offset: 0)
    }

    @inline(__always)
    static func green(_ buffer: [UInt8], row: Int, x: Int) -> Int {
        index(buffer, row: row, x: x, offset: 1)
    }

    @inline(__always)
    static func red(_ buffer: [UInt8], row: Int, x: Int) -> Int {
        index(buffer, row: row, x: x, offset: 2)
    }

    @inline(__always)
    private static func index(_ buffer: [UInt8], row: Int, x: Int, offset: Int) -> Int {
        let i = row * rowBytes + x * 4 + offset
        guard i >= 0, i < buffer.count else { return 0 }
        return Int(buffer[i])
    }

    /// Mean absolute gradient inside a band of rows, measured on the striping
    /// channels: high where the picture is crisp, low where it has been blurred.
    ///
    /// Both axes are sampled — green carries horizontal striping and blue the
    /// vertical one, and a single axis would report a blurred frame as sharp.
    ///
    /// Only pixels strictly inside the panel are counted: the panel's own edges
    /// and the background beyond them carry detail of their own, which would
    /// otherwise be mistaken for picture detail.
    ///
    /// Absolute values on a 4 px pattern depend on where the pattern's phase
    /// lands against the sample grid, so this is only meaningful when compared
    /// between two renders of the same frame.
    static func detail(_ buffer: [UInt8], row: Int, insideX: ClosedRange<Int>, band: Int = 24) -> Double {
        var total = 0.0
        var samples = 0
        let first = max(row - band / 2, 1)
        let last = min(row + band / 2, height - 2)
        // A generous margin: the panel's border pixels blend towards the
        // background, and including them would measure the edge, not the picture.
        let margin = 16
        let xFirst = max(insideX.lowerBound + margin, 2)
        let xLast = min(insideX.upperBound - margin, width - 2)
        guard xLast > xFirst else { return 0 }

        for y in first..<last {
            for x in xFirst..<xLast {
                total += abs(Double(green(buffer, row: y, x: x + 1)) - Double(green(buffer, row: y, x: x)))
                total += abs(Double(blue(buffer, row: y + 1, x: x)) - Double(blue(buffer, row: y, x: x)))
                samples += 2
            }
        }
        return samples > 0 ? total / Double(samples) : 0
    }

    /// First and last pixel of a row that is inside the panel. Used on coverage
    /// mask renders, where inside is 255 and outside is 0.
    static func panelEdges(_ buffer: [UInt8], row: Int) -> (first: Int, last: Int) {
        var first = -1
        var last = -1
        for x in 0..<width where green(buffer, row: row, x: x) >= 128 {
            if first < 0 { first = x }
            last = x
        }
        return (first < 0 ? 0 : first, last < 0 ? width - 1 : last)
    }

    /// First visible picture pixel in a row: on the red ramp, zero is only ever
    /// the clamped background.
    static func firstPicturePixel(_ buffer: [UInt8], row: Int) -> Int {
        for x in 0..<width where red(buffer, row: row, x: x) > 0 { return x }
        return -1
    }

    static func makeTarget(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalFrostRenderer.capturePixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    // MARK: - Entry point

    static func run() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fail("no Metal device available")
        }
        print("Metal device:", device.name)

        // 1. Shader library — the same lookup the app performs.
        let library: MTLLibrary
        do {
            library = try MetalFrostRenderer.makeShaderLibrary(device: device)
        } catch {
            fail("shader library unavailable: \(error)")
        }
        print("library functions:", library.functionNames.sorted().joined(separator: ", "))
        for name in ["frost_vertex", "frost_vertex_flat", "frost_downscale", "frost_fragment"] {
            guard library.makeFunction(name: name) != nil else {
                fail("shader function '\(name)' missing from the library")
            }
        }
        print("shader functions: OK")

        guard let buffer = makeTestFrame() else {
            fail("could not create the test frame")
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let outputDirectory = ProcessInfo.processInfo.environment["MACDUO_PROBE_OUT"]

        Task { @MainActor in
            let settings = FrostSettings()
            let renderer: MetalFrostRenderer
            do {
                renderer = try MetalFrostRenderer()
            } catch {
                fail("renderer init failed: \(error)")
            }
            print("pipelines: OK")

            // The probe must not leave its own experiments in the user's
            // preferences, so the angle window is pinned to something that is
            // never persisted and the fold is driven explicitly below.
            let fold = 0.30

            /// Renders the test frame and reads it back. Every capture gets its
            /// own texture: a shared target would let a later pass overwrite a
            /// buffer that has not been read back yet.
            @MainActor func capture(trapezoid: Double,
                                    debug: MetalFrostRenderer.GeometryDebug) -> [UInt8] {
                settings.trapezoidAmount = trapezoid
                guard let target = makeTarget(device: device) else {
                    fail("could not allocate a render target")
                }
                _ = renderer.renderOffscreen(pixelBuffer: buffer,
                                             intensity: 1.0,
                                             settings: settings,
                                             target: target,
                                             debug: debug)
                var pixels = [UInt8](repeating: 0, count: rowBytes * height)
                target.getBytes(&pixels, bytesPerRow: rowBytes,
                                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                return pixels
            }

            let folded = capture(trapezoid: fold, debug: .off)
            let foldedNoFrost = capture(trapezoid: fold, debug: .foldedSharp)
            let foldedMask = capture(trapezoid: fold, debug: .coverage)
            let flatMask = capture(trapezoid: 0, debug: .coverage)

            // 2. Fold geometry: a panel hinged along the bottom edge, tipped away.
            let fractions = [0.02, 0.2, 0.4, 0.6, 0.8, 0.98]
            let rows = fractions.map { min(max(Int(Double(height) * $0), 2), height - 3) }

            print("")
            print("row%   panel edges (folded)   folded width   full width")
            var widths: [(row: Int, width: Int, first: Int)] = []
            for (fraction, row) in zip(fractions, rows) {
                let edges = panelEdges(foldedMask, row: row)
                let flat = panelEdges(flatMask, row: row)
                widths.append((row, edges.last - edges.first, edges.first))
                let foldedWidth = edges.last - edges.first
                let flatWidth = flat.last - flat.first
                print(String(format: "%4.0f%%  %6d … %-6d  %10d   %10d",
                             fraction * 100, edges.first, edges.last, foldedWidth, flatWidth))
            }
            print("")

            let topWidth = widths.first!.width
            let hingeWidth = widths.last!.width
            let measuredRatio = Double(topWidth) / Double(hingeWidth)
            let expectedRatio = 1.0 / (1.0 + fold)
            print(String(format: "panel width  top: %d  hinge: %d  (ratio %.2f, expected %.2f)",
                         topWidth, hingeWidth, measuredRatio, expectedRatio))
            guard topWidth < hingeWidth else {
                fail("the folded panel is not narrower at the top (\(topWidth) vs \(hingeWidth))")
            }
            guard hingeWidth >= width - 12 else {
                fail("the hinge edge is not full width (\(hingeWidth) of \(width))")
            }
            // The slope must be a straight line: every row's width between the two
            // ends has to follow the same linear ramp.
            for sample in widths {
                let rowFraction = (Double(sample.row) + 0.5) / Double(height)
                let widthRange = Double(hingeWidth - topWidth)
                let expected = Double(hingeWidth) - widthRange * (1.0 - rowFraction)
                let difference = abs(Double(sample.width) - expected)
                guard difference <= 12 else {
                    fail("the fold is not a straight-sided trapezoid at row "
                         + "\(sample.row): \(sample.width) vs \(Int(expected))")
                }
            }

            // 3. Clipping, not rescaling: the picture's own columns stay put, so
            //    the panel's left edge must still be showing the picture's first
            //    column (red reads 0 there, and the ramp makes it exact).
            let topRow = rows.first!
            let panelLeft = widths.first!.first
            let pictureLeft = firstPicturePixel(folded, row: topRow)
            let uprightLeft = firstPicturePixel(folded, row: topRow)
            print("panel left edge at the top row:", panelLeft,
                  " first picture pixel:", pictureLeft, " (upright would be", uprightLeft, ")")
            guard abs(pictureLeft - panelLeft) <= 3 else {
                fail("the picture does not start at the panel edge "
                     + "(picture \(pictureLeft) vs panel \(panelLeft))")
            }
            guard pictureLeft > 20 else {
                fail("the picture was not clipped at all: it starts at x=\(pictureLeft), "
                     + "so the fold must have rescaled it instead")
            }

            // 4. The frost ramp: measured as a ratio against the same fold with no
            //    blur, which cancels out the sampling phase of the test pattern.
            let interior = { (row: Int) -> ClosedRange<Int> in
                let edges = panelEdges(foldedMask, row: row)
                return edges.first...(edges.last)
            }

            func retainedDetail(row: Int) -> Double {
                let range = interior(row)
                let sharpOnly = detail(foldedNoFrost, row: row, insideX: range)
                guard sharpOnly > 0.0001 else { return 1 }
                return detail(folded, row: row, insideX: range) / sharpOnly
            }

            let topRetained = retainedDetail(row: rows.first!)
            let midRetained = retainedDetail(row: rows[3])
            let hingeRetained = retainedDetail(row: rows.last!)

            print("")
            print("detail kept, relative to the same fold without any frost:")
            print(String(format: "  top edge   (row %3d): %5.0f%%", rows.first!, topRetained * 100))
            print(String(format: "  mid panel  (row %3d): %5.0f%%", rows[3], midRetained * 100))
            print(String(format: "  hinge      (row %3d): %5.0f%%", rows.last!, hingeRetained * 100))
            let sharpTop = detail(foldedNoFrost, row: rows.first!, insideX: interior(rows.first!))
            let sharpHinge = detail(foldedNoFrost, row: rows.last!, insideX: interior(rows.last!))
            print(String(format: "  reference gradients without frost: top %.2f  hinge %.2f", sharpTop, sharpHinge))
            print("")

            guard topRetained < 0.5 else {
                fail(String(format: "the frost barely touched the top edge (%.0f%% of the detail kept)",
                            topRetained * 100))
            }
            guard midRetained > topRetained else {
                fail("the mid panel is as frosted as the top edge "
                     + "(\(midRetained) vs \(topRetained))")
            }
            guard hingeRetained > midRetained else {
                fail("the hinge is as frosted as the mid panel "
                     + "(\(hingeRetained) vs \(midRetained))")
            }
            guard hingeRetained > 0.5 else {
                fail(String(format: "the hinge region is not readable (%.0f%% of the detail kept)",
                            hingeRetained * 100))
            }

            // 5. Preview frames, for eyeballing the effect.
            if let outputDirectory {
                try? FileManager.default.createDirectory(atPath: outputDirectory,
                                                         withIntermediateDirectories: true)
                settings.trapezoidAmount = 0.30
                for (name, intensity) in [("angle-open", 0.0), ("angle-mid", 0.45), ("angle-closed", 1.0)] {
                    guard let target = makeTarget(device: device) else { break }
                    _ = renderer.renderOffscreen(pixelBuffer: buffer, intensity: intensity,
                                                 settings: settings, target: target)
                    let path = "\(outputDirectory)/\(name).png"
                    try? writePNG(texture: target, to: path)
                    print("wrote \(path)")
                }
            }

            // 6. Optional on-screen smoke test: `MACDUO_PROBE_FLASH=1` pops the
            //    real overlay window for a couple of seconds so the effect can be
            //    seen on the built-in display without granting anything.
            if ProcessInfo.processInfo.environment["MACDUO_PROBE_FLASH"] == "1" {
                runVisualSmokeTest(settings: settings, buffer: buffer)
            }

            print("RESULT: all runtime checks passed")
            exit(0)
        }

        app.run()
    }

    // MARK: - Visual smoke test

    /// Puts the real overlay on screen for ~2.5 s with the synthetic frame: the
    /// picture folded into a trapezoid, frosted along the top edge and clear down
    /// at the hinge. A plain NSWindow, so this needs no permissions.
    @MainActor
    static func runVisualSmokeTest(settings: FrostSettings, buffer: CVPixelBuffer) {
        guard let screen = DisplayResolver.builtInScreen else {
            print("flash: no built-in screen, skipping")
            return
        }

        let host = VisualSmokeHost(frame: screen.frame, settings: settings)
        guard host.start(screen: screen) else {
            print("flash: could not create the overlay window, skipping")
            return
        }

        settings.trapezoidAmount = 0.30
        host.scheduleFrame(buffer)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        host.show(intensity: 1.0)
        host.scheduleFrame(buffer)
        print("flash: on screen now — trapezoid tipped back, frost heaviest at the top")
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))

        host.close()
        print("flash: done")
    }

    // MARK: - PNG output

    /// Saves a texture as a PNG so the effect can be eyeballed without the GUI.
    static func writePNG(texture: MTLTexture, to path: String) throws {
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        texture.getBytes(&pixels, bytesPerRow: rowBytes,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: rowBytes,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                           | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent)
        else {
            throw NSError(domain: "MacDuoProbe", code: 1)
        }

        let url = URL(fileURLWithPath: path) as CFURL
        guard let destination = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "MacDuoProbe", code: 2)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "MacDuoProbe", code: 3)
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("PROBE FAILURE: \(message)\n".utf8))
        exit(1)
    }
}

/// Minimal host that shows a MetalFrostRenderer output in a borderless window.
/// Used only by the optional visual smoke test.
@MainActor
final class VisualSmokeHost: NSObject, MTKViewDelegate {

    private let settings: FrostSettings
    private let renderer: MetalFrostRenderer?
    private var window: NSWindow?
    private var view: MTKView?
    private var pending: CVPixelBuffer?
    private var intensity: Double = 0

    init(frame: CGRect, settings: FrostSettings) {
        self.settings = settings
        self.renderer = try? MetalFrostRenderer()
        super.init()
    }

    func start(screen: NSScreen) -> Bool {
        guard let renderer else { return false }

        let view = MTKView(frame: screen.frame, device: renderer.device)
        view.delegate = self
        view.colorPixelFormat = MetalFrostRenderer.capturePixelFormat
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        self.view = view

        let window = NSWindow(contentRect: screen.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false,
                              screen: screen)
        window.contentView = view
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.window = window
        return true
    }

    func scheduleFrame(_ buffer: CVPixelBuffer) {
        pending = buffer
        view?.setNeedsDisplay(view?.bounds ?? .zero)
    }

    func show(intensity: Double) {
        self.intensity = intensity
        window?.orderFrontRegardless()
        view?.setNeedsDisplay(view?.bounds ?? .zero)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            guard let renderer, let pending, let drawable = view.currentDrawable else { return }
            _ = renderer.render(pixelBuffer: pending,
                                intensity: intensity,
                                settings: settings,
                                drawable: drawable,
                                viewSize: view.drawableSize)
        }
    }
}

RuntimeProbe.run()
