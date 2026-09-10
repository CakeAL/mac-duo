//
//  MacDuoApp.swift
//  MacDuo
//
//  A menu bar app with no main window: the whole point is the overlay that
//  appears over the built-in display when the lid comes down.
//

import SwiftUI
import MacDuoCore
import AppKit
import OSLog

/// Structured logging for the app. `os.Logger` is used instead of `NSLog`
/// because `NSLog` cannot safely format Swift strings.
enum Shell {
    private static let logger = Logger(subsystem: "local.macduo.app", category: "launch")

    static func log(sensor: String, angle: Double, screen: String, capturePermission: Bool) {
        logger.info("""
            launch sensor=\(sensor, privacy: .public) angle=\(angle, privacy: .public) \
            screen=\(screen, privacy: .public) \
            capturePermission=\(capturePermission ? "granted" : "missing", privacy: .public)
            """)
    }
}

@main
struct MacDuoApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(controller: delegate.controller)
        } label: {
            MenuBarLabel(controller: delegate.controller)
        }
        .menuBarExtraStyle(.window)

        Window("MacDuo 设置", id: MacDuoSceneID.settings) {
            SettingsView(controller: delegate.controller)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 520, height: 520)
        .windowResizability(.contentSize)
        .commandsRemoved()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        controller.start()

        // One concise line in the log makes a build checkable from a terminal:
        //   log stream --predicate 'subsystem == "local.macduo.app"'
        Shell.log(
            sensor: controller.sensor.statusText,
            angle: controller.angle,
            screen: DisplayResolver.builtInScreenLabel,
            capturePermission: CaptureEngine.hasScreenRecordingPermission
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
