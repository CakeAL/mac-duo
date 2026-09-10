//
//  MenuBarLabel.swift
//  MacDuo
//

import SwiftUI
import MacDuoCore

/// The menu bar item: the live lid angle, tinted while the frost is on — and a
/// warning when the effect cannot show anything, which is the state that is
/// otherwise completely invisible (the overlay simply never appears).
struct MenuBarLabel: View {
    var controller: AppController

    var body: some View {
        let settings = controller.settings
        let angle = controller.angle
        let frosting = controller.isFrosting
        let missingPermission = !CaptureEngine.hasScreenRecordingPermission

        HStack(spacing: 4) {
            Image(systemName: missingPermission
                  ? "exclamationmark.triangle"
                  : (frosting ? "square.3.layers.3d.down.right" : "rectangle.portrait"))

            if settings.showInMenuBar {
                Text("\(angle, format: .number.precision(.fractionLength(0)))°")
                    .monospacedDigit()
            }
        }
        .foregroundStyle(missingPermission ? Color.orange : (frosting ? Color.accentColor : Color.primary))
        .help(helpText(angle: angle, missingPermission: missingPermission))
    }

    private func helpText(angle: Double, missingPermission: Bool) -> String {
        guard !missingPermission else {
            return "缺少屏幕录制权限，合盖时不会出现任何效果：系统设置 → 隐私与安全性 → 屏幕录制"
        }
        return String(format: "盖角 %.1f° · %@", angle, controller.sensor.statusText)
    }
}
