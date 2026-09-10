//
//  CaptureEngine.swift
//  MacDuo
//
//  Streams the built-in display through ScreenCaptureKit. The capture is the
//  "screen behind the glass": it stays put at its upright geometry, and the
//  frosted layer is what we actually paint on top of it.
//

import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import CoreVideo
import QuartzCore

public enum CaptureEngineError: LocalizedError {
    case noBuiltInDisplay
    case permissionDenied
    case configurationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noBuiltInDisplay:
            "没有找到内建显示器（合盖模式或外接显示器模式下无法使用）。"
        case .permissionDenied:
            "缺少「屏幕录制」权限，无法读取内建显示器的画面。"
        case .configurationFailed(let reason):
            "无法启动画面捕获：\(reason)"
        }
    }
}

@MainActor
@Observable
public final class CaptureEngine: NSObject {

    public override init() { super.init() }


    public private(set) var isRunning = false
    public private(set) var lastError: String?
    public private(set) var displaySize = CGSize.zero
    /// Frames per second, for the diagnostics panel.
    public private(set) var measuredFPS: Double = 0

    /// Called on the main actor for every captured frame.
    @ObservationIgnored public var onFrame: ((CVPixelBuffer) -> Void)?

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var lastFrameTime: CFTimeInterval = 0
    @ObservationIgnored private var frameCounter = 0

    /// Screen Recording permission. Granting it needs to happen in System
    /// Settings; macOS usually applies it to a running app without a relaunch.
    public static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    public static func requestScreenRecordingPermission() {
        CGRequestScreenCaptureAccess()
    }

    public func start() async {
        guard !isRunning else { return }

        guard Self.hasScreenRecordingPermission else {
            lastError = CaptureEngineError.permissionDenied.localizedDescription
            return
        }

        do {
            guard let displayID = DisplayResolver.builtInDisplayID else {
                throw CaptureEngineError.noBuiltInDisplay
            }

            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )

            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureEngineError.noBuiltInDisplay
            }

            // Keep our own overlay out of the capture, otherwise it feeds back
            // on itself. Everything else is included, so normal windows are.
            let ownWindows = content.windows.filter { window in
                window.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
            }
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

            let configuration = SCStreamConfiguration()
            let pixelWidth = CGDisplayPixelsWide(displayID)
            let pixelHeight = CGDisplayPixelsHigh(displayID)

            configuration.width = Int(pixelWidth)
            configuration.height = Int(pixelHeight)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            configuration.queueDepth = 5
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true

            // The sensor polls at 60 Hz; matching that keeps motion glued to the lid.
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            if #available(macOS 14.0, *) {
                configuration.captureResolution = .best
                configuration.shouldBeOpaque = true
            }

            displaySize = CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))

            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            try await stream.startCapture()

            self.stream = stream
            isRunning = true
            lastError = nil
            startFrameClock()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isRunning = false
            stream = nil
        }
    }

    public func stop() async {
        stopFrameClock()
        guard let stream else {
            isRunning = false
            return
        }
        try? await stream.stopCapture()
        self.stream = nil
        isRunning = false
    }

    /// ScreenCaptureKit can drop out across display sleep or resolution changes.
    public func restart() async {
        await stop()
        await start()
    }

    // MARK: - Frame clock

    private func startFrameClock() {
        frameCounter = 0
        lastFrameTime = CACurrentMediaTime()
        measuredFPS = 0
    }

    private func stopFrameClock() {
        measuredFPS = 0
    }

    fileprivate func noteFrame() {
        frameCounter += 1
        let now = CACurrentMediaTime()
        let elapsed = now - lastFrameTime
        if elapsed >= 1.0 {
            measuredFPS = Double(frameCounter) / elapsed
            frameCounter = 0
            lastFrameTime = now
        }
    }
}

// MARK: - SCStreamOutput

extension CaptureEngine: SCStreamOutput {
    public nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete
        else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        MainActor.assumeIsolated { [weak self] in
            guard let self else { return }
            noteFrame()
            onFrame?(pixelBuffer)
        }
    }
}
