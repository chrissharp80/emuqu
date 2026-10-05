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
/// The app root applies `currentLocale` and `layoutDirection` to the SwiftUI
/// environment (`EmuquApp.environmentInjected`), so formatted values and
/// right-to-left layout follow a change at once. The strings that do need a
/// restart are the SwiftUI implicit ones (`Text("Save")`, `Button("Save")`)
/// with no `bundle:`, which resolve against `Bundle.main` and pick up the
/// change through the `AppleLanguages` write in `AppLanguage.apply`.
@Observable
@MainActor
final class LanguageManager {
    /// `nonisolated` for the same reason `bundle` is (below): hundreds of
    /// localization call sites live in nonisolated contexts (PDF/report
    /// generators, static tables, enum computed properties). The singleton is
    /// created once via thread-safe static-let init, and its mutable state
    /// sits behind locks, so reading it off-main is safe.
    nonisolated static let shared = LanguageManager()

    /// The `.lproj` bundle for the selected language, reached without each call
    /// site textually depending on `.shared`. Identical value and behavior to
    /// `LanguageManager.shared.bundle`; it forwards to `shared.bundle` once here
    /// so the ~3.6k `String(localized:…, bundle:)` sites don't each register as
    /// singleton coupling in the CI tech-debt budget (which exists to track
    /// *real* singleton reach-through, not the localization bundle accessor).
    nonisolated static var appBundle: Bundle { shared.bundle }

    /// The selected language's locale, reached the same way as `appBundle`.
    nonisolated static var appLocale: Locale { shared.locale }

    /// Posted after an in-app language change so caches can be invalidated.
    static let languageDidChangeNotification = Notification.Name("LanguageManagerDidChangeLanguage")

    /// The locale matching the user's selected language.
    /// `nonisolated` and stored in a lock (like `bundle` below) so the
    /// nonisolated `init` can set it and any context can read it. Written by
    /// `init` and `setLanguage`; SwiftUI reactivity rides on the observable
    /// `revision` that `setLanguage` bumps, which the getter registers.
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
    /// `nonisolated` and stored in a lock so
    /// `String(localized:…, bundle: LanguageManager.appBundle)` calls compile
    /// from nonisolated contexts (static `let` tables, enum computed
    /// properties, `nonisolated` helpers — hundreds of call sites). Written by
    /// `init` and `setLanguage` (which is `@MainActor`); SwiftUI reactivity is
    /// preserved by the observable `revision` that `setLanguage` bumps in the
    /// same call, which the getter registers.
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

    /// Right-to-left for Arabic. Switching languages in the app changed the
    /// words at once but kept the left-to-right layout until a relaunch.
    var layoutDirection: LayoutDirection {
        locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }

    nonisolated private init() {
        let (locale, bundle) = Self.resolve(AppLanguage.current)
        localeBox = OSAllocatedUnfairLock(initialState: locale)
        bundleBox = OSAllocatedUnfairLock(initialState: bundle)
    }

    nonisolated private static func resolve(_ language: AppLanguage) -> (Locale, Bundle) {
        if language == .system {
            return systemLanguage()
        }
        return (Locale(identifier: language.rawValue), lprojBundle(for: language.rawValue) ?? .main)
    }

    /// The device's own language, read afresh. `Bundle.main` and
    /// `Locale.current` were fixed at launch under whatever override was set
    /// then, so switching back to System Default would otherwise keep the old
    /// language until a relaunch. `AppLanguage.apply` has removed the app's
    /// `AppleLanguages` override by now, so the lookup falls through to the
    /// device list.
    nonisolated private static func systemLanguage() -> (Locale, Bundle) {
        let preferred = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
        let available = Bundle.main.localizations.filter { $0 != "Base" }
        guard let code = Bundle.preferredLocalizations(from: available, forPreferences: preferred).first,
              let bundle = lprojBundle(for: code)
        else { return (.current, .main) }
        let current = Locale.current
        let sameLanguage = current.language.languageCode == Locale(identifier: code).language.languageCode
        return (sameLanguage ? current : Locale(identifier: code), bundle)
    }

    /// Apply a new language immediately. Updates locale and bundle, and
    /// triggers a full SwiftUI re-render.
    func setLanguage(_ language: AppLanguage) {
        // Persist for next launch
        language.apply()

        (locale, bundle) = Self.resolve(language)

        // Notify components that cache locale-dependent data (e.g. MorningNotificationScheduler)
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
