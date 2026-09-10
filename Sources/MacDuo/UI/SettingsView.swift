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
    @State private var selection: Tab = .fold

    enum Tab: String, CaseIterable, Identifiable {
        case fold, hardware
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fold: "折叠"
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
                    case .fold: FoldPane(controller: controller)
                    case .hardware: HardwarePane(controller: controller)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 540, height: 600)
    }
}

// MARK: - Fold

private struct FoldPane: View {
    var controller: AppController

    var body: some View {
        @Bindable var settings = controller.settings

        return VStack(alignment: .leading, spacing: 18) {
            FoldPreview(controller: controller)

            SectionCard("梯形形变（底边不动）") {
                LabeledSlider(
                    title: "顶端收窄量",
                    value: $settings.topNarrowing,
                    range: 0...1.0,
                    format: "%.2f"
                )
                Text(String(format: "全屏截图被横向拉成上窄下宽的梯形：完全折叠时顶端宽度是底端的 %.0f%%。底边完全不动，画面也不会变矮。",
                            100 * settings.topWidthRatio(at: 1)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("梯形之外是盖子背后的空间，用纯黑填充。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            SectionCard("高斯模糊（顶端最强，往下递减）") {
                LabeledSlider(title: "顶端模糊半径", value: $settings.maxBlurRadius, range: 0...200, format: "%.0f pt")
                Text("半径沿画面从上往下递减到 0：顶端最糊，铰链端逐像素清晰。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                LabeledSlider(title: "渐变曲线", value: $settings.blurFalloff, range: 0.3...3, format: "%.2f")
                Text("1 = 线性；大于 1 时靠近铰链的一半保持清晰，糊集中在顶端。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            SectionCard("附加（默认关闭）") {
                LabeledSlider(title: "远端额外压暗", value: $settings.farDarkening, range: 0...2, format: "%.2f")
                LabeledSlider(title: "白雾浓度", value: $settings.frostOpacity, range: 0...0.4, format: "%.2f")
                LabeledSlider(title: "保留色彩", value: $settings.frostSaturation, range: 0...1, format: "%.2f")
            }

            SectionCard("开合动画") {
                LabeledSlider(
                    title: "响应平滑",
                    value: $settings.responseSmoothing,
                    range: 0...0.4,
                    format: "%.2f s"
                )
                Text("传感器本身已经平滑过；这里是把「掀盖子」这个突变补成一次连续折叠的时间常数。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(controller.isPreviewing ? "停止预览" : "预览一次开合（8.6 秒）") {
                        controller.togglePreview()
                    }
                    if !CaptureEngine.hasScreenRecordingPermission {
                        Text("预览需要画面捕获权限")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            SectionCard("触发条件") {
                LabeledSlider(title: "开始生效角度", value: $settings.activationAngle, range: 40...150, format: "%.0f°")
                LabeledSlider(title: "满强度角度", value: $settings.saturationAngle, range: 0...120, format: "%.0f°")
                Text("效果区间就是这两者之间：盖角 ≥ 开始生效角度（默认 90°）时画面干净，压下去越合越强，到满强度角度（默认 0°）拉满。与参考实现同一条式子——把折角取成「开始生效角度 − 盖角」，progress = clamp(折角 / (π/2), 0, 1)。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("镜像（顶端不动、底端收窄）", isOn: $settings.mirror)
                Text("默认关：底边钉住不动，顶端收窄、顶端最糊。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if settings.saturationAngle >= settings.activationAngle {
                    Label("「满强度角度」需要小于「开始生效角度」，否则效果不会出现。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                LabeledSlider(title: "响应曲线", value: $settings.responseCurve, range: 0.3...3.0, format: "%.2f")
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
                ReadoutRow(label: "折叠进度", value: String(format: "%.2f", controller.progress))

                HStack {
                    Button("重新检测") { controller.sensor.restart() }
                    Spacer()
                }

                Divider()

                LabeledSlider(title: "角度偏移", value: $settings.angleOffset, range: -60...60, format: "%.0f°")
                Toggle("反转角度方向", isOn: $settings.isAngleReversed)
                Text("盖子打开时读数应该在 100…135° 附近。如果开着盖子读数却接近 0，打开这个开关。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

/// Live diagram of what the overlay is doing: the screenshot stretched into a
/// trapezoid whose bottom edge is pinned to the bottom of the display, the blur
/// ramping from the top edge down to nothing at the hinge, and black around it.
private struct FoldPreview: View {
    var controller: AppController

    var body: some View {
        let settings = controller.settings
        let progress = min(max(controller.progress, 0), 1)
        let topScale = settings.topWidthRatio(at: progress)
        // 展开侧镜像时，能动的是底边。
        let mirror = settings.mirror
        let falloff = max(settings.blurFalloff, 0.05)
        let blur = settings.maxBlurRadius * progress

        return SectionCard("效果预览") {
            HStack(alignment: .top, spacing: 14) {
                Canvas { context, size in
                    let w = size.width
                    let h = size.height

                    // Black is what shows beyond the picture.
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

                    // The picture: full width along the bottom edge (which never
                    // moves), narrower the higher it goes.
                    let inset = w * (1 - topScale) / 2
                    var shape = Path()
                    if mirror {
                        shape.move(to: CGPoint(x: 0, y: 0))
                        shape.addLine(to: CGPoint(x: w, y: 0))
                        shape.addLine(to: CGPoint(x: w - inset, y: h))
                        shape.addLine(to: CGPoint(x: inset, y: h))
                    } else {
                        shape.move(to: CGPoint(x: inset, y: 0))
                        shape.addLine(to: CGPoint(x: w - inset, y: 0))
                        shape.addLine(to: CGPoint(x: w, y: h))
                        shape.addLine(to: CGPoint(x: 0, y: h))
                    }
                    shape.closeSubpath()

                    var content = context
                    content.clip(to: shape)
                    let stripes = 12
                    for index in 0..<stripes {
                        let x = w * Double(index) / Double(stripes)
                        content.fill(
                            Path(CGRect(x: x, y: 0, width: w / Double(stripes) / 2, height: h)),
                            with: .color(.accentColor.opacity(0.35))
                        )
                    }
                    // The blur ramp, drawn as a veil: opaque at the top, gone at
                    // the bottom.
                    if progress > 0.001 {
                        let stops = (0...5).map { step -> Gradient.Stop in
                            let t = Double(step) / 5
                            return .init(color: .white.opacity(0.75 * progress * pow(t, falloff)),
                                         location: t)
                        }
                        content.fill(
                            Path(CGRect(origin: .zero, size: size)),
                            with: .linearGradient(Gradient(stops: stops),
                                                  startPoint: CGPoint(x: 0, y: 0),
                                                  endPoint: CGPoint(x: 0, y: h))
                        )
                    }
                    context.stroke(shape, with: .color(.accentColor), lineWidth: 1.2)
                }
                .frame(width: 200, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    ReadoutRow(label: "折叠进度", value: String(format: "%.2f", progress))
                    ReadoutRow(label: "顶端宽度", value: String(format: "%.0f%%", 100 * topScale))
                    ReadoutRow(label: "顶端模糊", value: String(format: "%.0f pt", blur))
                    Text("示意图：整屏截图横向拉成梯形，底边不动；模糊从顶端往下递减，梯形之外是黑色。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
