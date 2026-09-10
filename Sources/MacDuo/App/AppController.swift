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
    /// 0 = clear screen, 1 = fully frosted.
    private(set) var intensity: Double = 0
    private(set) var isFrosting = false

    /// True when the user asked for capture by hand from the menu.
    private(set) var isCapturePinned = false

    /// How long capture keeps running after the lid leaves the frost zone, so a
    /// wiggle around the threshold does not thrash the stream.
    private static let idleGrace: TimeInterval = 8

    @ObservationIgnored private static let logger = Logger(subsystem: "local.macduo.app", category: "controller")

    @ObservationIgnored private var lastActiveTime: TimeInterval = 0
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

    private func refresh() {
        settings.rawAngle = sensor.angle
        let raw = (sensor.angle + settings.angleOffset) * settings.angleScale
        angle = raw

        let value = settings.intensity(for: raw)
        intensity = value
        isFrosting = value > 0.001
        overlay.update(intensity: value)

        // A little above the activation angle, so the first frame is already
        // there by the time the effect actually becomes visible.
        let needsCapture = raw < settings.activationAngle + 10
        manageCaptureLifecycle(needsCapture: needsCapture)
    }
}
