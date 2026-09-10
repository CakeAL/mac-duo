//
//  MenuBarPanel.swift
//  MacDuo
//

import SwiftUI
import MacDuoCore

/// The dropdown attached to the menu bar item. Kept deliberately small: the full
/// set of knobs lives in the settings window.
struct MenuBarPanel: View {
    var controller: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            quickControls
            Divider()
            actions
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 300)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.angle, format: .number.precision(.fractionLength(1)))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                + Text("°").font(.system(size: 15, weight: .semibold, design: .rounded))

                Text(controller.sensor.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                StatusPill(
                    text: controller.capture.isRunning ? "捕获中" : "未捕获",
                    isGood: controller.capture.isRunning
                )
                StatusPill(
                    text: controller.isFrosting ? "磨砂中" : "清晰",
                    isGood: !controller.isFrosting
                )
            }
        }
    }

    private var quickControls: some View {
        @Bindable var settings = controller.settings

        return VStack(alignment: .leading, spacing: 8) {
            Toggle("启用磨砂效果", isOn: $settings.isEnabled)

            LabeledSlider(
                title: "远端最强模糊",
                value: $settings.blurRadiusPoints,
                range: 0...200,
                format: "%.0f pt"
            )

            LabeledSlider(
                title: "生效角度",
                value: $settings.activationAngle,
                range: 40...140,
                format: "%.0f°"
            )
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !CaptureEngine.hasScreenRecordingPermission {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("缺少屏幕录制权限：合盖时不会出现任何效果。授权后需要重新启动一次本应用。")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("打开屏幕录制设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Button("打开设置…") {
                openWindow(id: MacDuoSceneID.settings)
                NSApp.activate(ignoringOtherApps: true)
            }

            Button(controller.isPreviewing ? "停止开合预览" : "预览开合动画") {
                if !controller.isPreviewing,
                   !CaptureEngine.hasScreenRecordingPermission {
                    CaptureEngine.requestScreenRecordingPermission()
                }
                controller.togglePreview()
            }

            if controller.capture.isRunning {
                Button("停止画面捕获") {
                    Task { await controller.stopCapture() }
                }
            } else {
                Button("开始画面捕获") {
                    Task {
                        if !CaptureEngine.hasScreenRecordingPermission {
                            CaptureEngine.requestScreenRecordingPermission()
                        }
                        await controller.startCapture()
                    }
                }
            }

            Button("重新检测传感器") {
                controller.sensor.restart()
            }
        }
        .buttonStyle(.link)
    }

    private var footer: some View {
        HStack {
            Text(DisplayResolver.builtInScreenLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("退出") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.link)
        }
    }
}

// MARK: - Shared bits

struct StatusPill: View {
    let text: String
    let isGood: Bool

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill((isGood ? Color.green : Color.orange).opacity(0.18))
            )
            .foregroundStyle(isGood ? Color.green : Color.orange)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: format, value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}
