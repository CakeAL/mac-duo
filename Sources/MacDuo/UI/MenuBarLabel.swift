//
//  MenuBarLabel.swift
//  MacDuo
//

import SwiftUI
import MacDuoCore

/// The menu bar item: the live lid angle, tinted while the frost is on.
struct MenuBarLabel: View {
    var controller: AppController

    var body: some View {
        let settings = controller.settings
        let angle = controller.angle
        let frosting = controller.isFrosting

        HStack(spacing: 4) {
            Image(systemName: frosting ? "square.3.layers.3d.down.right" : "rectangle.portrait")

            if settings.showInMenuBar {
                Text("\(angle, format: .number.precision(.fractionLength(0)))°")
                    .monospacedDigit()
            }
        }
        .foregroundStyle(frosting ? Color.accentColor : Color.primary)
        .help("盖角 \(angle, format: .number.precision(.fractionLength(1)))° · \(controller.sensor.statusText)")
    }
}
