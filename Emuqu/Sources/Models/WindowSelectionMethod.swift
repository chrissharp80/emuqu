import Foundation

/// Methods for selecting the 5-minute analysis window
enum WindowSelectionMethod: String, Codable, CaseIterable {
    case consolidatedRecovery
    case peakRMSSD
    case peakSDNN
    case peakTotalPower
    case custom

    var displayName: String {
        switch self {
        case .consolidatedRecovery:
            String(localized: "Best Recovery (Default)", bundle: LanguageManager.appBundle)
        case .peakRMSSD:
            String(localized: "Highest RMSSD", bundle: LanguageManager.appBundle)
        case .peakSDNN:
            String(localized: "Highest SDNN", bundle: LanguageManager.appBundle)
        case .peakTotalPower:
            String(localized: "Highest Total Power", bundle: LanguageManager.appBundle)
        case .custom:
            String(localized: "Choose Your Own Window", bundle: LanguageManager.appBundle)
        }
    }

    /// Short label for use in compact UI (dropdown menus, etc.)
    var shortName: String {
        switch self {
        case .consolidatedRecovery:
            String(localized: "Best Recovery", bundle: LanguageManager.appBundle)
        case .peakRMSSD:
            String(localized: "Highest RMSSD", bundle: LanguageManager.appBundle)
        case .peakSDNN:
            String(localized: "Highest SDNN", bundle: LanguageManager.appBundle)
        case .peakTotalPower:
            String(localized: "Highest Total Power", bundle: LanguageManager.appBundle)
        case .custom:
            String(localized: "Custom Window", bundle: LanguageManager.appBundle)
        }
    }

    var tooltip: String {
        switch self {
        case .consolidatedRecovery:
            String(localized: "Picks the most stable, organized recovery window during deep sleep. This is what most HRV apps report.", bundle: LanguageManager.appBundle)
        case .peakRMSSD:
            String(localized: "Finds your highest parasympathetic activity regardless of stability.", bundle: LanguageManager.appBundle)
        case .peakSDNN:
            String(localized: "Finds your highest total heart rate variability (sympathetic + parasympathetic).", bundle: LanguageManager.appBundle)
        case .peakTotalPower:
            String(localized: "Finds the window with the most overall autonomic nervous system activity.", bundle: LanguageManager.appBundle)
        case .custom:
            String(localized: "Tap or drag on the chart to analyze any part of your recording.", bundle: LanguageManager.appBundle)
        }
    }

    var icon: String {
        switch self {
        case .consolidatedRecovery:
            "star.fill"
        case .peakRMSSD:
            "waveform.path.ecg"
        case .peakSDNN:
            "chart.line.uptrend.xyaxis"
        case .peakTotalPower:
            "bolt.heart.fill"
        case .custom:
            "hand.draw.fill"
        }
    }

    /// Methods that appear in the dropdown (excludes custom which has its own UI)
    static var automaticMethods: [WindowSelectionMethod] {
        [.consolidatedRecovery, .peakRMSSD, .peakSDNN, .peakTotalPower]
    }

    /// Factory default method
    static var defaultMethod: WindowSelectionMethod {
        .consolidatedRecovery
    }
}
