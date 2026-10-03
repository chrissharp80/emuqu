import Foundation

/// The interval announcements in the app language, spoken as written when
/// they can't go through the AI: Flo switched off, its notice not accepted,
/// or the provider without consent. They used to go silent then, and a
/// structured workout lost every step change.
enum IntervalSpokenCue {
    static func step(_ step: IntervalStep, number: Int, of total: Int) -> String {
        let bundle = LanguageManager.appBundle
        let header = String(localized: "Step \(number) of \(total): \(localizedLabel(step.label)).", bundle: bundle)
        let target = target(step.target)
        guard let span = span(of: step) else { return header + " " + target }
        return header + " " + String(localized: "\(target) for \(span).", bundle: bundle)
    }

    /// A built-in preset's step label in the app language. The presets
    /// (`IntervalPlan`) store English labels; a label the user typed is
    /// returned as written.
    static func localizedLabel(_ label: String) -> String {
        let bundle = LanguageManager.appBundle
        switch label {
        case "warm up": return String(localized: "warm up", bundle: bundle)
        case "cool down": return String(localized: "cool down", bundle: bundle)
        case "easy": return String(localized: "easy", bundle: bundle)
        case "hard": return String(localized: "hard", bundle: bundle)
        case "interval": return String(localized: "interval", bundle: bundle)
        case "recovery": return String(localized: "recovery", bundle: bundle)
        case "rest": return String(localized: "rest", bundle: bundle)
        case "aerobic base": return String(localized: "aerobic base", bundle: bundle)
        default: return label
        }
    }

    static var blockComplete: String {
        String(localized: "Interval block complete. Anything from here counts as cool-down.", bundle: LanguageManager.appBundle)
    }

    private static func target(_ target: IntervalStep.Target) -> String {
        let bundle = LanguageManager.appBundle
        switch target {
        case .zone(let zone): return String(localized: "Zone \(zone)", bundle: bundle)
        case let .hrRange(lo, hi): return String(localized: "heart rate \(lo) to \(hi)", bundle: bundle)
        case .paceSecPerKm(let pace):
            let clock = String(format: "%d:%02d", pace / 60, pace % 60)
            return String(localized: "\(clock) per kilometer", bundle: bundle)
        case .effort(let cue): return effort(cue)
        }
    }

    private static func effort(_ cue: IntervalStep.Target.EffortCue) -> String {
        let bundle = LanguageManager.appBundle
        return switch cue {
        case .recovery: String(localized: "recovery effort", bundle: bundle)
        case .easy: String(localized: "easy effort", bundle: bundle)
        case .moderate: String(localized: "moderate effort", bundle: bundle)
        case .hard: String(localized: "hard effort", bundle: bundle)
        case .allOut: String(localized: "all-out effort", bundle: bundle)
        }
    }

    /// Duration or distance, worded by the system in the app language, so
    /// plurals and units come out right.
    private static func span(of step: IntervalStep) -> String? {
        if let seconds = step.durationSec {
            let formatter = DateComponentsFormatter()
            var calendar = Calendar.current
            calendar.locale = LanguageManager.appLocale
            formatter.calendar = calendar
            formatter.unitsStyle = .full
            formatter.allowedUnits = [.minute, .second]
            return formatter.string(from: TimeInterval(seconds))
        }
        guard let meters = step.distanceMeters else { return nil }
        let unit: UnitLength = meters >= 1000 ? .kilometers : .meters
        let value = Measurement(value: meters, unit: UnitLength.meters).converted(to: unit)
        return value.formatted(.measurement(width: .wide, usage: .asProvided).locale(LanguageManager.appLocale))
    }
}
