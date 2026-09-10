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

            SectionCard("折叠几何（从你的位置看这块面板）") {
                LabeledSlider(
                    title: "观察距离",
                    value: $settings.eyeDistance,
                    range: 1...8,
                    format: "%.2f 屏高"
                )
                Text("眼睛离屏幕有多远，单位是屏幕高度。越近，画面朝铰链方向压得越狠；参考实现里相机约在 3.6 屏高之外。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                LabeledSlider(
                    title: "眼睛高度",
                    value: $settings.eyeHeight,
                    range: 0...2,
                    format: "%.2f 屏高"
                )
                Text("眼睛高于铰链多少（0.5 = 屏幕正中）。坐得高一点，画面被压得轻一点。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            SectionCard("渐进模糊（沿面板从铰链到远端）") {
                LabeledSlider(
                    title: "远端最强模糊",
                    value: $settings.blurRadiusPoints,
                    range: 0...200,
                    format: "%.0f pt"
                )
                Text("铰链一侧恒为 0 pt，越靠近面板远端越糊。72 是参考实现的取值，约等于画面宽度的 4.5%。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                LabeledSlider(
                    title: "渐变曲线",
                    value: $settings.rampFalloff,
                    range: 0.5...3,
                    format: "%.2f"
                )
                Text("1 = 线性；1.35（参考实现）让靠近铰链的一半保持可读，模糊集中在远端那一段。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                LabeledSlider(
                    title: "铰链侧保持清晰",
                    value: $settings.hingeClearFraction,
                    range: 0...0.4,
                    format: "%.2f"
                )
                Text("从铰链算起这一比例的面板高度完全不糊。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            SectionCard("远端压暗") {
                LabeledSlider(
                    title: "压暗强度",
                    value: $settings.farDarkening,
                    range: 0...2.5,
                    format: "%.2f"
                )
                Text("2.0 是参考实现的取值：合到一半以后，最远端就已经全黑。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                LabeledSlider(
                    title: "压暗起始位置",
                    value: $settings.darkeningStart,
                    range: 0...0.6,
                    format: "%.2f"
                )
                Text("0 = 从铰链就开始压暗，0.2 表示前 20% 完全不受影响。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            SectionCard("毛玻璃质感") {
                LabeledSlider(title: "白雾浓度", value: $settings.frostOpacity, range: 0...0.4, format: "%.2f")
                LabeledSlider(title: "保留色彩", value: $settings.frostSaturation, range: 0...1, format: "%.2f")
                Text("只在已经糊掉的地方叠加，铰链一侧不受影响。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            SectionCard("开合动画") {
                LabeledSlider(
                    title: "平滑时间",
                    value: $settings.responseSmoothing,
                    range: 0...0.6,
                    format: "%.2f s"
                )
                Text("角度变化到画面跟上之间的时间常数：越大，合盖的动作越像一段连续的折叠动画。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(controller.isPreviewing ? "停止预览" : "预览开合动画") {
                        controller.togglePreview()
                    }
                    if !controller.capture.isRunning {
                        Text("预览需要画面捕获权限")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
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
                    Text("角度从 \(settings.activationAngle, format: .number.precision(.fractionLength(0)))° 合到 \(settings.saturationAngle, format: .number.precision(.fractionLength(0)))° 的过程中，模糊与压暗由无到最强。")
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
                ReadoutRow(label: "折叠进度", value: String(format: "%.2f", controller.progress))
                ReadoutRow(
                    label: "远端模糊",
                    value: String(format: "%.0f pt",
                                  settings.blurRadiusPoints * Self.eased(controller.progress))
                )
                ReadoutRow(
                    label: "远端压暗",
                    value: String(format: "%.0f%%",
                                  min(1, Self.eased(controller.progress) * settings.farDarkening) * 100)
                )
                ReadoutRow(
                    label: "面板可见高度",
                    value: String(format: "%.0f%%", 100 * Self.visiblePanelFraction(settings: settings,
                                                                                     progress: controller.progress))
                )
            }
        }
    }

    /// `motion` in the shader: the fold eased into its effect.
    static func eased(_ progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        return p * p * (3 - 2 * p)
    }

    /// How much of the display the folded panel still covers.
    static func visiblePanelFraction(settings: FrostSettings, progress: Double) -> Double {
        let phi = min(max(progress, 0), 1) * Double.pi / 2
        let D = max(settings.eyeDistance, 0.5)
        let E = settings.eyeHeight
        let sinPhi = sin(phi), cosPhi = cos(phi)
        // The panel's far edge (panel distance 1) appears at this screen height.
        func panelDistance(_ s: Double) -> Double {
            D * s / max(D * cosPhi + (E - s) * sinPhi, 1e-5)
        }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if panelDistance(mid) < 1 { low = mid } else { high = mid }
        }
        return min(max(low, 0), 1)
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

/// A live diagram of what the overlay is doing: the panel tipped away about the
/// display's bottom edge, with the picture foreshortened onto it by the very same
/// projection the shader runs, the blur ramp and the shadow ramp over that, and
/// whatever is behind the lid above the panel's far edge.
private struct FoldPreview: View {
    var controller: AppController

    var body: some View {
        let settings = controller.settings
        let progress = min(max(controller.progress, 0), 1)
        let motion = AnglePane.eased(progress)
        let falloff = max(settings.rampFalloff, 0.05)
        let shadow = min(1, motion * settings.farDarkening)
        let panelFraction = AnglePane.visiblePanelFraction(settings: settings, progress: progress)

        return SectionCard("折叠预览") {
            HStack(alignment: .top, spacing: 14) {
                Canvas { context, size in
                    let D = max(settings.eyeDistance, 0.5)
                    let E = settings.eyeHeight
                    let phi = progress * Double.pi / 2
                    let sinPhi = sin(phi), cosPhi = cos(phi)

                    // The same mapping the shader uses, in canvas coordinates.
                    func panelDistance(atScreenUp s: Double) -> Double {
                        D * s / max(D * cosPhi + (E - s) * sinPhi, 1e-5)
                    }
                    func screenUp(forPanel h: Double) -> Double {
                        var low = 0.0, high = 1.0
                        for _ in 0..<24 {
                            let mid = (low + high) / 2
                            if panelDistance(atScreenUp: mid) < h { low = mid } else { high = mid }
                        }
                        return low
                    }
                    func y(forScreenUp s: Double) -> Double { size.height * (1 - s) }

                    // Behind the lid.
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

                    // The picture, row by row, as it lands on the tipped panel.
                    let rows = Int(size.height)
                    for row in 0..<rows {
                        let s = 1 - (Double(row) + 0.5) / Double(size.height)
                        let h = panelDistance(atScreenUp: s)
                        guard h <= 1 else { continue }
                        let edge = min(max(h, 0), 1)
                        let ramp = pow(edge, falloff)
                        let dark = min(1, motion * settings.farDarkening
                                       * pow(max((edge - settings.darkeningStart)
                                                 / max(1 - settings.darkeningStart, 1e-4), 0), falloff))
                        // Blur reads as a wash towards white on top of the picture.
                        let veil = 0.75 * motion * ramp
                        let base = 0.55 * (1 - dark) + 0.15
                        let lifted = base * (1 - veil) + 0.95 * veil
                        context.fill(
                            Path(CGRect(x: 0, y: Double(row), width: size.width, height: 1)),
                            with: .color(Color(white: lifted))
                        )
                    }

                    // Grid lines at fixed picture heights: their bunching towards
                    // the hinge is the foreshortening, drawn to scale.
                    for step in 1..<10 {
                        let h = Double(step) / 10
                        let y = y(forScreenUp: screenUp(forPanel: h))
                        let line = Path(CGRect(x: 0, y: y - 0.5, width: size.width, height: 1))
                        context.fill(line, with: .color(.accentColor.opacity(0.55)))
                    }

                    // The panel's far edge.
                    let edgeY = y(forScreenUp: panelFraction)
                    context.stroke(
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: edgeY))
                            path.addLine(to: CGPoint(x: size.width, y: edgeY))
                        },
                        with: .color(.accentColor),
                        lineWidth: 1.2
                    )
                }
                .frame(width: 200, height: 126)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    ReadoutRow(label: "折叠进度", value: String(format: "%.2f", progress))
                    ReadoutRow(label: "远端模糊", value: String(format: "%.0f pt",
                                                               settings.blurRadiusPoints * motion))
                    ReadoutRow(label: "远端压暗", value: String(format: "%.0f%%", shadow * 100))
                    ReadoutRow(label: "面板可见高度", value: String(format: "%.0f%%", panelFraction * 100))
                    Text("示意图：面板沿屏幕底边向下折，画面按同一套正视投影前缩到面板上；面板之外是盖子背后的暗处。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
