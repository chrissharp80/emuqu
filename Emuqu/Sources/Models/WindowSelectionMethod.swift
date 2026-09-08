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
            "Best Recovery (Default)"
        case .peakRMSSD:
            "Highest RMSSD"
        case .peakSDNN:
            "Highest SDNN"
        case .peakTotalPower:
            "Highest Total Power"
        case .custom:
            "Choose Your Own Window"
        }
    }

    /// Short label for use in compact UI (dropdown menus, etc.)
    var shortName: String {
        switch self {
        case .consolidatedRecovery:
            "Best Recovery"
        case .peakRMSSD:
            "Highest RMSSD"
        case .peakSDNN:
            "Highest SDNN"
        case .peakTotalPower:
            "Highest Total Power"
        case .custom:
            "Custom Window"
        }
    }

    var tooltip: String {
        switch self {
        case .consolidatedRecovery:
            "Picks the most stable, organized recovery window during deep sleep. This is what most HRV apps report."
        case .peakRMSSD:
            "Finds your highest parasympathetic activity regardless of stability."
        case .peakSDNN:
            "Finds your highest total heart rate variability (sympathetic + parasympathetic)."
        case .peakTotalPower:
            "Finds the window with the most overall autonomic nervous system activity."
        case .custom:
            "Tap or drag on the chart to analyze any part of your recording."
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
