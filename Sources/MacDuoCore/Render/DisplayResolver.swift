//
//  DisplayResolver.swift
//  MacDuo
//
//  Finds the built-in MacBook display. The effect is only ever applied to that
//  panel: on an external monitor there is no hinge, so there is nothing to mimic.
//

import AppKit
import CoreGraphics

public enum DisplayResolver {

    /// The CGDirectDisplayID of the built-in panel, if one is attached and awake.
    public static var builtInDisplayID: CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }

        // Prefer the panel macOS itself considers internal, then fall back to the
        // main display when it is at least not an obvious external screen.
        for id in displays where CGDisplayIsBuiltin(id) != 0 {
            return id
        }
        return nil
    }

    /// The NSScreen backing the built-in panel.
    public static var builtInScreen: NSScreen? {
        guard let id = builtInDisplayID else { return nil }
        return NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == id
        }
    }

    /// Short description used by the UI.
    public static var builtInScreenLabel: String {
        guard let screen = builtInScreen else { return "未检测到内建显示器" }
        let size = screen.frame.size
        let scale = screen.backingScaleFactor
        return "内建显示器 \(Int(size.width))×\(Int(size.height)) pt @\(Int(scale))x"
    }
}
