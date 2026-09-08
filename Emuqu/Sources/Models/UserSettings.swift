import Foundation
import UIKit

/// User fitness level for personalized baselines
enum FitnessLevel: String, Codable, CaseIterable, Identifiable {
    case sedentary = "Sedentary"
    case lightlyActive = "Lightly Active"
    case moderatelyActive = "Moderately Active"
    case active = "Active"
    case veryActive = "Very Active"
    case athlete = "Athlete"

    var id: String {
        rawValue
    }

    var description: String {
        switch self {
        case .sedentary:
            "Little to no regular exercise"
        case .lightlyActive:
            "Light exercise 1-3 days/week"
        case .moderatelyActive:
            "Moderate exercise 3-5 days/week"
        case .active:
            "Hard exercise 6-7 days/week"
        case .veryActive:
            "Very hard daily exercise or physical job"
        case .athlete:
            "Professional or competitive athlete"
        }
    }

    /// Expected RMSSD range baseline multiplier
    var rmssdBaselineMultiplier: Double {
        switch self {
        case .sedentary: 0.8
        case .lightlyActive: 0.9
        case .moderatelyActive: 1.0
        case .active: 1.1
        case .veryActive: 1.2
        case .athlete: 1.3
        }
    }
}

/// Build plan §4.6 M3.3 + §D8 — three-state training goal. Drives Coach
/// voice modulation and Trajectory ramp-rate language; does not change
/// the recovery score itself (which is physiology-only per §D2).
enum TrainingGoal: String, Codable, CaseIterable, Identifiable {
    case maintain
    case build
    case peak

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .maintain: "Maintain"
        case .build: "Build"
        case .peak: "Peak"
        }
    }

    var blurb: String {
        switch self {
        case .maintain:
            "Keep current fitness. Coach favors balanced-load suggestions."
        case .build:
            "Train upward. Coach allows ramp-rate growth before flagging it as fast."
        case .peak:
            "Race build. Coach softens 'detraining' language during taper."
        }
    }
}

/// Adaptive routing modes per the spec. Quick / Auto /
/// Deep are the three canonical user-facing modes; Manual ("every
/// turn goes to the picked provider") is the escape hatch.
enum RoutingMode: String, Codable, CaseIterable, Identifiable {
    case quick
    case auto
    case deep
    case manual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quick: "Quick"
        case .auto: "Auto"
        case .deep: "Deep"
        case .manual: "Manual"
        }
    }

    var blurb: String {
        switch self {
        case .quick:
            "Fastest, free, private. Apple Intelligence on-device for every turn. May refuse complex multi-week analysis."
        case .auto:
            "Session-sticky. Picks Apple for lookups + simple coaching, your paid provider for real reasoning. Tier persists once chosen."
        case .deep:
            "Best quality. Every turn goes to your strongest configured cloud model. Slower (1-3s) and costlier."
        case .manual:
            "Every turn goes to whatever you picked in the model picker. Full control."
        }
    }
}

/// Temperature display unit preference
enum TemperatureUnit: String, Codable, CaseIterable, Identifiable {
    case celsius = "Celsius"
    case fahrenheit = "Fahrenheit"

    var id: String {
        rawValue
    }

    var symbol: String {
        switch self {
        case .celsius: "°C"
        case .fahrenheit: "°F"
        }
    }

    /// Convert Celsius deviation to display value
    func convert(_ celsiusDeviation: Double) -> Double {
        switch self {
        case .celsius: celsiusDeviation
        case .fahrenheit: celsiusDeviation * 9.0 / 5.0 // Deviation conversion (not absolute)
        }
    }

    /// Convert a Celsius deviation from wrist baseline (36.5°C) to an absolute temperature
    func absoluteFromDeviation(_ celsiusDeviation: Double) -> Double {
        let absoluteCelsius = 36.5 + celsiusDeviation
        switch self {
        case .celsius: return absoluteCelsius
        case .fahrenheit: return absoluteCelsius * 9.0 / 5.0 + 32.0
        }
    }
}

/// App appearance theme for background customization
@MainActor
enum AppearanceTheme: String, Codable, CaseIterable, Identifiable {
    case light = "Light"
    case dim = "Dim"
    case dark = "Dark"

    nonisolated var id: String {
        rawValue
    }

    var displayName: String {
        let bundle = LanguageManager.appBundle
        switch self {
        case .light: return String(localized: "Light", bundle: bundle)
        case .dim: return String(localized: "Dim", bundle: bundle)
        case .dark: return String(localized: "Dark", bundle: bundle)
        }
    }

    var description: String {
        let bundle = LanguageManager.appBundle
        switch self {
        case .light: return String(localized: "Warm off-white background", bundle: bundle)
        case .dim: return String(localized: "Muted gray background", bundle: bundle)
        case .dark: return String(localized: "Dark charcoal background", bundle: bundle)
        }
    }
}

/// Color theme for the app's primary accent color
@MainActor
enum ColorTheme: String, Codable, CaseIterable, Identifiable {
    case blue = "Blue"
    case teal = "Teal"
    case indigo = "Indigo"
    case purple = "Purple"
    case rose = "Rose"
    case orange = "Orange"

    nonisolated var id: String {
        rawValue
    }

    var displayName: String {
        let bundle = LanguageManager.appBundle
        switch self {
        case .blue: return String(localized: "Blue", bundle: bundle)
        case .teal: return String(localized: "Teal", bundle: bundle)
        case .indigo: return String(localized: "Indigo", bundle: bundle)
        case .purple: return String(localized: "Purple", bundle: bundle)
        case .rose: return String(localized: "Rose", bundle: bundle)
        case .orange: return String(localized: "Orange", bundle: bundle)
        }
    }

    var description: String {
        let bundle = LanguageManager.appBundle
        switch self {
        case .blue: return String(localized: "Trust & calm", bundle: bundle)
        case .teal: return String(localized: "Fresh & balanced", bundle: bundle)
        case .indigo: return String(localized: "Deep & focused", bundle: bundle)
        case .purple: return String(localized: "Premium & insightful", bundle: bundle)
        case .rose: return String(localized: "Warm & energetic", bundle: bundle)
        case .orange: return String(localized: "Bold & vibrant", bundle: bundle)
        }
    }
}

/// Session merge gap mode for linking split-sleep segments
enum SessionMergeMode: String, Codable, CaseIterable, Identifiable {
    case off = "Off"
    case defaultGap = "Default"
    case custom = "Custom"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .defaultGap: "Default (4.5 hrs)"
        case .custom: "Custom"
        }
    }
}
