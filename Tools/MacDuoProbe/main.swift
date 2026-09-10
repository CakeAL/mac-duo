//
//  main.swift
//  MacDuo (verification harness)
//
//  Exercises everything the overlay needs at runtime, without opening a window:
//  the shader library, the pipelines, the fold projection, the blur ramp and the
//  shadow ramp. Run it with ./verify.sh — a broken shader or a Metal regression
//  then fails before the app is ever launched.
//
//  The four frames each isolate one claim:
//
//    measure  checker ramp + a white band at the top of the *picture* and a black
//             one at its bottom  -> where the picture lands after the fold
//    uniform  flat white          -> the shadow ramp and the panel's far edge
//    edge     left black, right white -> the blur *radius* per row, measured as a
//             transition width
//    preview  a stand-in desktop  -> the PNGs, for eyeballing
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

/// The projection the shader runs, in Swift, so the probe can say where a pixel
/// *should* land instead of only checking that something happened.
///
/// The panel is hinged along the display's bottom edge. A ray from the eye
/// through a display pixel meets the tipped panel at
///
///     h = D * s / (D * cos(phi) + (E - s) * sin(phi))
///
/// where `s` is the pixel's height above the hinge in screen heights, `h` is the
/// same distance measured along the panel, and D/E are the eye's distance and
/// height. h == s while the lid stands at 90°, and runs past 1 as it folds.
struct Fold {
    var eyeDistance: Double
    var eyeHeight: Double
    var progress: Double

    /// `motion` in the shader.
    var motion: Double {
        let p = min(max(progress, 0), 1)
        return p * p * (3 - 2 * p)
    }

    private var phi: Double { min(max(progress, 0), 1) * .pi / 2 }

    func panelDistance(screenUp s: Double) -> Double {
        let sinPhi = sin(phi), cosPhi = cos(phi)
        return eyeDistance * s / max(eyeDistance * cosPhi + (eyeHeight - s) * sinPhi, 1e-5)
    }

    /// Screen height at which the panel is this far from the hinge.
    func screenUp(panelDistance h: Double) -> Double {
        var low = 0.0
        var high = 1.0
        for _ in 0..<32 {
            let mid = (low + high) / 2
            if panelDistance(screenUp: mid) < h { low = mid } else { high = mid }
        }
        return low
    }
}

enum RuntimeProbe {

    // MARK: - Frames

    static let width = 1280
    static let height = 800
    static let rowBytes = width * 4

    /// The screen row a picture row ends up on, at a given fold.
    static func row(atPanelDistance h: Double, fold: Fold) -> Int {
        min(max(Int((1 - fold.screenUp(panelDistance: h)) * Double(height) + 0.5), 0), height - 1)
    }

    /// The panel distance a screen row actually shows. Rows are quantised, and
    /// near the far edge the ramps are steep enough for that to matter.
    static func panelDistance(ofRow row: Int, fold: Fold) -> Double {
        fold.panelDistance(screenUp: 1 - (Double(row) + 0.5) / Double(height))
    }

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

    /// The measuring frame. The first 24 rows of the *picture* are flat white and
    /// its last 24 rows are flat black, so where those two boundaries land on
    /// screen is a direct read-out of the projection.
    static func makeMeasureFrame() -> CVPixelBuffer? {
        makeBuffer { x, y in
            if y < 24 { return (255, 255, 255) }
            if y >= height - 24 { return (0, 0, 0) }
            let cell = ((x >> 2) ^ (y >> 2)) & 1 == 0
            return (UInt8((x * 255) / (width - 1)), cell ? 255 : 0, cell ? 0 : 255)
        }
    }

    /// Flat white: blurring it changes nothing, so what is left is the shadow
    /// ramp and the panel's far edge.
    static func makeUniformFrame() -> CVPixelBuffer? {
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
                total += abs(Double(green(buffer, row: y, x: x + 1)) - Double(green(buffer, row: y, x: x)))
                total += abs(Double(blue(buffer, row: y + 1, x: x)) - Double(blue(buffer, row: y, x: x)))
                samples += 2
            }
        }
        return samples > 0 ? total / Double(samples) : 0
    }

    /// Width of the black-to-white transition in a row, normalised between the
    /// row's own black and white levels. For a Gaussian of standard deviation s
    /// the 10...90 width is 2.563 s, so this reads the blur out directly.
    static func transitionWidth(_ buffer: [UInt8], row: Int) -> Double {
        let blackLevel = Double(red(buffer, row: row, x: 200))
        let whiteLevel = Double(red(buffer, row: row, x: width - 200))
        let span = whiteLevel - blackLevel
        guard span > 40 else { return -1 }

        let low = blackLevel + span * 0.1
        let high = blackLevel + span * 0.9
        var lowX = -1
        var highX = -1
        for x in (width / 2 - 360)..<(width / 2 + 360) {
            let value = Double(red(buffer, row: row, x: x))
            if lowX < 0, value >= low { lowX = x }
            if highX < 0, value >= high { highX = x }
        }
        guard lowX >= 0, highX >= 0 else { return -1 }
        return Double(highX - lowX)
    }

    /// What the shader should produce for a flat white pixel this far along the
    /// panel, straight from the reference's formulas.
    struct Ramps {
        var falloff: Double
        var hingeClear: Double
        var darkenStart: Double
        var darkenGain: Double
        var frostOpacity: Double
    }

    static func expectedGray(panelDistance h: Double, ramps: Ramps, motion: Double) -> Double {
        let hingeClear = min(max(ramps.hingeClear, 0), 0.8)
        let edge = min(max((h - hingeClear) / max(1 - hingeClear, 1e-4), 0), 1)
        let falloff = min(max(ramps.falloff, 0.05), 4)
        let ramp = pow(edge, falloff)

        let start = min(max(ramps.darkenStart, 0), 0.9)
        let darkenGradient = min(max((edge - start) / max(1 - start, 1e-4), 0), 1)
        let effect = motion * pow(darkenGradient, falloff)
        let shadow = min(1, effect * max(ramps.darkenGain, 0))

        var gray = 255.0 * (1 - shadow)
        let wash = min(1, max(ramps.frostOpacity, 0) * (motion * ramp))
        gray = gray * (1 - wash) + 255.0 * wash
        return gray
    }

    static func makeTarget(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
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
        for name in ["frost_vertex", "frost_copy", "frost_fragment"] {
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
              let uniform = makeUniformFrame(),
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

            let full = Ramps(falloff: settings.rampFalloff,
                             hingeClear: settings.hingeClearFraction,
                             darkenStart: settings.darkeningStart,
                             darkenGain: settings.farDarkening,
                             frostOpacity: settings.frostOpacity)

            /// Renders a frame and reads it back.
            @MainActor func render(_ frame: CVPixelBuffer, progress: Double) -> [UInt8] {
                guard let target = makeTarget(device: device, width: width, height: height) else {
                    fail("could not allocate a render target")
                }
                guard renderer.renderOffscreen(pixelBuffer: frame,
                                               progress: progress,
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
                fail(String(format: "the picture is modified at progress 0 (%.2f%% of samples off, worst %d)",
                            mismatchShare * 100, worst))
            }
            guard red(untouched, row: 6, x: 640) > 250,
                  red(untouched, row: height - 6, x: 640) < 5 else {
                fail("the picture is not upright")
            }
            print("orientation: top row white, bottom row black — upright")
            print("")

            // MARK: 2. The fold projection: the picture lands where it should

            // Geometry on its own: no blur and no shadow, so the boundaries
            // between the test frame's flat bands and its checker stay sharp and
            // the measured rows are the projection's, not the blur's.
            settings.blurRadiusPoints = 0
            settings.farDarkening = 0
            settings.frostOpacity = 0

            print("== 2. the fold: the picture is foreshortened towards the hinge")
            print("  progress   panel visible   top band: row (want)   bottom band: row (want)")

            /// The picture's white band ends at panel distance 1 - 24/h, and its
            /// black band starts 24 rows above the hinge.
            func bandRows(fold: Fold) -> (top: Int, bottom: Int) {
                (row(atPanelDistance: 1 - 24.5 / Double(height), fold: fold),
                 row(atPanelDistance: 24.5 / Double(height), fold: fold))
            }

            for progress in [0.25, 0.5, 0.75] {
                let fold = Fold(eyeDistance: settings.eyeDistance,
                                eyeHeight: settings.eyeHeight,
                                progress: progress)
                let frame = render(measure, progress: progress)
                let wanted = bandRows(fold: fold)
                let panelTopRow = row(atPanelDistance: 1, fold: fold)

                var firstPictureRow = height - 1
                for row in 0..<height where red(frame, row: row, x: 640) > 6 {
                    firstPictureRow = row
                    break
                }
                // The picture's far edge is antialiased into the black behind
                // it, so look for the band's far side only after the white band
                // has actually shown up.
                var topBandEnd = -1
                var seenBright = false
                for row in firstPictureRow..<height {
                    let value = green(frame, row: row, x: 640)
                    if value > 240 { seenBright = true; continue }
                    if seenBright, value < 200 { topBandEnd = row; break }
                }
                var bottomBandStart = -1
                for row in stride(from: height - 1, through: firstPictureRow, by: -1)
                where red(frame, row: row, x: 640) > 8 {
                    bottomBandStart = row
                    break
                }

                print(String(format: "  %8.2f   %8.0f%%          row %4d (%4d)        row %4d (%4d)",
                             progress,
                             100 * fold.screenUp(panelDistance: 1),
                             topBandEnd, wanted.top, bottomBandStart, wanted.bottom))

                guard topBandEnd >= 0, bottomBandStart >= 0 else {
                    fail("could not find the picture's bands at progress \(progress)")
                }
                guard abs(topBandEnd - wanted.top) <= 4 else {
                    fail(String(format: "the picture's top band lands at row %d, expected %d (progress %.2f)",
                                topBandEnd, wanted.top, progress))
                }
                guard abs(bottomBandStart - wanted.bottom) <= 4 else {
                    fail(String(format: "the picture's bottom band lands at row %d, expected %d (progress %.2f)",
                                bottomBandStart, wanted.bottom, progress))
                }
                // Above the panel there is only the space behind the lid.
                for row in 0..<max(panelTopRow - 2, 1) where red(frame, row: row, x: 640) != 0 {
                    fail("row \(row) above the panel is not black at progress \(progress)")
                }
            }
            print("")

            settings.blurRadiusPoints = 72
            settings.farDarkening = 2.0

            // MARK: 3. The blur ramp, measured along the panel

            let rampProgress = 0.5
            let rampFold = Fold(eyeDistance: settings.eyeDistance,
                                eyeHeight: settings.eyeHeight,
                                progress: rampProgress)
            let blurred = render(measure, progress: rampProgress)
            let edgeBlurred = render(edge, progress: rampProgress)

            print("== 3. the blur ramp along the panel: sharp at the hinge, frosted far out")
            print("  panel   screen row   wanted sigma   measured sigma   detail kept")
            var sigmas: [Double] = []
            var wanted: [Double] = []
            var panelDistances: [Double] = []
            for h in [0.06, 0.25, 0.45, 0.65, 0.85] {
                let screenRow = min(max(row(atPanelDistance: h, fold: rampFold), 4), height - 5)
                let actual = panelDistance(ofRow: screenRow, fold: rampFold)
                let expected = settings.blurRadiusPoints * rampFold.motion
                    * pow(actual, settings.rampFalloff)
                let measured = transitionWidth(edgeBlurred, row: screenRow) / 2.563
                let reference = detail(pristine, row: min(max(Int((1 - actual) * Double(height)),
                                                              0), height - 1))
                let ratio = reference > 0.0001 ? detail(blurred, row: screenRow) / reference : 1
                sigmas.append(measured)
                wanted.append(expected)
                panelDistances.append(actual)
                print(String(format: "%8.3f   %10d   %12.1f   %14.1f   %9.1f%%",
                             actual, screenRow, expected, measured, ratio * 100))
            }
            print("")

            for index in 1..<sigmas.count {
                guard sigmas[index] > sigmas[index - 1] else {
                    fail(String(format: "the blur radius does not grow along the panel: %.1f px at panel "
                                + "%.2f vs %.1f px nearer the hinge",
                                sigmas[index], panelDistances[index], sigmas[index - 1]))
                }
                // The prefilter level follows the picture's own screen-space
                // footprint, and the fold minifies the picture, so a folded row
                // blurs a little wider than its nominal radius. Half to 2.5x is
                // the honest band; the shape is what matters and it is monotone.
                guard sigmas[index] > wanted[index] * 0.6, sigmas[index] < wanted[index] * 1.6 else {
                    fail(String(format: "the blur at panel %.2f is %.1f px, wanted about %.1f px",
                                panelDistances[index], sigmas[index], wanted[index]))
                }
            }
            guard sigmas[0] < 2.0 else {
                fail(String(format: "the hinge is not sharp (sigma %.1f px)", sigmas[0]))
            }
            print("ramp: zero at the hinge, growing along the panel, monotone throughout")
            print("")

            // MARK: 4. The shadow ramp and the panel's far edge

            let flatSharp = render(uniform, progress: 0)
            let flatShut = render(uniform, progress: 1.0)
            let shut = Fold(eyeDistance: settings.eyeDistance,
                            eyeHeight: settings.eyeHeight,
                            progress: 1.0)

            print("== 4. the far panel falls into the dark, and behind the lid is black")
            print("   panel   screen row   rendered   expected")
            for h in [0.05, 0.2, 0.4, 0.6, 0.8, 0.95] {
                let row = min(max(row(atPanelDistance: h, fold: shut), 1), height - 2)
                let actual = panelDistance(ofRow: row, fold: shut)
                let rendered = Double(red(flatShut, row: row, x: width / 2))
                let expected = expectedGray(panelDistance: actual, ramps: full, motion: shut.motion)
                print(String(format: "%8.3f   %10d   %8.1f   %8.1f", actual, row, rendered, expected))
                guard abs(rendered - expected) <= 3 else {
                    fail(String(format: "the shadow at panel %.3f (row %d) is %.1f, expected %.1f",
                                actual, row, rendered, expected))
                }
            }

            let shutPanelTopRow = row(atPanelDistance: 1, fold: shut)
            guard shutPanelTopRow > 8, shutPanelTopRow < height - 8 else {
                fail("the panel's far edge lands at row \(shutPanelTopRow), which cannot be right when shut")
            }
            for row in 0..<max(shutPanelTopRow - 2, 1) where red(flatShut, row: row, x: width / 2) != 0 {
                fail("row \(row) above the panel is not black at full fold")
            }
            guard red(flatSharp, row: 4, x: width / 2) == 255,
                  red(flatSharp, row: height - 4, x: width / 2) == 255 else {
                fail("a flat frame is not passed through untouched at progress 0")
            }
            print(String(format: "panel edge: a shut lid leaves the bottom %.0f%% of the screen",
                         100 * shut.screenUp(panelDistance: 1)))
            print("shadow: matches the formula on the panel, hinge untouched, behind the lid black")
            print("")

            // MARK: 5. Preview frames, for eyeballing the effect

            if let outputDirectory {
                try? FileManager.default.createDirectory(atPath: outputDirectory,
                                                         withIntermediateDirectories: true)
                for (name, progress) in [("lid-90", 0.0),
                                         ("lid-67", 0.25),
                                         ("lid-45", 0.5),
                                         ("lid-22", 0.75),
                                         ("lid-00", 1.0)] {
                    guard let target = makeTarget(device: device, width: width, height: height) else { break }
                    _ = renderer.renderOffscreen(pixelBuffer: preview,
                                                 progress: progress,
                                                 settings: settings,
                                                 target: target,
                                                 displayScale: 1)
                    let path = "\(outputDirectory)/\(name).png"
                    try? writePNG(texture: target, to: path)
                    print("wrote \(path)")
                }
            }

            // MARK: 6. Optional on-screen smoke test

            if ProcessInfo.processInfo.environment["MACDUO_PROBE_FLASH"] == "1" {
                runVisualSmokeTest(settings: settings, buffer: preview)
            }

            // MARK: 7. Optional cost measurement

            if ProcessInfo.processInfo.environment["MACDUO_PROBE_BENCH"] == "1" {
                runBenchmark(renderer: renderer, frame: preview, settings: settings, device: device)
            }

            print("RESULT: all runtime checks passed")
            exit(0)
        }

        app.run()
    }

    // MARK: - Visual smoke test

    /// Puts the real overlay on screen for ~3 s at half fold: the picture
    /// foreshortened towards the hinge, sharp there, frosted and dark far out.
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

        host.show(progress: 0.5)
        host.scheduleFrame(buffer)
        print("flash: on screen now — half folded, foreshortened towards the hinge")
        RunLoop.main.run(until: Date().addingTimeInterval(3.0))

        host.close()
        print("flash: done")
    }

    // MARK: - Benchmark

    /// Times the composite at the real panel size (MACDUO_PROBE_BENCH=1).
    @MainActor
    static func runBenchmark(renderer: MetalFrostRenderer,
                             frame: CVPixelBuffer,
                             settings: FrostSettings,
                             device: MTLDevice) {
        let pixelSize = DisplayResolver.builtInScreen.map {
            CGSize(width: $0.frame.width * $0.backingScaleFactor,
                   height: $0.frame.height * $0.backingScaleFactor)
        } ?? CGSize(width: 3024, height: 1964)

        guard let target = makeTarget(device: device,
                                      width: Int(pixelSize.width),
                                      height: Int(pixelSize.height)) else { return }

        print("")
        print(String(format: "== 6. cost at %d×%d, whole screen, 25 taps per pixel",
                     Int(pixelSize.width), Int(pixelSize.height)))

        for _ in 0..<3 {
            _ = renderer.renderOffscreen(pixelBuffer: frame, progress: 0.5, settings: settings,
                                         target: target, displayScale: 1)
        }

        let iterations = 30
        let start = CACurrentMediaTime()
        for _ in 0..<iterations {
            _ = renderer.renderOffscreen(pixelBuffer: frame, progress: 0.5, settings: settings,
                                         target: target, displayScale: 1)
        }
        let elapsed = CACurrentMediaTime() - start
        print(String(format: "composite: %.2f ms/frame — %.0f fps of headroom",
                     elapsed / Double(iterations) * 1000, Double(iterations) / elapsed))
        print("")
    }

    // MARK: - PNG output

    /// Saves a texture as a PNG so the effect can be eyeballed without the GUI.
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
