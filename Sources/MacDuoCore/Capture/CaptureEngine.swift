//
//  CaptureEngine.swift
//  MacDuo
//
//  Streams the built-in display through ScreenCaptureKit. The capture is the
//  "screen behind the glass": it stays put at its upright geometry, and the
//  frosted layer is what we actually paint on top of it.
//

import Foundation
import OSLog
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

    private static let logger = Logger(subsystem: "local.macduo.app", category: "capture")

    /// 构造"抓内建显示器、并把自己整个排除掉"的过滤器。
    ///
    /// 排除必须按**应用**做，不能按窗口列：覆盖窗口铺满整屏、显示的就是捕获画面，
    /// 只要它被拍进去一帧，这一帧就会成为下一帧的输入，模糊与压暗逐帧累积，屏幕上
    /// 会出现一层流动的糊、拖影和整体发灰——也就是那个"液体效果"。而覆盖窗口在效果
    /// 为零时是 orderOut 的，用 `onScreenWindowsOnly: true` 根本列不到它。
    ///
    /// 单独抽出来，是为了让验证程序能对同一个过滤器核对这件事。
    public static func makeBuiltInFilter() async throws -> SCContentFilter {
        guard let displayID = DisplayResolver.builtInDisplayID else {
            throw CaptureEngineError.noBuiltInDisplay
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                          onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureEngineError.noBuiltInDisplay
        }
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let ownApplication = content.applications.first { $0.processID == ownProcessID }
        if ownApplication == nil {
            logger.error("自己的进程不在可共享内容里，覆盖窗口可能被拍进捕获造成反馈")
        }
        return SCContentFilter(display: display,
                               excludingApplications: ownApplication.map { [$0] } ?? [],
                               exceptingWindows: [])
    }

    public override init() { super.init() }

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

            let filter = try await Self.makeBuiltInFilter()

            let configuration = SCStreamConfiguration()
            let pixelWidth = CGDisplayPixelsWide(displayID)
            let pixelHeight = CGDisplayPixelsHigh(displayID)

            configuration.width = Int(pixelWidth)
            configuration.height = Int(pixelHeight)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            // sRGB, explicitly, and the overlay tags its layer with the same
            // space, so the captured pixels reach the screen unchanged.
            configuration.colorSpaceName = CGColorSpace.sRGB
            // The cursor is drawn by the system on top of everything, so it must
            // not also be inside the captured picture: that would show up as a
            // second, lagging cursor.
            configuration.showsCursor = false
            // Shallow queue: every buffered frame is a frame of lag between the
            // screen and the picture the overlay shows.
            configuration.queueDepth = 3
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
