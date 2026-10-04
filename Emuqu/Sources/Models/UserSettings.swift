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

    /// For the picker. `rawValue` stays English: it is stored and synced.
    var localizedName: String {
        let bundle = LanguageManager.appBundle
        return switch self {
        case .sedentary: String(localized: "Sedentary", bundle: bundle)
        case .lightlyActive: String(localized: "Lightly Active", bundle: bundle)
        case .moderatelyActive: String(localized: "Moderately Active", bundle: bundle)
        case .active: String(localized: "Active", bundle: bundle)
        case .veryActive: String(localized: "Very Active", bundle: bundle)
        case .athlete: String(localized: "Athlete", bundle: bundle)
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

/// Three-state training goal. Reaches Flo
/// through the profile line of its context; does not change the recovery
/// score itself (which is physiology-only).
enum TrainingGoal: String, Codable, CaseIterable, Identifiable {
    case maintain
    case build
    case peak

    var id: String { rawValue }

    var displayName: String {
        let bundle = LanguageManager.appBundle
        return switch self {
        case .maintain: String(localized: "Maintain", bundle: bundle)
        case .build: String(localized: "Build", bundle: bundle)
        case .peak: String(localized: "Peak", bundle: bundle)
        }
    }

    /// What the goal shows under the picker.
    var localizedBlurb: String {
        let bundle = LanguageManager.appBundle
        return switch self {
        case .maintain: String(localized: "Keep current fitness. Flo favors balanced-load suggestions.", bundle: bundle)
        case .build: String(localized: "Train upward. Flo lets your load climb before calling the ramp fast.", bundle: bundle)
        case .peak: String(localized: "Race build. Flo softens \"detraining\" talk during a taper.", bundle: bundle)
        }
    }

    /// English, for Flo's context.
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

/// Adaptive routing modes. Quick / Auto /
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
        case .quick: String(localized: "Quick", bundle: LanguageManager.appBundle)
        case .auto: String(localized: "Auto", bundle: LanguageManager.appBundle)
        case .deep: String(localized: "Deep mode", bundle: LanguageManager.appBundle)
        case .manual: String(localized: "Manual", bundle: LanguageManager.appBundle)
        }
    }

    var blurb: String {
        switch self {
        case .quick:
            String(localized: "Private. Typed questions are answered on this iPhone by Apple Intelligence. May refuse complex multi-week analysis.", bundle: LanguageManager.appBundle)
        case .auto:
            String(localized: "Session-sticky. Apple Intelligence answers lookups on this iPhone; questions that need more reasoning go to xAI Grok or DeepSeek once you've added its key and accepted its data-sharing notice.", bundle: LanguageManager.appBundle)
        case .deep:
            String(localized: """
                While Apple Intelligence is selected, Deep sends every turn to xAI Grok or DeepSeek once you've added its key and accepted its data-sharing notice; \
                without one, it answers on this iPhone. Select another cloud model to send every turn to it.
                """, bundle: LanguageManager.appBundle)
        case .manual:
            String(localized: "Every turn goes to whatever you picked in the model picker. Full control.", bundle: LanguageManager.appBundle)
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

    /// The unit the device's region uses: Fahrenheit where the region
    /// measures in US units, Celsius everywhere else.
    static var regionDefault: TemperatureUnit {
        Locale.current.measurementSystem == .us ? .fahrenheit : .celsius
    }

    var localizedName: String {
        self == .celsius
            ? String(localized: "Celsius", bundle: LanguageManager.appBundle)
            : String(localized: "Fahrenheit", bundle: LanguageManager.appBundle)
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
        case .off: String(localized: "Off", bundle: LanguageManager.appBundle)
        case .defaultGap: String(localized: "Default (4.5 hrs)", bundle: LanguageManager.appBundle)
        case .custom: String(localized: "Custom", bundle: LanguageManager.appBundle)
        }
    }
}
