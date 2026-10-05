import Foundation

// MARK: - NarrativeLanguage

/// The language the narrative builders write in: the morning summary
/// (`AnalysisSummaryGenerator`), the probable causes (`CauseDetection`), the
/// score-factor details (`ScoreDetailBuilder`, `VitalsScoring`), the score
/// breakdown's message and penalties (`ScoreBreakdownCopy`) and the readiness
/// copy (`ReadinessScoring`, `LiveReadiness`). Their
/// sentences are catalogue keys with format arguments, so they come out in the
/// app language with reviewed translations. Machine consumers that need
/// English (the assistant's context) wrap the call in `english { }`.
enum NarrativeLanguage {
    @TaskLocal static var isEnglish: Bool = false

    /// The catalogue the builders read: the app language, or English inside
    /// `english { }`.
    static var bundle: Bundle { isEnglish ? englishBundle : LanguageManager.appBundle }

    /// The locale the builders format numbers in.
    static var locale: Locale { isEnglish ? Locale(identifier: "en_US_POSIX") : LanguageManager.appLocale }

    /// Runs `body` with every narrative builder writing English.
    static func english<T>(_ body: () throws -> T) rethrows -> T {
        try $isEnglish.withValue(true, operation: body)
    }

    /// `value` with `decimals` fraction digits and no grouping, in `locale`.
    static func number(_ value: Double, decimals: Int = 0) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)).grouping(.never).locale(locale))
    }

    /// A whole number with no grouping, in `locale`.
    static func integer(_ value: Int) -> String {
        value.formatted(.number.grouping(.never).locale(locale))
    }

    /// `value` with an explicit sign ("+0.7", "-0.3"), in `locale`.
    static func signedNumber(_ value: Double, decimals: Int) -> String {
        value.formatted(
            .number.precision(.fractionLength(decimals)).grouping(.never).sign(strategy: .always()).locale(locale)
        )
    }

    /// "7h 30m": English as the builders always wrote it, else the system's
    /// abbreviated duration in the app language.
    static func hoursMinutes(_ minutes: Int) -> String {
        guard !isEnglish else { return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m" }
        return LocalizedDuration.hoursMinutes(minutes: minutes)
    }

    /// The development-language `.lproj`, falling back to the main bundle,
    /// whose keys are the English text.
    private static let englishBundle: Bundle = Bundle.main.path(forResource: "en", ofType: "lproj")
        .flatMap(Bundle.init(path:)) ?? .main
}
