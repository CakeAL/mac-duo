//
//  FrostSettings.swift
//  MacDuo
//
//  The knobs that shape the fold illusion and the frosted glass on top of it,
//  persisted to UserDefaults.
//

import Foundation
import Observation

@MainActor
@Observable
public final class FrostSettings {

    // MARK: - Angle behaviour

    /// The effect is completely off at or above this angle.
    public var activationAngle: Double { didSet { persist(\.activationAngle, key: "activationAngle") } }
    /// The effect reaches full strength at or below this angle.
    public var saturationAngle: Double { didSet { persist(\.saturationAngle, key: "saturationAngle") } }
    /// Exponent applied to the normalized closing progress; >1 keeps the effect subtle longer.
    public var responseCurve: Double { didSet { persist(\.responseCurve, key: "responseCurve") } }

    // MARK: - Fold geometry

    /// Trapezoid amount at full strength.
    ///
    /// The picture is a flat panel hinged along the bottom edge of the display.
    /// `0` leaves it standing at 90°, i.e. a plain rectangle. A value of `t`
    /// makes the top edge `1/(1+t)` as wide as the hinge edge; the sides slant
    /// straight in and the rows bunch up as they recede, and whatever the panel
    /// no longer covers shows the surface behind it.
    public var trapezoidAmount: Double { didSet { persist(\.trapezoidAmount, key: "trapezoidAmount") } }

    // MARK: - Frost

    /// Blur radius in display points at the top edge, where the frost is heaviest.
    public var maxBlurPoints: Double { didSet { persist(\.maxBlurPoints, key: "maxBlurPoints") } }
    /// Blur radius at the hinge edge, so the bottom of the picture stays legible.
    public var minBlurPoints: Double { didSet { persist(\.minBlurPoints, key: "minBlurPoints") } }
    /// Fraction of the panel height at the hinge that is left (almost) clear.
    public var nearClearFraction: Double { didSet { persist(\.nearClearFraction, key: "nearClearFraction") } }
    /// 0 = crisp stacked blur (glass), 1 = soft transition (heavy frost).
    public var frostSoftness: Double { didSet { persist(\.frostSoftness, key: "frostSoftness") } }
    /// Strength of the milky frosted-glass wash, 0...1.
    public var frostOpacity: Double { didSet { persist(\.frostOpacity, key: "frostOpacity") } }
    /// Colour kept in the frosted area, 0 (greyscale) ... 1 (untouched).
    public var frostSaturation: Double { didSet { persist(\.frostSaturation, key: "frostSaturation") } }
    /// Dim the frosted area slightly, which reads as glass over a dark room.
    public var frostDim: Double { didSet { persist(\.frostDim, key: "frostDim") } }
    /// How dark the surface behind the tipped panel is, 0...1.
    public var backgroundDim: Double { didSet { persist(\.backgroundDim, key: "backgroundDim") } }

    // MARK: - Behaviour

    /// Master switch for the whole effect.
    public var isEnabled: Bool { didSet { UserDefaults.standard.set(isEnabled, forKey: "isEnabled") } }
    public var showInMenuBar: Bool { didSet { UserDefaults.standard.set(showInMenuBar, forKey: "showInMenuBar") } }

    // MARK: - Calibration

    /// Added to every raw reading, for machines whose sensor reports a shifted range.
    public var angleOffset: Double { didSet { persist(\.angleOffset, key: "angleOffset") } }
    /// Multiplied into every raw reading; use -1 on hardware that reports inverted angles.
    public var angleScale: Double { didSet { persist(\.angleScale, key: "angleScale") } }

    /// Raw sensor value as it comes off the HID report, before calibration.
    public var rawAngle: Double = 0

    // MARK: - Init

    public init(defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            "activationAngle": 90.0,
            "saturationAngle": 15.0,
            "responseCurve": 1.0,
            "trapezoidAmount": 0.24,
            "maxBlurPoints": 90.0,
            "minBlurPoints": 2.0,
            "nearClearFraction": 0.18,
            "frostSoftness": 0.45,
            "frostOpacity": 0.14,
            "frostSaturation": 0.55,
            "frostDim": 0.06,
            "backgroundDim": 0.55,
            "angleOffset": 0.0,
            "angleScale": 1.0,
            "isEnabled": true,
            "showInMenuBar": true,
        ])

        activationAngle = defaults.double(forKey: "activationAngle")
        saturationAngle = defaults.double(forKey: "saturationAngle")
        responseCurve = defaults.double(forKey: "responseCurve")
        trapezoidAmount = defaults.double(forKey: "trapezoidAmount")
        maxBlurPoints = defaults.double(forKey: "maxBlurPoints")
        minBlurPoints = defaults.double(forKey: "minBlurPoints")
        nearClearFraction = defaults.double(forKey: "nearClearFraction")
        frostSoftness = defaults.double(forKey: "frostSoftness")
        frostOpacity = defaults.double(forKey: "frostOpacity")
        frostSaturation = defaults.double(forKey: "frostSaturation")
        frostDim = defaults.double(forKey: "frostDim")
        backgroundDim = defaults.double(forKey: "backgroundDim")
        angleOffset = defaults.double(forKey: "angleOffset")
        angleScale = defaults.double(forKey: "angleScale")
        isEnabled = defaults.bool(forKey: "isEnabled")
        showInMenuBar = defaults.bool(forKey: "showInMenuBar")
    }

    // MARK: - Derived values

    /// Width of the top edge relative to the hinge edge at full strength.
    public var topToBottomWidthRatio: Double {
        1.0 / (1.0 + max(trapezoidAmount, 0))
    }

    /// 0 = effect fully off, 1 = fully frosted.
    public func intensity(for angle: Double) -> Double {
        guard isEnabled else { return 0 }
        let span = max(activationAngle - saturationAngle, 0.001)
        let progress = (activationAngle - angle) / span
        let clamped = min(max(progress, 0), 1)
        guard clamped > 0 else { return 0 }
        return pow(clamped, max(responseCurve, 0.05))
    }

    // MARK: - Persistence

    private func persist(_ keyPath: KeyPath<FrostSettings, Double>, key: String) {
        UserDefaults.standard.set(self[keyPath: keyPath], forKey: key)
    }
}
