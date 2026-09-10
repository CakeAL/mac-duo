//
//  FrostOverlayController.swift
//  MacDuo
//
//  A borderless, always-on overlay pinned to the built-in display that paints a
//  progressively frosted copy of the screen. When the lid is open far enough the
//  overlay hides itself completely and the untouched desktop shows through.
//

import AppKit
import MetalKit
import QuartzCore
import CoreVideo

@MainActor
public final class FrostOverlayController: NSObject {

    public private(set) var isRunning = false
    public private(set) var renderFPS: Double = 0

    @ObservationIgnored private let settings: FrostSettings
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var metalView: MTKView?
    @ObservationIgnored private var renderer: MetalFrostRenderer?
    @ObservationIgnored private var capture: CaptureEngine?
    @ObservationIgnored private var pendingFrame: CVPixelBuffer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private var currentProgress: Double = 0
    /// 展开侧是否镜像：顶端钉住、底端收窄。
    private var currentMirror = false
    private var lastDrawnIntensity: Double = -1
    private var needsRedraw = false
    private var frameCounter = 0
    private var lastFPSStamp: CFTimeInterval = 0

    public init(settings: FrostSettings) {
        self.settings = settings
        super.init()
    }

    // MARK: - Lifecycle

    public func start(capture: CaptureEngine) {
        guard !isRunning else { return }
        self.capture = capture

        guard let screen = DisplayResolver.builtInScreen else {
            NSLog("[MacDuo] No built-in screen available for the overlay.")
            return
        }

        do {
            let renderer = try MetalFrostRenderer()
            self.renderer = renderer

            let view = MTKView(frame: screen.frame, device: renderer.device)
            view.delegate = self
            view.colorPixelFormat = MetalFrostRenderer.capturePixelFormat
            view.framebufferOnly = true
            view.autoResizeDrawable = true
            view.enableSetNeedsDisplay = true
            view.isPaused = true
            view.preferredFramesPerSecond = 60
            view.layer?.isOpaque = true
            // The overlay shows captured pixels unchanged, so the layer has to be
            // tagged with the space those pixels are encoded in. Untagged, macOS
            // treats the numbers as belonging to the display, and the moment the
            // overlay appears the whole screen looks washed out — the "it just
            // goes grey" at 90°.
            (view.layer as? CAMetalLayer)?.colorspace = Self.overlayColorSpace
            metalView = view

            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.contentView = view
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.level = .normal
            window.isMovable = false
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.animationBehavior = .none
            window.title = "MacDuo Frost"
            self.window = window

            capture.onFrame = { [weak self] buffer in
                self?.handle(frame: buffer)
            }

            installObservers()
            isRunning = true
        } catch {
            NSLog("[MacDuo] Overlay failed to start: \(error)")
            isRunning = false
        }
    }

    public func stop() {
        removeObservers()
        capture?.onFrame = nil
        pendingFrame = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        metalView = nil
        renderer?.invalidateCache()
        renderer = nil
        isRunning = false
        renderFPS = 0
        lastDrawnIntensity = -1
    }

    /// Tears the overlay down and builds it again; used when the built-in display
    /// changes geometry or the app wakes from sleep.
    public func rebuild(capture: CaptureEngine) {
        stop()
        start(capture: capture)
    }

    /// The colour space of the captured frames, as configured in CaptureEngine.
    private static let overlayColorSpace = CGColorSpace(name: CGColorSpace.sRGB)

    // MARK: - Intensity

    /// - Parameter progress: 0 hides the overlay entirely, 1 is fully folded.
    public func update(progress: Double, mirror: Bool = false) {
        guard isRunning else { return }
        // Below this the effect is not visible, and showing a captured copy of the
        // screen for nothing would only add the capture's lag to everything.
        let clamped = min(max(progress, 0), 1) < 0.004 ? 0 : min(max(progress, 0), 1)
        guard abs(clamped - currentProgress) > 0.0008 else { return }
        currentProgress = clamped
        currentMirror = mirror
        needsRedraw = true

        if clamped <= 0 {
            window?.orderOut(nil)
        } else {
            presentIfPossible()
        }
        metalView?.setNeedsDisplay(metalView?.bounds ?? .zero)
    }

    /// Shows the overlay, but only once there is a captured frame to paint.
    ///
    /// Ordering it in earlier would put an opaque black window over the desktop
    /// for the frame or two it takes the stream to deliver its first picture.
    private func presentIfPossible() {
        guard pendingFrame != nil, window?.isVisible != true else { return }
        window?.orderFrontRegardless()
    }

    // MARK: - Frames

    private func handle(frame: CVPixelBuffer) {
        guard isRunning, currentProgress > 0 else { return }
        pendingFrame = frame
        needsRedraw = true
        presentIfPossible()
        metalView?.setNeedsDisplay(metalView?.bounds ?? .zero)
    }

    // MARK: - System observers

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let capture = self.capture else { return }
                self.rebuild(capture: capture)
            }
        })

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let capture = self.capture else { return }
                self.pendingFrame = nil
                Task { await capture.restart() }
            }
        })
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}

// MARK: - MTKViewDelegate

extension FrostOverlayController: MTKViewDelegate {

    public nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            guard let renderer, let window, window.isVisible else { return }
            guard currentProgress > 0 || lastDrawnIntensity != 0 else { return }
            guard needsRedraw else { return }
            guard let frame = pendingFrame,
                  let drawable = view.currentDrawable
            else { return }

            let settings = self.settings

            let rendered = renderer.render(
                pixelBuffer: frame,
                progress: currentProgress,
                mirror: currentMirror,
                settings: settings,
                drawable: drawable,
                viewSize: view.drawableSize
            )

            if rendered {
                needsRedraw = false
                lastDrawnIntensity = currentProgress
                noteRenderedFrame()
            }
        }
    }

    private func noteRenderedFrame() {
        frameCounter += 1
        let now = CACurrentMediaTime()
        if now - lastFPSStamp >= 1.0 {
            renderFPS = Double(frameCounter) / (now - lastFPSStamp)
            frameCounter = 0
            lastFPSStamp = now
        }
    }
}
