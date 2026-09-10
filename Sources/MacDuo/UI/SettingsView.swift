//
//  SettingsView.swift
//  MacDuo
//

import SwiftUI
import MacDuoCore

enum MacDuoSceneID {
    static let settings = "macduo.settings"
}

struct SettingsView: View {
    var controller: AppController
    @State private var selection: Tab = .effect

    enum Tab: String, CaseIterable, Identifiable {
        case effect, angle, hardware
        var id: String { rawValue }
        var label: String {
            switch self {
            case .effect: "效果"
            case .angle: "角度"
            case .hardware: "硬件与权限"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selection) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            ScrollView {
                Group {
                    switch selection {
                    case .effect: EffectPane(controller: controller)
                    case .angle: AnglePane(controller: controller)
                    case .hardware: HardwarePane(controller: controller)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 540, height: 580)
    }
}

// MARK: - Effect

private struct EffectPane: View {
    var controller: AppController

    var body: some View {
        @Bindable var settings = controller.settings

        return VStack(alignment: .leading, spacing: 18) {
            FoldPreview(controller: controller)

            SectionCard("折叠形变（画面仍在 90° 的位置）") {
                LabeledSlider(
                    title: "梯形倾斜量",
                    value: $settings.trapezoidAmount,
                    range: 0...0.45,
                    format: "%.2f"
                )
                Text(String(format: "最强时顶端宽度 = 底端的 %.0f%%。数值 0 时画面就是普通矩形。",
                            100 * settings.topToBottomWidthRatio))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                LabeledSlider(
                    title: "画面后方的暗度",
                    value: $settings.backgroundDim,
                    range: 0...1,
                    format: "%.2f"
                )
                Text("梯形之外露出来的部分，用屏幕边缘的颜色延续并压暗，代表折叠后露出的背景。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            SectionCard("毛玻璃（上强下弱）") {
                LabeledSlider(title: "顶端最强模糊", value: $settings.maxBlurPoints, range: 0...220, format: "%.0f pt")
                LabeledSlider(title: "底端基础模糊", value: $settings.minBlurPoints, range: 0...40, format: "%.1f pt")
                LabeledSlider(
                    title: "底部保持清晰的高度",
                    value: $settings.nearClearFraction,
                    range: 0...0.6,
                    format: "%.2f"
                )
                Text("从铰链这一侧算起，这一段高度基本清晰，往上才开始起雾。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                LabeledSlider(title: "层次融合", value: $settings.frostSoftness, range: 0...1, format: "%.2f")
                Text("0 = 三层模糊分明，像叠起来的玻璃；1 = 融成一条连续渐变。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            SectionCard("质感") {
                LabeledSlider(title: "白雾浓度", value: $settings.frostOpacity, range: 0...0.5, format: "%.2f")
                LabeledSlider(title: "保留色彩", value: $settings.frostSaturation, range: 0...1, format: "%.2f")
                LabeledSlider(title: "压暗", value: $settings.frostDim, range: 0...0.4, format: "%.2f")
            }
        }
    }
}

// MARK: - Angle

private struct AnglePane: View {
    var controller: AppController

    var body: some View {
        @Bindable var settings = controller.settings

        return VStack(alignment: .leading, spacing: 18) {
            SectionCard("触发条件") {
                LabeledSlider(title: "开始生效角度", value: $settings.activationAngle, range: 40...150, format: "%.0f°")
                LabeledSlider(title: "达到最强角度", value: $settings.saturationAngle, range: 0...120, format: "%.0f°")

                if settings.saturationAngle >= settings.activationAngle {
                    Label(
                        "「达到最强角度」需要小于「开始生效角度」，否则效果不会出现。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Text("角度从 \(settings.activationAngle, format: .number.precision(.fractionLength(0)))° 合到 \(settings.saturationAngle, format: .number.precision(.fractionLength(0)))° 的过程中，倾斜与磨砂由无到最强。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledSlider(
                    title: "响应曲线",
                    value: $settings.responseCurve,
                    range: 0.3...3.0,
                    format: "%.2f"
                )
                Text("大于 1 时，前半段保持轻微，接近合上时才快速加深。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            SectionCard("当前状态") {
                ReadoutRow(label: "原始读数", value: String(format: "%.1f°", settings.rawAngle))
                ReadoutRow(label: "校准后角度", value: String(format: "%.1f°", controller.angle))
                ReadoutRow(label: "效果强度", value: String(format: "%.2f", controller.intensity))
                ReadoutRow(
                    label: "当前梯形比例",
                    value: String(format: "%.0f%%", 100 / (1 + settings.trapezoidAmount * controller.intensity))
                )
            }
        }
    }
}

// MARK: - Hardware

private struct HardwarePane: View {
    var controller: AppController

    var body: some View {
        @Bindable var settings = controller.settings

        return VStack(alignment: .leading, spacing: 18) {
            SectionCard("盖角传感器") {
                ReadoutRow(label: "状态", value: controller.sensor.statusText)
                ReadoutRow(label: "原始读数", value: String(format: "%.1f°", settings.rawAngle))

                HStack {
                    Button("重新检测") { controller.sensor.restart() }
                    Spacer()
                }

                Divider()

                LabeledSlider(title: "角度偏移", value: $settings.angleOffset, range: -60...60, format: "%.0f°")
                LabeledSlider(title: "角度倍率", value: $settings.angleScale, range: -2...2, format: "%.2f")
                Text("如果合上盖子时读数不是接近 0，用偏移修正；如果读数方向是反的，把倍率设为 -1。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            SectionCard("画面捕获") {
                ReadoutRow(label: "状态", value: controller.capture.isRunning ? "运行中" : "已停止")
                ReadoutRow(label: "分辨率", value: controller.capture.displaySize == .zero
                           ? "—"
                           : "\(Int(controller.capture.displaySize.width))×\(Int(controller.capture.displaySize.height))")
                ReadoutRow(label: "捕获帧率", value: controller.capture.isRunning
                           ? String(format: "%.0f fps", controller.capture.measuredFPS)
                           : "—")
                ReadoutRow(label: "渲染帧率", value: controller.overlay.isRunning
                           ? String(format: "%.0f fps", controller.overlay.renderFPS)
                           : "—")
                ReadoutRow(label: "权限", value: CaptureEngine.hasScreenRecordingPermission ? "已授权" : "未授权")

                if let error = controller.capture.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    if controller.capture.isRunning {
                        Button("停止捕获") { Task { await controller.stopCapture() } }
                    } else {
                        Button("开始捕获") {
                            Task {
                                if !CaptureEngine.hasScreenRecordingPermission {
                                    CaptureEngine.requestScreenRecordingPermission()
                                }
                                await controller.startCapture()
                            }
                        }
                    }
                    Button("打开屏幕录制设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Spacer()
                }

                Text("捕获只在盖子压到生效角度附近时才运行，回到上面 8 秒后自动停止。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Building blocks

struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }
}

struct ReadoutRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
        }
    }
}

/// A live diagram of what the overlay is doing: the screen rectangle, the
/// trapezoid the picture is folded into at the current angle, and how the frost
/// ramps up from the hinge to the top.
private struct FoldPreview: View {
    var controller: AppController

    var body: some View {
        let settings = controller.settings
        let intensity = controller.intensity
        let fold = settings.trapezoidAmount * intensity

        return SectionCard("折叠预览") {
            HStack(alignment: .top, spacing: 14) {
                Canvas { context, size in
                    let fullWidth = size.width
                    let inset = fold / (1 + fold) * fullWidth / 2

                    // Outside the trapezoid is the surface behind the panel.
                    context.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .color(.black.opacity(0.55))
                    )

                    var clip = Path()
                    clip.move(to: CGPoint(x: inset, y: 0))
                    clip.addLine(to: CGPoint(x: fullWidth - inset, y: 0))
                    clip.addLine(to: CGPoint(x: fullWidth, y: size.height))
                    clip.addLine(to: CGPoint(x: 0, y: size.height))
                    clip.closeSubpath()

                    var content = context
                    content.clip(to: clip)
                    let stripes = 14
                    for index in 0..<stripes {
                        let x = fullWidth * Double(index) / Double(stripes)
                        content.fill(
                            Path(CGRect(x: x, y: 0, width: fullWidth / Double(stripes) / 2, height: size.height)),
                            with: .color(.accentColor.opacity(0.28))
                        )
                    }
                    if intensity > 0.001 {
                        content.fill(
                            Path(CGRect(origin: .zero, size: size)),
                            with: .linearGradient(
                                Gradient(stops: [
                                    .init(color: .white.opacity(0), location: 0),
                                    .init(color: .white.opacity(0.9 * intensity), location: 1),
                                ]),
                                startPoint: CGPoint(x: 0, y: size.height),
                                endPoint: CGPoint(x: 0, y: 0)
                            )
                        )
                    }

                    context.stroke(clip, with: .color(.accentColor), lineWidth: 1.2)
                }
                .frame(width: 200, height: 126)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    ReadoutRow(label: "强度", value: String(format: "%.2f", intensity))
                    ReadoutRow(label: "顶端宽度", value: String(format: "%.0f%%", 100 / (1 + fold)))
                    ReadoutRow(label: "上/下模糊", value: String(format: "%.0f / %.0f pt",
                                                                settings.maxBlurPoints, settings.minBlurPoints))
                    Text("示意图：面板沿底边向下折，画面本身不缩放，梯形之外是背景。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
