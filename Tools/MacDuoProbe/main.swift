//
//  main.swift
//  MacDuo (verification harness)
//
//  Exercises everything the overlay needs at runtime, without opening a window:
//  the shader library, the pipelines, the trapezoid and the blur ramp. Run it
//  with ./verify.sh — a broken shader or a Metal regression then fails before the
//  app is ever launched.
//
//  The four frames each isolate one claim:
//
//    measure  red ramp + checker + a white top band and a black bottom band
//    white    flat white            -> the trapezoid's outline and the black around it
//    edge     left black, right white -> the blur radius per row, as a transition width
//    preview  a stand-in desktop    -> the PNGs, for eyeballing
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
import ScreenCaptureKit
import MacDuoCore

enum RuntimeProbe {

    // MARK: - Frames

    static let width = 1280
    static let height = 800
    static let rowBytes = width * 4

    /// Builds a BGRA frame, one pixel at a time, through `paint`.
    static func makeBuffer(_ paint: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8)) -> CVPixelBuffer? {
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
                    let color = paint(x, y)
                    let offset = y * stride + x * 4
                    pointer[offset + 0] = color.b
                    pointer[offset + 1] = color.g
                    pointer[offset + 2] = color.r
                    pointer[offset + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// The measuring frame: a 4 px checker over a horizontal red ramp, with a
    /// flat white band at the top of the picture and a flat black one at the
    /// bottom, so the orientation cannot be faked.
    static func makeMeasureFrame() -> CVPixelBuffer? {
        makeBuffer { x, y in
            if y < 24 { return (255, 255, 255) }
            if y >= height - 24 { return (0, 0, 0) }
            let cell = ((x >> 2) ^ (y >> 2)) & 1 == 0
            return (UInt8((x * 255) / (width - 1)), cell ? 255 : 0, cell ? 0 : 255)
        }
    }

    /// Flat white: the picture is one solid colour, so what is left after the
    /// trapezoid is its outline and the black around it.
    static func makeWhiteFrame() -> CVPixelBuffer? {
        makeBuffer { _, _ in (255, 255, 255) }
    }

    /// One vertical edge, so a row's blur radius can be read off as the width of
    /// the black-to-white transition.
    static func makeEdgeFrame() -> CVPixelBuffer? {
        makeBuffer { x, _ in x < width / 2 ? (0, 0, 0) : (255, 255, 255) }
    }

    /// A stand-in desktop for the preview PNGs: wallpaper, a menu bar, a window
    /// full of text-like bars, and a dock.
    static func makePreviewFrame() -> CVPixelBuffer? {
        let window = (x: 300, y: 180, width: 680, height: 460)
        return makeBuffer { x, y in
            let t = Double(y) / Double(height - 1)
            var color = (
                r: UInt8(24 + 172 * pow(t, 1.6)),
                g: UInt8(30 + 96 * pow(t, 1.6)),
                b: UInt8(58 + 66 * pow(t, 1.6))
            )

            if y < 28 {
                color = (246, 246, 248)
                let items = [40, 110, 200, 280, 360]
                if items.contains(where: { abs($0 - x) < 18 }) { color = (60, 62, 70) }
                if abs(x - 1200) < 14 || abs(x - 1240) < 14 { color = (90, 92, 100) }
            } else if y < 30 {
                color = (210, 212, 218)
            }

            if x >= window.x, x < window.x + window.width,
               y >= window.y, y < window.y + window.height {
                color = (242, 242, 246)
                if y < window.y + 30 {
                    color = (224, 224, 230)
                    let dots = [window.x + 18, window.x + 38, window.x + 58]
                    if dots.contains(where: { abs($0 - x) < 6 }) { color = (200, 120, 110) }
                }
                let line = (y - (window.y + 60)) / 30
                if line >= 0, line < 12, y - (window.y + 60) - line * 30 < 13 {
                    let lengths = [560, 480, 600, 300, 520, 610, 240, 470, 590, 380, 540, 200]
                    let length = lengths[line % lengths.count]
                    if x > window.x + 40, x < window.x + 40 + length {
                        let shade = UInt8(70 + (line % 3) * 20)
                        color = (shade, shade, shade + 8)
                    }
                }
            }

            if y >= 730, y < 790, x >= 340, x < 940 {
                color = (228, 228, 234)
            }
            if y >= 738, y < 782 {
                let icons = stride(from: 360, to: 920, by: 70).map { $0 }
                for (index, left) in icons.enumerated() where x >= left && x < left + 52 {
                    let palette: [(UInt8, UInt8, UInt8)] = [
                        (86, 168, 255), (255, 138, 96), (120, 214, 130), (232, 108, 160),
                        (250, 200, 92), (140, 130, 246), (96, 206, 214), (238, 238, 242),
                    ]
                    color = palette[index % palette.count]
                }
            }
            return color
        }
    }

    // MARK: - Pixel access (BGRA)

    @inline(__always)
    static func blue(_ buffer: [UInt8], _ row: Int, _ x: Int) -> Int {
        index(buffer, row: row, x: x, offset: 0)
    }

    @inline(__always)
    static func green(_ buffer: [UInt8], _ row: Int, _ x: Int) -> Int {
        index(buffer, row: row, x: x, offset: 1)
    }

    @inline(__always)
    static func red(_ buffer: [UInt8], _ row: Int, _ x: Int) -> Int {
        index(buffer, row: row, x: x, offset: 2)
    }

    @inline(__always)
    private static func index(_ buffer: [UInt8], row: Int, x: Int, offset: Int) -> Int {
        let i = row * rowBytes + x * 4 + offset
        guard i >= 0, i < buffer.count else { return 0 }
        return Int(buffer[i])
    }

    static func pixels(of buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var out = [UInt8](repeating: 0, count: rowBytes * height)
        for y in 0..<height {
            memcpy(&out[y * rowBytes], base.advanced(by: y * stride), rowBytes)
        }
        return out
    }

    /// First and last pixel of a row that is brighter than the black around it.
    static func litRun(_ buffer: [UInt8], row: Int) -> (first: Int, last: Int, count: Int) {
        var first = -1
        var last = -1
        for x in 0..<width where red(buffer, row, x) > 24 || green(buffer, row, x) > 24 {
            if first < 0 { first = x }
            last = x
        }
        guard first >= 0 else { return (0, width - 1, 0) }
        return (first, last, last - first + 1)
    }

    /// Mean absolute gradient inside a band of rows, on the striping channels.
    static func detail(_ buffer: [UInt8], row: Int, band: Int = 16) -> Double {
        var total = 0.0
        var samples = 0
        let first = max(row - band / 2, 1)
        let last = min(row + band / 2, height - 2)
        let xFirst = 32
        let xLast = width - 32

        for y in first..<last {
            for x in xFirst..<xLast {
                total += abs(Double(green(buffer, y, x + 1)) - Double(green(buffer, y, x)))
                total += abs(Double(blue(buffer, y + 1, x)) - Double(blue(buffer, y, x)))
                samples += 2
            }
        }
        return samples > 0 ? total / Double(samples) : 0
    }

    /// Width of the black-to-white transition in a row, normalised between the
    /// row's own black and white levels. For a Gaussian of standard deviation s
    /// the 10...90 width is 2.563 s, so this reads the blur out directly.
    static func transitionWidth(_ buffer: [UInt8], row: Int) -> Double {
        let blackLevel = Double(red(buffer, row, 200))
        let whiteLevel = Double(red(buffer, row, width - 200))
        let span = whiteLevel - blackLevel
        guard span > 40 else { return -1 }

        let low = blackLevel + span * 0.1
        let high = blackLevel + span * 0.9
        var lowX = -1
        var highX = -1
        for x in (width / 2 - 400)..<(width / 2 + 400) {
            let value = Double(red(buffer, row, x))
            if lowX < 0, value >= low { lowX = x }
            if highX < 0, value >= high { highX = x }
        }
        guard lowX >= 0, highX >= 0 else { return -1 }
        if ProcessInfo.processInfo.environment["MACDUO_PROBE_DEBUG"] == "1" {
            print(String(format: "    [span] row %d black %.0f white %.0f low %.1f high %.1f -> %d..%d",
                         row, blackLevel, whiteLevel, low, high, lowX, highX))
        }
        return Double(highX - lowX)
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

        let library: MTLLibrary
        do {
            library = try MetalFrostRenderer.makeShaderLibrary(device: device)
        } catch {
            fail("shader library unavailable: \(error)")
        }
        print("library functions:", library.functionNames.sorted().joined(separator: ", "))
        for name in ["frost_vertex", "frost_vertex_flat", "frost_copy", "frost_fragment"] {
            guard library.makeFunction(name: name) != nil else {
                fail("shader function '\(name)' missing from the library")
            }
        }
        print("shader functions: OK")

        let uniformStride = MemoryLayout<FrostUniforms>.stride
        print("uniform block: \(uniformStride) bytes")
        guard uniformStride == 48 else {
            fail("FrostUniforms is \(uniformStride) bytes; the shader expects three 16-byte rows (48)")
        }

        guard let measure = makeMeasureFrame(),
              let white = makeWhiteFrame(),
              let edge = makeEdgeFrame(),
              let preview = makePreviewFrame() else {
            fail("could not create the test frames")
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let outputDirectory = ProcessInfo.processInfo.environment["MACDUO_PROBE_OUT"]

        Task { @MainActor in
            // The probe writes to its own defaults suite, so its experiments never
            // land in the settings of the installed app.
            let probeStore = UserDefaults(suiteName: "local.macduo.probe") ?? .standard
            probeStore.removePersistentDomain(forName: "local.macduo.probe")
            let settings = FrostSettings(defaults: probeStore)

            let renderer: MetalFrostRenderer
            do {
                renderer = try MetalFrostRenderer()
            } catch {
                fail("renderer init failed: \(error)")
            }
            print("pipelines: OK")
            print("")

            @MainActor func render(_ frame: CVPixelBuffer, progress: Double,
                                   mirror: Bool = false) -> [UInt8] {
                guard let target = makeTarget(device: device) else {
                    fail("could not allocate a render target")
                }
                guard renderer.renderOffscreen(pixelBuffer: frame,
                                               progress: progress,
                                               mirror: mirror,
                                               settings: settings,
                                               target: target,
                                               displayScale: 1) else {
                    fail("renderOffscreen returned false")
                }
                var pixels = [UInt8](repeating: 0, count: rowBytes * height)
                target.getBytes(&pixels, bytesPerRow: rowBytes,
                                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                return pixels
            }

            // MARK: 1. At 90° the picture is exactly the picture

            let pristine = pixels(of: measure)
            let untouched = render(measure, progress: 0)

            var mismatches = 0
            var worst = 0
            var compared = 0
            for y in stride(from: 0, to: height, by: 3) {
                for x in stride(from: 0, to: width, by: 3) {
                    for offset in [0, 1, 2] {
                        let difference = abs(Int(untouched[y * rowBytes + x * 4 + offset])
                                             - Int(pristine[y * rowBytes + x * 4 + offset]))
                        worst = max(worst, difference)
                        if difference > 2 { mismatches += 1 }
                        compared += 1
                    }
                }
            }
            let mismatchShare = Double(mismatches) / Double(max(compared, 1))
            print("== 1. with the lid at 90° the picture is exactly the picture")
            print(String(format: "identity: %.3f%% of samples differ by more than 2 (worst %d)",
                         mismatchShare * 100, worst))
            guard mismatchShare < 0.0005 else {
                fail(String(format: "the picture is modified at progress 0 (%.2f%% off, worst %d)",
                            mismatchShare * 100, worst))
            }
            guard red(untouched, 6, 640) > 250, red(untouched, height - 6, 640) < 5 else {
                fail("the picture is not upright")
            }
            print("orientation: top row white, bottom row black — upright")
            print("")

            // MARK: 2. The trapezoid: bottom edge pinned, top edge drawn in

            // Geometry on its own: no blur, no extras, so the outline is exact.
            settings.maxBlurRadius = 0
            settings.farDarkening = 0
            settings.frostOpacity = 0

            print("== 2. the trapezoid: the bottom edge does not move")
            print("  progress   row%   lit run          width   expected")
            for progress in [0.25, 0.5, 1.0] {
                let frame = render(white, progress: progress)
                let topScale = settings.topWidthRatio(at: progress)
                var previousCount = 0
                for fraction in [0.01, 0.25, 0.5, 0.75, 0.99] {
                    let row = min(max(Int(Double(height) * fraction), 2), height - 3)
                    let screenUp = 1 - (Double(row) + 0.5) / Double(height)
                    let expected = Double(width) * (1 + (topScale - 1) * screenUp)
                    let run = litRun(frame, row: row)
                    print(String(format: "  %8.2f   %4.0f%%   %5d … %-5d   %6d   %8.0f",
                                 progress, fraction * 100, run.first, run.last, run.count, expected))

                    guard abs(Double(run.count) - expected) <= 6 else {
                        fail(String(format: "at progress %.2f row %d the picture is %d px wide, expected %.0f",
                                    progress, row, run.count, expected))
                    }
                    // Straight sides: the run can only grow as the row descends.
                    guard run.count >= previousCount else {
                        fail("the sides are not straight at progress \(progress), row \(row)")
                    }
                    previousCount = run.count

                    if fraction == 0.99 {
                        guard run.count >= width - 6 else {
                            fail(String(format: "the bottom edge moved at progress %.2f (%d of %d px)",
                                        progress, run.count, width))
                        }
                    }
                }
                // Everything above the top edge, and the upper corners, are black.
                guard red(frame, 1, 1) == 0, green(frame, 1, 1) == 0, blue(frame, 1, 1) == 0,
                      red(frame, 1, width - 2) == 0 else {
                    fail("the space outside the trapezoid is not black at progress \(progress)")
                }
            }
            print("")

            // 镜像：能动的是底边，顶边钉在全宽。
            settings.mirror = true
            let mirrored = render(white, progress: 1.0, mirror: true)
            let topRun = litRun(mirrored, row: 2)
            let bottomRun = litRun(mirrored, row: height - 3)
            print(String(format: "mirrored: top %d px wide, bottom %d px (expect full width on top, "
                         + "%.0f%% at the bottom)", topRun.count, bottomRun.count,
                         100 * settings.topWidthRatio(at: 1)))
            guard topRun.count >= width - 6 else {
                fail("the mirrored shape does not pin the top edge (\(topRun.count) px)")
            }
            guard abs(Double(bottomRun.count) - Double(width) * settings.topWidthRatio(at: 1)) <= 6 else {
                fail("the mirrored shape does not narrow the bottom edge (\(bottomRun.count) px)")
            }
            settings.mirror = false

            settings.maxBlurRadius = 72

            // MARK: 3. The blur ramp: heaviest at the top, nothing at the hinge

            let progress = 1.0
            let blurred = render(measure, progress: progress)
            let edgeBlurred = render(edge, progress: progress)

            print("== 3. the blur ramp: heaviest at the top, nothing at the hinge")
            print("  row%   wanted sigma   measured sigma   detail kept")
            var sigmas: [Double] = []
            var wanted: [Double] = []
            for fraction in [0.02, 0.25, 0.5, 0.75, 0.98] {
                let row = min(max(Int(Double(height) * fraction), 4), height - 5)
                let screenUp = 1 - (Double(row) + 0.5) / Double(height)
                // The blur is done in picture space, and the trapezoid squeezes
                // the picture horizontally, so the width seen on screen is the
                // radius times the local horizontal scale.
                let scale = 1 + (settings.topWidthRatio(at: progress) - 1) * screenUp
                let expected = settings.maxBlurRadius * progress
                    * pow(screenUp, settings.blurFalloff) * scale
                let measured = transitionWidth(edgeBlurred, row: row) / 2.563
                let reference = detail(pristine, row: row)
                let ratio = reference > 0.0001 ? detail(blurred, row: row) / reference : 1
                sigmas.append(measured)
                wanted.append(expected)
                print(String(format: "%5.0f%%   %12.1f   %14.1f   %9.1f%%",
                             fraction * 100, expected, measured, ratio * 100))
            }
            print("")

            for index in 1..<sigmas.count {
                guard sigmas[index] < sigmas[index - 1] else {
                    fail(String(format: "the blur does not weaken towards the hinge: %.1f px then %.1f px",
                                sigmas[index - 1], sigmas[index]))
                }
                guard sigmas[index - 1] > wanted[index - 1] * 0.6,
                      sigmas[index - 1] < wanted[index - 1] * 1.6 || wanted[index - 1] < 1.5 else {
                    fail(String(format: "the blur near the top is %.1f px, wanted about %.1f px",
                                sigmas[index - 1], wanted[index - 1]))
                }
            }
            guard sigmas[0] > 45 else {
                fail(String(format: "the top of the picture is barely blurred (sigma %.1f px)", sigmas[0]))
            }
            guard sigmas[sigmas.count - 1] < 2.0 else {
                fail(String(format: "the hinge is not sharp (sigma %.1f px)", sigmas[sigmas.count - 1]))
            }
            print("ramp: strongest at the top, monotone down to a sharp hinge")
            print("")

            // MARK: 4. Preview frames, for eyeballing the effect

            if let outputDirectory {
                try? FileManager.default.createDirectory(atPath: outputDirectory,
                                                         withIntermediateDirectories: true)
                for (name, value) in [("lid-90", 0.0), ("lid-67", 0.25), ("lid-45", 0.5),
                                      ("lid-22", 0.75), ("lid-00", 1.0)] {
                    guard let target = makeTarget(device: device) else { break }
                    _ = renderer.renderOffscreen(pixelBuffer: preview,
                                                 progress: value,
                                                 settings: settings,
                                                 target: target,
                                                 displayScale: 1)
                    let path = "\(outputDirectory)/\(name).png"
                    try? writePNG(texture: target, to: path)
                    print("wrote \(path)")
                }
            }

            // MARK: 4b. Optional diagnostics: the sensor and the angle mapping

            if ProcessInfo.processInfo.environment["MACDUO_PROBE_SENSOR"] == "1" {
                let sensor = LidAngleSensor()
                sensor.start()
                var samples: [Double] = []
                for _ in 0..<30 {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    samples.append(sensor.angle)
                }
                let low = samples.min() ?? 0
                let high = samples.max() ?? 0
                print("")
                print("== sensor")
                print(String(format: "status: %@", sensor.statusText))
                print(String(format: "live reading over 3 s: %.1f° … %.1f° (last %.1f°)",
                             low, high, samples.last ?? 0))
                print("A lid being looked at reads roughly 100…135°; a reading near 0 means "
                      + "the sensor reports the opposite way round.")
            }

            if ProcessInfo.processInfo.environment["MACDUO_PROBE_MAP"] == "1" {
                print("")
                print("== angle -> progress (the effect lives in 0–90°)")
                print("   angle   progress   top edge   blur at the far edge")
                for angle in [135.0, 120, 111, 100, 95, 90, 80, 75, 60, 45, 30, 15, 0] {
                    let value = settings.progress(for: angle)
                    print(String(format: "%8.0f   %8.2f   %7.0f%%   %12.0f pt",
                                 angle, value,
                                 100 * settings.topWidthRatio(at: value),
                                 settings.blurRadius(at: value)))
                }
                // 效果区间是盖角 0–90°：生效角度及以上为零，满强度角度为 1，中间单调。
                for angle in [settings.activationAngle, settings.activationAngle + 10, 135, 180] {
                    guard settings.progress(for: angle) == 0 else {
                        fail(String(format: "progress at %.0f° is %.3f, expected 0 "
                                    + "(the effect lives between %.0f° and %.0f°)",
                                    angle, settings.progress(for: angle),
                                    settings.saturationAngle, settings.activationAngle))
                    }
                }
                for angle in [settings.saturationAngle, 0, -0] {
                    guard abs(settings.progress(for: angle) - 1) < 1e-9 else {
                        fail(String(format: "progress at %.0f° is %.3f, expected the full 1.0",
                                    angle, settings.progress(for: angle)))
                    }
                }
                // 0–90° 这一段必须真的有渐变（不是恒满、也不是恒零）。
                let middle = settings.progress(for: (settings.activationAngle + settings.saturationAngle) / 2)
                guard middle > 0.05, middle < 0.95 else {
                    fail(String(format: "the middle of the range reads %.2f, so the effect is not "
                                + "gradual across 0–90°", middle))
                }
                var previous = 0.0
                var previousAngle = settings.activationAngle + 5
                for angle in stride(from: settings.activationAngle, through: settings.saturationAngle, by: -2) {
                    let value = settings.progress(for: angle)
                    guard value >= previous - 1e-9 else {
                        fail(String(format: "progress is not monotone between %.0f° and %.0f°: "
                                    + "%.2f at %.0f° then %.2f at %.0f°",
                                    settings.activationAngle, settings.saturationAngle,
                                    previous, previousAngle, value, angle))
                    }
                    previous = value
                    previousAngle = angle
                }
                print(String(format: "zero at or above %.0f°, full at or below %.0f° — the effect "
                             + "lives in the 0–90° range, graded in between",
                             settings.activationAngle, settings.saturationAngle))
            }

            // MARK: 5. Optional on-screen smoke test

            if ProcessInfo.processInfo.environment["MACDUO_PROBE_FLASH"] == "1" {
                runVisualSmokeTest(settings: settings, buffer: preview)
            }

            // MARK: 5b. 真实捕获的反馈检查

            if ProcessInfo.processInfo.environment["MACDUO_PROBE_CAPTURE"] == "1" {
                await runCaptureFeedbackCheck()
            }

            // MARK: 6. Optional cost measurement

            if ProcessInfo.processInfo.environment["MACDUO_PROBE_BENCH"] == "1" {
                runBenchmark(renderer: renderer, frame: preview, settings: settings, device: device)
            }

            print("RESULT: all runtime checks passed")
            exit(0)
        }

        app.run()
    }

    // MARK: - Visual smoke test

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

        host.scheduleFrame(buffer)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        host.show(progress: 1.0)
        host.scheduleFrame(buffer)
        print("flash: on screen now — trapezoid, top edge blurred")
        RunLoop.main.run(until: Date().addingTimeInterval(3.0))

        host.close()
        print("flash: done")
    }

    // MARK: - Capture feedback check

    /// 覆盖窗口铺满整屏、显示的就是捕获画面：只要它被拍进捕获一帧，这一帧就会变成
    /// 下一帧的输入，模糊与压暗逐帧累积——屏幕上就会出现一层流动的糊和拖影。
    ///
    /// 这个检查用真实捕获复现这件事：先放一个纯红窗口占满内建屏，再抓几帧，然后看
    /// 捕获里有没有那块红。有红 = 自己被拍了进去 = 反馈。
    @MainActor
    static func runCaptureFeedbackCheck() async {
        print("")
        print("== 5b. capture feedback check")
        guard CaptureEngine.hasScreenRecordingPermission else {
            print("skipped: 没有屏幕录制权限，先在系统设置里授权再跑")
            return
        }
        guard let screen = DisplayResolver.builtInScreen else {
            print("skipped: 找不到内建屏幕")
            return
        }

        // 一个刺眼的纯红窗口，充当覆盖层。
        let probeWindow = NSWindow(contentRect: screen.frame,
                                   styleMask: [.borderless],
                                   backing: .buffered,
                                   defer: false,
                                   screen: screen)
        probeWindow.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        probeWindow.isOpaque = true
        probeWindow.hasShadow = false
        probeWindow.level = .normal
        probeWindow.collectionBehavior = [.canJoinAllSpaces, .stationary]
        probeWindow.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        // 用 app 真正用的那个过滤器做一次截图，看看红窗口有没有被排除掉。
        let filter: SCContentFilter
        do {
            filter = try await CaptureEngine.makeBuiltInFilter()
        } catch {
            print("skipped: 拿不到过滤器（\(error)）")
            probeWindow.orderOut(nil)
            return
        }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
        configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.captureResolution = .best

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                               configuration: configuration)
        } catch {
            print("skipped: 截图失败（\(error)）")
            probeWindow.orderOut(nil)
            return
        }
        probeWindow.orderOut(nil)
        print("screenshot: \(image.width)×\(image.height)")

        // 画进已知布局的位图，再读中心像素（BGRA）。
        let imageWidth = image.width
        let imageHeight = image.height
        var pixels = [UInt8](repeating: 0, count: imageWidth * imageHeight * 4)
        guard let context = CGContext(data: &pixels,
                                      width: imageWidth,
                                      height: imageHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: imageWidth * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            print("skipped: 无法建立位图上下文")
            return
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))

        let offset = ((imageHeight / 2) * imageWidth + (imageWidth / 2)) * 4
        let middleBlue = Int(pixels[offset])
        let middleGreen = Int(pixels[offset + 1])
        let middleRed = Int(pixels[offset + 2])
        print(String(format: "centre pixel BGRA = %d %d %d", middleBlue, middleGreen, middleRed))

        guard !(middleRed > 180 && middleGreen < 80 && middleBlue < 80) else {
            fail("覆盖窗口被拍进了捕获：中心像素是纯红。反馈没被排除，屏幕上会出现那层流动的糊")
        }
        print("ok: 覆盖窗口没有被拍进捕获，不会出现反馈")
    }

    // MARK: - Benchmark

    @MainActor
    static func runBenchmark(renderer: MetalFrostRenderer,
                             frame: CVPixelBuffer,
                             settings: FrostSettings,
                             device: MTLDevice) {
        let pixelSize = DisplayResolver.builtInScreen.map {
            CGSize(width: $0.frame.width * $0.backingScaleFactor,
                   height: $0.frame.height * $0.backingScaleFactor)
        } ?? CGSize(width: 3024, height: 1964)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalFrostRenderer.capturePixelFormat,
            width: Int(pixelSize.width),
            height: Int(pixelSize.height),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let target = device.makeTexture(descriptor: descriptor) else { return }

        print("")
        print(String(format: "== 6. cost at %d×%d, whole screen, 25 taps per pixel",
                     Int(pixelSize.width), Int(pixelSize.height)))

        for _ in 0..<3 {
            _ = renderer.renderOffscreen(pixelBuffer: frame, progress: 1, settings: settings,
                                         target: target, displayScale: 1)
        }

        let iterations = 30
        let start = CACurrentMediaTime()
        for _ in 0..<iterations {
            _ = renderer.renderOffscreen(pixelBuffer: frame, progress: 1, settings: settings,
                                         target: target, displayScale: 1)
        }
        let elapsed = CACurrentMediaTime() - start
        print(String(format: "composite: %.2f ms/frame — %.0f fps of headroom",
                     elapsed / Double(iterations) * 1000, Double(iterations) / elapsed))
        print("")
    }

    // MARK: - PNG output

    static func writePNG(texture: MTLTexture, to path: String) throws {
        let textureWidth = texture.width
        let textureHeight = texture.height
        let stride = textureWidth * 4
        var pixels = [UInt8](repeating: 0, count: stride * textureHeight)
        texture.getBytes(&pixels, bytesPerRow: stride,
                         from: MTLRegionMake2D(0, 0, textureWidth, textureHeight), mipmapLevel: 0)

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: textureWidth,
                                  height: textureHeight,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: stride,
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
    private var progress: Double = 0

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

    func show(progress: Double) {
        self.progress = progress
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
            let pointWidth = max(view.window?.frame.width ?? view.drawableSize.width, 1)
            _ = renderer.render(pixelBuffer: pending,
                                progress: progress,
                                settings: settings,
                                drawable: drawable,
                                viewSize: view.drawableSize,
                                displayScale: view.drawableSize.width / pointWidth)
        }
    }
}

RuntimeProbe.run()
