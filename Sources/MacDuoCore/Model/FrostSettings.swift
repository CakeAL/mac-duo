//
//  FrostSettings.swift
//  MacDuo
//
//  The knobs behind the fold: how far the top edge draws in, how hard the far
//  half blurs, and how the lid angle turns into both. Persisted to UserDefaults.
//

import Foundation
import Observation

@MainActor
@Observable
public final class FrostSettings {

    // MARK: - Angle behaviour

    /// 开始生效角度：盖角到这个角度或更开，效果为零。
    ///
    /// 默认 90°：屏幕立起来正对你的时候画面是干净的，只有压到 90° 以下才开始折。
    public var activationAngle: Double { didSet { persist(\.activationAngle, key: "activationAngle") } }
    /// 满强度角度：盖角到这个角度或更合，效果拉满。默认 0°（完全合上）。
    public var saturationAngle: Double { didSet { persist(\.saturationAngle, key: "saturationAngle") } }
    /// 镜像：true 时改成"顶端不动、底端收窄 + 底端最糊"。默认关。
    public var mirror: Bool { didSet { store.set(mirror, forKey: "mirror") } }

    /// 响应曲线：`progress` 的幂次。大于 1 时靠近生效角度的那一段更平缓。
    public var responseCurve: Double { didSet { persist(\.responseCurve, key: "responseCurve") } }

    /// Time constant of the fold animation, in seconds.
    ///
    /// The sensor is already smoothed, but a hinge is still a step input: this
    /// second, time-based ease is what turns a flick of the lid into one
    /// continuous fold instead of a jump.
    public var responseSmoothing: Double { didSet { persist(\.responseSmoothing, key: "responseSmoothing") } }

    // MARK: - Trapezoid

    /// How much narrower the top edge is at full fold, as a fraction.
    ///
    /// 0 leaves the picture a rectangle; 0.35 draws the top edge in to about 74%
    /// of the bottom edge. **The bottom edge never moves**, whatever this is: the
    /// picture is pinned to the hinge and only the far end comes in.
    public var topNarrowing: Double { didSet { persist(\.topNarrowing, key: "topNarrowing") } }

    // MARK: - Blur

    /// Gaussian radius at the far edge (the top of the picture) at full fold, in
    /// display points. The hinge end stays perfectly sharp.
    public var maxBlurRadius: Double { didSet { persist(\.maxBlurRadius, key: "maxBlurRadius") } }
    /// Shape of the top-to-bottom ramp.
    ///
    /// 1 is linear, so the whole picture softens evenly; larger values keep the
    /// near half sharp and bunch the blur up at the far edge.
    public var blurFalloff: Double { didSet { persist(\.blurFalloff, key: "blurFalloff") } }

    // MARK: - Extras (both off by default)

    /// Extra darkening at the far edge, 0 = none. The fold is carried by the
    /// trapezoid and the blur; this is only here to taste.
    public var farDarkening: Double { didSet { persist(\.farDarkening, key: "farDarkening") } }
    /// Milky wash over the blurred part, 0 = none.
    public var frostOpacity: Double { didSet { persist(\.frostOpacity, key: "frostOpacity") } }
    /// Colour kept in the blurred part, 1 = untouched.
    public var frostSaturation: Double { didSet { persist(\.frostSaturation, key: "frostSaturation") } }

    // MARK: - Behaviour

    /// Master switch for the whole effect.
    public var isEnabled: Bool { didSet { store.set(isEnabled, forKey: "isEnabled") } }
    public var showInMenuBar: Bool { didSet { store.set(showInMenuBar, forKey: "showInMenuBar") } }

    // MARK: - Calibration

    /// Added to every raw reading, for machines whose sensor reports a shifted range.
    public var angleOffset: Double { didSet { persist(\.angleOffset, key: "angleOffset") } }
    /// Multiplied into every raw reading; -1 on hardware that reports the lid the
    /// other way round.
    public var angleScale: Double { didSet { persist(\.angleScale, key: "angleScale") } }

    /// The same thing as a switch, because nobody should have to remember that
    /// "-1 in the scale field" is the fix for a lid that reads backwards.
    ///
    /// With the lid open the sensor should read something like 100…135°; if it
    /// reads near 0 while you are looking at the screen, flip this.
    public var isAngleReversed: Bool {
        get { angleScale < 0 }
        set { angleScale = newValue ? -1 : 1 }
    }

    /// Raw sensor value as it comes off the HID report, before calibration.
    public var rawAngle: Double = 0

    /// Where values are read from and written back to. The verification harness
    /// passes its own suite so its experiments never touch the installed app.
    @ObservationIgnored private let store: UserDefaults

    // MARK: - Init

    /// Bumped whenever the effect changes shape: a stored value from an older
    /// version describes knobs that no longer mean the same thing, so it is
    /// dropped rather than used to judge a different effect.
    public static let settingsVersion = 7

    public init(defaults store: UserDefaults = .standard) {
        self.store = store
        if store.integer(forKey: "settingsVersion") != Self.settingsVersion {
            Self.clearStoredValues(in: store)
            store.set(Self.settingsVersion, forKey: "settingsVersion")
        }

        let defaults = store
        defaults.register(defaults: [
            "activationAngle": 90.0,
            "saturationAngle": 0.0,
            "mirror": false,
            "responseCurve": 1.0,
            "responseSmoothing": 0.06,
            "topNarrowing": 0.35,
            "maxBlurRadius": 72.0,
            "blurFalloff": 1.2,
            "farDarkening": 0.0,
            "frostOpacity": 0.0,
            "frostSaturation": 1.0,
            "angleOffset": 0.0,
            "angleScale": 1.0,
            "isEnabled": true,
            "showInMenuBar": true,
        ])

        activationAngle = defaults.double(forKey: "activationAngle")
        saturationAngle = defaults.double(forKey: "saturationAngle")
        responseCurve = defaults.double(forKey: "responseCurve")
        responseSmoothing = defaults.double(forKey: "responseSmoothing")
        topNarrowing = defaults.double(forKey: "topNarrowing")
        maxBlurRadius = defaults.double(forKey: "maxBlurRadius")
        blurFalloff = defaults.double(forKey: "blurFalloff")
        farDarkening = defaults.double(forKey: "farDarkening")
        frostOpacity = defaults.double(forKey: "frostOpacity")
        frostSaturation = defaults.double(forKey: "frostSaturation")
        angleOffset = defaults.double(forKey: "angleOffset")
        angleScale = defaults.double(forKey: "angleScale")
        mirror = defaults.bool(forKey: "mirror")
        isEnabled = defaults.bool(forKey: "isEnabled")
        showInMenuBar = defaults.bool(forKey: "showInMenuBar")
    }

    // MARK: - Derived values

    /// Width of the top edge as a fraction of the bottom edge, at this fold.
    public func topWidthRatio(at progress: Double) -> Double {
        let strength = min(max(progress, 0), 1)
        return min(max(1.0 / (1.0 + max(topNarrowing, 0) * strength), 0.02), 1)
    }

    /// Blur radius at the far edge, in points, at this fold.
    public func blurRadius(at progress: Double) -> Double {
        maxBlurRadius * min(max(progress, 0), 1)
    }

    /// 效果强度，0…1 —— 与参考实现同一个式子。
    ///
    /// 参考实现：`foldAngle = (180 − 滑杆值)/180 × π`，`progress = clamp(foldAngle / (π/2), 0, 1)`。
    /// 这里把"折角"定义成**离立起来还差多少**，也就是 `折角 = 开始生效角度 − 盖角`：
    /// 盖角 90°（屏幕立着正对你）时折角为 0，画面干净；盖角 0°（合上）时折角 90°，
    /// 效果拉满。于是
    ///
    ///     progress = clamp(折角 / (π/2), 0, 1)
    ///              = clamp((开始生效角度 − 盖角) / (开始生效角度 − 满强度角度), 0, 1)
    ///
    /// 与参考实现逐字同形，效果区间就是**盖角 0–90°**：90° 及以上为零，越合越强。
    public func progress(for angle: Double) -> Double {
        guard isEnabled else { return 0 }
        let span = max(activationAngle - saturationAngle, 0.001)
        let clamped = min(max((activationAngle - angle) / span, 0), 1)
        guard clamped > 0 else { return 0 }
        return pow(clamped, max(responseCurve, 0.05))
    }

    // MARK: - Persistence

    /// Every key this class owns; the settings window's frame is left alone.
    private static let storedKeys = [
        "activationAngle", "saturationAngle", "responseCurve", "responseSmoothing", "mirror",
        "fullAngle", "zeroAngle", "openSaturationAngle", "mirrorWhenOpen",
        "topNarrowing", "maxBlurRadius", "blurFalloff", "farDarkening", "openSaturationAngle",
        "frostOpacity", "frostSaturation", "angleOffset", "angleScale",
        "isEnabled", "showInMenuBar",
        // Keys from earlier shapes of the effect.
        "maximumFoldAngle", "eyeDistance", "eyeHeight", "hingeClearFraction",
        "darkeningStart", "blurRadiusPoints", "rampFalloff", "trapezoidAmount",
        "backgroundDim", "maxBlurPoints", "minBlurPoints", "nearClearFraction",
        "frostSoftness", "frostDim", "progress",
    ]

    private static func clearStoredValues(in store: UserDefaults) {
        for key in storedKeys { store.removeObject(forKey: key) }
    }

    private func persist(_ keyPath: KeyPath<FrostSettings, Double>, key: String) {
        store.set(self[keyPath: keyPath], forKey: key)
    }
}
