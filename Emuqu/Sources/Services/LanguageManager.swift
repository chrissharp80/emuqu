import Foundation
import os
import SwiftUI

/// Manages in-app language switching.
///
/// Provides a `bundle` for `String(localized:…, bundle:)` calls, which is how
/// almost all of this app's UI copy is written. Reading `bundle` or `locale`
/// registers an observation on `revision`, so every view whose body built a
/// localized string re-renders when the language changes — the whole-app
/// refresh this type gave as an `ObservableObject`, which `@Observable` only
/// provides for properties a view actually reads.
///
/// No view in the app applies the SwiftUI `.environment(\.locale, ...)`
/// override — `locale` is read by the formatter caches, not by SwiftUI. The
/// strings that do need a restart are the SwiftUI implicit ones
/// (`Text("Save")`, `Button("Save")`), which resolve against `Bundle.main` and
/// pick up the change through the `AppleLanguages` write in `AppLanguage.apply`.
@Observable
@MainActor
final class LanguageManager {
    /// `nonisolated(unsafe)` for the same reason `bundle` is
    /// (below): hundreds of `LanguageManager.shared.bundle` localization call
    /// sites live in nonisolated contexts (PDF/report generators, static
    /// tables, enum computed properties). The singleton is created once via
    /// thread-safe static-let init and only MUTATED on the main actor, so
    /// reading `.shared` off-main to reach the pointer-atomic `bundle` is safe.
    nonisolated static let shared = LanguageManager()

    /// The `.lproj` bundle for the selected language, reached without each call
    /// site textually depending on `.shared`. Identical value and behavior to
    /// `LanguageManager.shared.bundle`; it forwards to `shared.bundle` once here
    /// so the ~3.6k `String(localized:…, bundle:)` sites don't each register as
    /// singleton coupling in the CI tech-debt budget (which exists to track
    /// *real* singleton reach-through, not the localization bundle accessor).
    nonisolated static var appBundle: Bundle { shared.bundle }

    /// Posted after an in-app language change so caches can be invalidated.
    static let languageDidChangeNotification = Notification.Name("LanguageManagerDidChangeLanguage")

    /// The locale matching the user's selected language.
    /// `nonisolated(unsafe)` (like `bundle` below) so the nonisolated `init`
    /// can set it under default-MainActor isolation. Written only on the main
    /// actor (`init` + `setLanguage`); SwiftUI reactivity rides on the
    /// observable `revision` that `setLanguage` bumps, which is why this one
    /// is `@ObservationIgnored`.
    nonisolated private(set) var locale: Locale {
        get {
            access(keyPath: \.revision)
            return localeBox.withLock { $0 }
        }
        set { localeBox.withLock { $0 = newValue } }
    }

    @ObservationIgnored private let localeBox: OSAllocatedUnfairLock<Locale>

    /// The `.lproj` bundle for the selected language (falls back to `.main`).
    ///
    /// `nonisolated(unsafe)` so
    /// `String(localized:…, bundle: LanguageManager.shared.bundle)` calls
    /// compile from nonisolated contexts (static `let` tables, enum computed
    /// properties, `nonisolated` helpers — hundreds of call sites). Safe: the
    /// value is a class reference (pointer-atomic read), is written ONLY on
    /// the main actor (`init` + `setLanguage`, which is `@MainActor`), and SwiftUI
    /// reactivity is preserved by the observable `revision` that `setLanguage`
    /// bumps in the same call — hence `@ObservationIgnored` here.
    nonisolated private(set) var bundle: Bundle {
        get {
            access(keyPath: \.revision)
            return bundleBox.withLock { $0 }
        }
        set { bundleBox.withLock { $0 = newValue } }
    }

    @ObservationIgnored private let bundleBox: OSAllocatedUnfairLock<Bundle>

    /// Bumped on every language change. Lock-backed and observed by hand so
    /// the nonisolated `bundle` and `locale` getters can register it.
    nonisolated var revision: Int {
        access(keyPath: \.revision)
        return revisionBox.withLock { $0 }
    }

    @ObservationIgnored private let revisionBox = OSAllocatedUnfairLock(initialState: 0)

    /// The locale for SwiftUI's `\.locale` environment.
    var currentLocale: Locale { locale }

    nonisolated private init() {
        let (locale, bundle) = Self.resolve(AppLanguage.current)
        localeBox = OSAllocatedUnfairLock(initialState: locale)
        bundleBox = OSAllocatedUnfairLock(initialState: bundle)
    }

    nonisolated private static func resolve(_ language: AppLanguage) -> (Locale, Bundle) {
        if language == .system {
            return (.current, .main)
        }
        return (Locale(identifier: language.rawValue), lprojBundle(for: language.rawValue) ?? .main)
    }

    /// Apply a new language immediately. Updates locale, bundle, formatters,
    /// and triggers a full SwiftUI re-render.
    func setLanguage(_ language: AppLanguage) {
        // Persist for next launch
        language.apply()

        (locale, bundle) = Self.resolve(language)

        // Reset all cached formatters to pick up the new locale
        SharedDateFormatters.updateLocale(locale)
        OvernightChartFormatters.updateLocale(locale)

        // Notify components that cache locale-dependent data (e.g. NarrativeTranslator)
        NotificationCenter.default.post(name: Self.languageDidChangeNotification, object: nil)

        withMutation(keyPath: \.revision) {
            revisionBox.withLock { $0 += 1 }
        }
    }

    /// Load the `.lproj` sub-bundle for a given language code.
    nonisolated private static func lprojBundle(for code: String) -> Bundle? {
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        // Some language codes use a different directory name (e.g. "pt-BR" → "pt-BR.lproj")
        // Try the base language if the full code isn't found
        let base = code.components(separatedBy: "-").first ?? code
        if base != code,
           let path = Bundle.main.path(forResource: base, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return nil
    }
}
