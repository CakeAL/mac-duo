//
//  FrostSettings.swift
//  MacDuo
//
//  The knobs behind the fold illusion, persisted to UserDefaults.
//
//  None of them move the picture: the effect is a blur ramp plus a shadow ramp
//  laid over a picture that stays exactly where it would be at 90°.
//

import Foundation
import Observation

@MainActor
@Observable
public final class FrostSettings {

    // MARK: - Angle behaviour

    /// The effect is completely off at or above this angle. 90° is the
    /// reference's own starting point: its slider runs the fold from flat (0) to
    /// shut (1), which is exactly 90° down to 0° on a laptop lid.
    public var activationAngle: Double { didSet { persist(\.activationAngle, key: "activationAngle") } }
    /// The effect reaches full strength at or below this angle; 0 keeps the fold
    /// and the lid angle in step the whole way down.
    public var saturationAngle: Double { didSet { persist(\.saturationAngle, key: "saturationAngle") } }
    /// Exponent applied to the normalized closing progress; >1 keeps the effect subtle longer.
    public var responseCurve: Double { didSet { persist(\.responseCurve, key: "responseCurve") } }
    /// Time constant, in seconds, of the animated approach to the target strength.
    /// A fast lid movement therefore still reads as one continuous fold.
    public var responseSmoothing: Double { didSet { persist(\.responseSmoothing, key: "responseSmoothing") } }

    // MARK: - The ramp

    /// Blur radius, in points, at the far edge (the top of the display) at full
    /// strength. The hinge edge stays at zero. 72 is the reference's number.
    public var blurRadiusPoints: Double { didSet { persist(\.blurRadiusPoints, key: "blurRadiusPoints") } }
    /// Shape of the ramp from the hinge to the far edge.
    ///
    /// `1` is a straight ramp. The reference look is `1.35`: the near half of the
    /// picture stays legible and the softening bunches up towards the far edge.
    public var rampFalloff: Double { didSet { persist(\.rampFalloff, key: "rampFalloff") } }
    /// Fraction of the height at the hinge that is left perfectly sharp.
    public var hingeClearFraction: Double { didSet { persist(\.hingeClearFraction, key: "hingeClearFraction") } }

    // MARK: - Viewer

    /// Where the viewer's eye is, in units of screen heights.
    ///
    /// The fold is projected from this eye, which is what compresses the picture
    /// towards the hinge as the lid goes down. The reference puts its camera 40
    /// units from a screen about 11 units tall, i.e. about 3.6 screens; a person
    /// about 50 cm from a 22 cm-tall screen is about 2.3 screens away. Farther
    /// away = flatter compression, closer = stronger.
    public var eyeDistance: Double { didSet { persist(\.eyeDistance, key: "eyeDistance") } }
    /// Height of the eye above the hinge, also in screen heights: 0.5 is dead
    /// centre, higher values mean you are looking down at the screen.
    public var eyeHeight: Double { didSet { persist(\.eyeHeight, key: "eyeHeight") } }

    // MARK: - Shadow

    /// How hard the far edge falls into the dark.
    ///
    /// `2.0` is the reference value — `color *= 1 - min(1, effect * 2)` — and is
    /// the default here: at the far edge the shadow reaches full strength once
    /// the fold is past halfway. Lower values keep more of the picture visible.
    public var farDarkening: Double { didSet { persist(\.farDarkening, key: "farDarkening") } }
    /// Where the shadow begins along the ramp, 0 = at the hinge, 1 = at the far edge.
    public var darkeningStart: Double { didSet { persist(\.darkeningStart, key: "darkeningStart") } }

    // MARK: - Glass

    /// Strength of the milky wash that sells the frosted-glass surface.
    ///
    /// Off by default: the reference has no such wash, it only blurs and
    /// darkens. Raise it for a more "glass" and less "out of focus" feel.
    public var frostOpacity: Double { didSet { persist(\.frostOpacity, key: "frostOpacity") } }
    /// Colour kept in the frosted area, 0 (greyscale) ... 1 (untouched).
    ///
    /// 1 by default, again matching the reference, which keeps every colour.
    public var frostSaturation: Double { didSet { persist(\.frostSaturation, key: "frostSaturation") } }

    // MARK: - Behaviour

    /// Master switch for the whole effect.
    public var isEnabled: Bool { didSet { store.set(isEnabled, forKey: "isEnabled") } }
    public var showInMenuBar: Bool { didSet { store.set(showInMenuBar, forKey: "showInMenuBar") } }

    // MARK: - Calibration

    /// Added to every raw reading, for machines whose sensor reports a shifted range.
    public var angleOffset: Double { didSet { persist(\.angleOffset, key: "angleOffset") } }
    /// Multiplied into every raw reading; use -1 on hardware that reports inverted angles.
    public var angleScale: Double { didSet { persist(\.angleScale, key: "angleScale") } }

    /// Raw sensor value as it comes off the HID report, before calibration.
    public var rawAngle: Double = 0

    /// Where the values are read from and written back to. The verification
    /// harness passes its own suite so its experiments never touch the settings
    /// of the installed app.
    @ObservationIgnored private let store: UserDefaults

    // MARK: - Init

    /// Bumped whenever the effect changes shape.
    ///
    /// A stored value from an older version describes knobs that no longer mean
    /// the same thing — the trapezoid build's leftovers, for instance, or a frost
    /// wash dialled up while looking at a different effect entirely. On a version
    /// change the stored values are dropped so the saved settings always describe
    /// the effect that is actually running.
    public static let settingsVersion = 3

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
            "responseCurve": 1.0,
            "responseSmoothing": 0.12,
            "blurRadiusPoints": 72.0,
            "rampFalloff": 1.35,
            "hingeClearFraction": 0.0,
            "farDarkening": 2.0,
            "darkeningStart": 0.2,
            "frostOpacity": 0.0,
            "frostSaturation": 1.0,
            "eyeDistance": 2.5,
            "eyeHeight": 0.5,
            "angleOffset": 0.0,
            "angleScale": 1.0,
            "isEnabled": true,
            "showInMenuBar": true,
        ])

        activationAngle = defaults.double(forKey: "activationAngle")
        saturationAngle = defaults.double(forKey: "saturationAngle")
        responseCurve = defaults.double(forKey: "responseCurve")
        responseSmoothing = defaults.double(forKey: "responseSmoothing")
        blurRadiusPoints = defaults.double(forKey: "blurRadiusPoints")
        rampFalloff = defaults.double(forKey: "rampFalloff")
        hingeClearFraction = defaults.double(forKey: "hingeClearFraction")
        farDarkening = defaults.double(forKey: "farDarkening")
        darkeningStart = defaults.double(forKey: "darkeningStart")
        frostOpacity = defaults.double(forKey: "frostOpacity")
        frostSaturation = defaults.double(forKey: "frostSaturation")
        eyeDistance = defaults.double(forKey: "eyeDistance")
        eyeHeight = defaults.double(forKey: "eyeHeight")
        angleOffset = defaults.double(forKey: "angleOffset")
        angleScale = defaults.double(forKey: "angleScale")
        isEnabled = defaults.bool(forKey: "isEnabled")
        showInMenuBar = defaults.bool(forKey: "showInMenuBar")
    }

    // MARK: - Derived values

    /// The reference's `progress` — the fold amount its slider sets — read off the
    /// lid angle instead. 0 = the picture standing at 90°, 1 = fully folded.
    public func progress(for angle: Double) -> Double {
        guard isEnabled else { return 0 }
        let span = max(activationAngle - saturationAngle, 0.001)
        let raw = (activationAngle - angle) / span
        let clamped = min(max(raw, 0), 1)
        guard clamped > 0 else { return 0 }
        return pow(clamped, max(responseCurve, 0.05))
    }

    // MARK: - Persistence

    /// Every key this class owns. The window frame is deliberately left alone.
    private static let storedKeys = [
        "activationAngle", "saturationAngle", "responseCurve", "responseSmoothing",
        "blurRadiusPoints", "rampFalloff", "hingeClearFraction", "farDarkening",
        "darkeningStart", "frostOpacity", "frostSaturation", "eyeDistance",
        "eyeHeight", "angleOffset", "angleScale", "isEnabled", "showInMenuBar",
        // Keys from earlier shapes of the effect, so a stale file cannot confuse
        // anything that reads the domain by hand.
        "trapezoidAmount", "backgroundDim", "maxBlurPoints", "minBlurPoints",
        "nearClearFraction", "frostSoftness", "frostDim",
    ]

    private static func clearStoredValues(in store: UserDefaults) {
        for key in storedKeys { store.removeObject(forKey: key) }
    }

    private func persist(_ keyPath: KeyPath<FrostSettings, Double>, key: String) {
        store.set(self[keyPath: keyPath], forKey: key)
    }
}
