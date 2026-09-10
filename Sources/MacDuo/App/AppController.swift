//
//  AppController.swift
//  MacDuo
//
//  Wires the lid sensor to the frosted-glass overlay: above the activation
//  angle nothing happens at all, below it the overlay fades in and its intensity
//  tracks the hinge.
//

import Foundation
import AppKit
import OSLog
import MacDuoCore

@MainActor
@Observable
final class AppController {

    let sensor: LidAngleSensor
    let settings: FrostSettings
    let capture = CaptureEngine()
    let overlay: FrostOverlayController

    /// Latest lid angle after calibration.
    private(set) var angle: Double = 110
    /// 0 = the picture standing at 90°, 1 = fully folded.
    private(set) var progress: Double = 0
    private(set) var isFrosting = false

    /// True while the fold animation is being replayed on screen from the menu,
    /// without moving the lid.
    private(set) var isPreviewing = false

    /// True when the user asked for capture by hand from the menu.
    private(set) var isCapturePinned = false

    /// How long capture keeps running after the lid leaves the frost zone, so a
    /// wiggle around the threshold does not thrash the stream.
    private static let idleGrace: TimeInterval = 8

    /// One cycle of the preview animation, shaped like the folding reference:
    /// open, close, held closed, open again.
    private static let previewCycle: TimeInterval = 8.6
    private static let previewHold: TimeInterval = 1.2
    private static let previewMove: TimeInterval = 3.1

    @ObservationIgnored private static let logger = Logger(subsystem: "local.macduo.app", category: "controller")

    @ObservationIgnored private var lastActiveTime: TimeInterval = 0
    @ObservationIgnored private var lastTick: TimeInterval = 0
    @ObservationIgnored private var previewPhase: TimeInterval = 0
    @ObservationIgnored private var isStartingCapture = false
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    init() {
        let settings = FrostSettings()
        self.settings = settings
        self.sensor = LidAngleSensor()
        self.overlay = FrostOverlayController(settings: settings)

        angle = sensor.angle
    }

    // MARK: - Lifecycle

    func start() {
        sensor.start()
        overlay.start(capture: capture)

        // The UI needs its own clock: the overlay renders on captured frames, but
        // the menu bar read-out has to keep moving even when the lid is still.
        if tickTask == nil {
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.refresh()
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
        }

        refresh()
    }

    func shutdown() {
        tickTask?.cancel()
        tickTask = nil
        sensor.stop()
        overlay.stop()
        Task { await capture.stop() }
    }

    // MARK: - Capture control

    /// Manual override from the menu bar.
    func startCapture() async {
        isCapturePinned = true
        await beginCaptureIfPossible()
    }

    func stopCapture() async {
        isCapturePinned = false
        await capture.stop()
    }

    /// Starts the stream if it is not already running and permission allows it.
    /// Returns whether capture ended up running.
    @discardableResult
    private func beginCaptureIfPossible() async -> Bool {
        if capture.isRunning { return true }
        guard !isStartingCapture else { return false }

        guard CaptureEngine.hasScreenRecordingPermission else {
            if capture.lastError == nil {
                CaptureEngine.requestScreenRecordingPermission()
            }
            return false
        }

        isStartingCapture = true
        await capture.start()
        isStartingCapture = false

        if capture.isRunning {
            Self.logger.info("screen capture started")
            if !overlay.isRunning {
                overlay.start(capture: capture)
            }
            return true
        }

        let reason = capture.lastError ?? "unknown"
        Self.logger.error("screen capture failed: \(reason, privacy: .public)")
        return false
    }

    /// Capture only runs while it is useful. Grabbing a 6 MP display at 60 fps is
    /// expensive, so it starts the moment the lid enters the frost zone and stops
    /// again a few seconds after the lid is back up.
    private func manageCaptureLifecycle(needsCapture: Bool) {
        let now = CACurrentMediaTime()

        if needsCapture || isCapturePinned {
            lastActiveTime = now
            if !capture.isRunning && !isStartingCapture {
                Task { await beginCaptureIfPossible() }
            }
            return
        }

        guard capture.isRunning, !isStartingCapture else { return }
        if now - lastActiveTime > Self.idleGrace {
            Task { await capture.stop() }
        }
    }

    // MARK: - Effect state

    /// Replays the fold on the built-in display, so the effect can be seen
    /// without folding the machine. Capture has to be running for it: the
    /// overlay shows the captured picture, not an invented one.
    func startPreview() {
        guard !isPreviewing else { return }
        isPreviewing = true
        previewPhase = 0
        Self.logger.info("fold preview started")
    }

    func stopPreview() {
        guard isPreviewing else { return }
        isPreviewing = false
        previewPhase = 0
        Self.logger.info("fold preview stopped")
    }

    func togglePreview() {
        isPreviewing ? stopPreview() : startPreview()
    }

    /// Fold amount of the preview animation at a point in its cycle: open,
    /// shut, held, open again — a cosine at each end so the motion has no
    /// corners, the same shape as the reference's play button.
    static func previewProgress(at phase: TimeInterval) -> Double {
        let cycle = previewCycle
        let t = phase.truncatingRemainder(dividingBy: cycle)
        let hold = previewHold
        let move = previewMove
        switch t {
        case ..<hold:
            return 0
        case ..<(hold + move):
            return (1 - cos((t - hold) / move * .pi)) / 2
        case ..<(hold * 2 + move):
            return 1
        default:
            return (1 + cos((t - hold * 2 - move) / move * .pi)) / 2
        }
    }

    private func refresh() {
        settings.rawAngle = sensor.angle
        let raw = (sensor.angle + settings.angleOffset) * settings.angleScale
        angle = raw

        let now = CACurrentMediaTime()
        let elapsed = lastTick > 0 ? min(max(now - lastTick, 0), 0.25) : 0
        lastTick = now

        var target = settings.progress(for: raw)
        if isPreviewing {
            // Hold the animation until there is a picture to fold, otherwise the
            // overlay would blank the display for the first frames.
            if capture.isRunning {
                previewPhase += elapsed
                if previewPhase >= Self.previewCycle {
                    // One fold and back, then hand the screen back on its own: a
                    // preview that loops forever is a screen that never stops
                    // rearranging itself.
                    stopPreview()
                } else {
                    target = Self.previewProgress(at: previewPhase)
                }
            } else {
                target = 0
            }
        }

        // The sensor is already smoothed; this second, time-based ease is what
        // turns a quick flick of the lid into one continuous fold animation.
        let timeConstant = max(settings.responseSmoothing, 0.001)
        let alpha = elapsed > 0 ? 1 - exp(-elapsed / timeConstant) : 1
        progress += (target - progress) * alpha
        if abs(target - progress) < 0.0008 { progress = target }

        isFrosting = progress > 0.001
        overlay.update(progress: progress, mirror: settings.mirror)

        // 只要盖角压到生效角度附近，效果就可能出现，捕获就开着。
        let needsCapture = isPreviewing || raw < settings.activationAngle + 10
        manageCaptureLifecycle(needsCapture: needsCapture)
    }
}
