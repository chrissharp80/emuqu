//
//  ProviderConsentTracker.swift
//  Emuqu
//
//  Per-provider PHI/PII sharing consent tracker.
//
//  The first-launch HealthDisclaimer
//  is generic ("AI uses your provider key") and runs once at app open.
//  But the user can add a Claude key three weeks later and switch
//  providers mid-conversation; without per-provider acknowledgement we'd
//  silently start sending HRV / heart rate / sleep / GPS / named routes
//  to a provider the user hasn't explicitly agreed to. That is HIPAA-
//  adjacent and the App Store privacy nutrition label doesn't disclose
//  third-party AI sharing under the current `AppFunctionality` purpose.
//
//  This tracker is a thin wrapper over UserDefaults keyed per provider.
//  Apple Intelligence (on-device) is exempt — no data leaves the device,
//  so no consent prompt is needed for that provider.
//
//  Two invariants, both of the kind that only hold if you compare this file
//  against the disclosure it claims to version:
//
//    1. `consentSchemaVersion` must be bumped whenever the consent sheet
//       gains a material addition (a data-residency note, a web-search
//       disclosure, a location-services disclosure), or nobody is
//       re-prompted.
//
//    2. `revoke(_:)` must have production callers. Otherwise consent, once
//       given, cannot be withdrawn from the shipping app — and removing the
//       API key must withdraw it too, or a user who removed a key and later
//       re-added it resumes hosted sends with no second prompt.
//
//  Both are wired below and in `AIAssistantSettingsPage`. Consent records
//  carry the date and schema they were granted under so the UI can show them.
//

import Foundation

@Observable

@MainActor
final class ProviderConsentTracker {
    static let shared = ProviderConsentTracker()

    /// Bumped to invalidate prior consent across providers when the disclosure
    /// text materially changes (added a new data category, switched provider
    /// host, etc.).
    ///
    /// - `1` — the original disclosure language.
    /// - `2` — covers the three additions made under version 1
    ///   without a bump: the DeepSeek data-residency note, the Tavily
    ///   web-search disclosure, and the location-services disclosure. Everyone
    ///   who consented under version 1 re-consents on their next hosted send.
    /// - `3` — names the data the sheet had left out: overnight vitals, the
    ///   profile, workout-coach updates sent without a question, and saved
    ///   memory facts, which can hold health conditions.
    /// - `4` — names the saved email contacts and default recipients the
    ///   assistant reads to write email, your position when you ask for
    ///   directions, and, on Claude, Anthropic's own web search.
    /// - `5` — names what the assistant was already reading without a line on
    ///   the sheet: today's steps and distance, the Get Me Back trail and recent
    ///   start points, the saved home address, recording notes, tags and
    ///   check-ins, memory notes and to-dos, and Open-Meteo's elevation fallback.
    /// - `6` — weather comes from MET Norway instead of Open-Meteo, elevation
    ///   from OpenTopoData alone, and heat tracking sends nothing.
    /// - `7` — names both Overpass instances the road and trail lookups use,
    ///   overpass.private.coffee and overpass-api.de, which are run by
    ///   different operators.
    ///
    /// **Bump this in the same change that edits the sheet.** There is no
    /// automated check, so the discipline is the only guard.
    static let consentSchemaVersion = 7

    private static func storageKey(for provider: ProviderID) -> String {
        "assistant.consent.v\(consentSchemaVersion).\(provider.rawValue)"
    }

    /// When consent was granted, so Settings can show it. Additive metadata —
    /// `storageKey` remains the sole gate, unchanged from version 1.
    private static func grantedDateKey(for provider: ProviderID) -> String {
        storageKey(for: provider) + ".grantedAt"
    }

    /// Provider IDs that require explicit consent before the first PHI/PII
    /// payload leaves the device. Apple Intelligence runs on-device so it
    /// is excluded.
    static let providersRequiringConsent: Set<ProviderID> = [
        .anthropic, .openai, .gemini, .grok, .deepseek
    ]

    private(set) var acknowledgedProviders: Set<ProviderID> = []

    init() {
        for provider in Self.providersRequiringConsent where UserDefaults.standard.bool(forKey: Self.storageKey(for: provider)) {
            acknowledgedProviders.insert(provider)
        }
    }

    /// Whether the user must see a consent sheet before this provider can
    /// receive their data. False for `.apple` (on-device) and for any
    /// previously-acknowledged provider.
    func requiresConsent(_ provider: ProviderID) -> Bool {
        guard Self.providersRequiringConsent.contains(provider) else { return false }
        return !acknowledgedProviders.contains(provider)
    }

    /// Record that the user accepted the data-sharing disclosure for the
    /// given provider. Persists across app launches; cleared if the schema
    /// version bumps.
    func acknowledge(_ provider: ProviderID) {
        guard Self.providersRequiringConsent.contains(provider) else { return }
        acknowledgedProviders.insert(provider)
        UserDefaults.standard.set(true, forKey: Self.storageKey(for: provider))
        UserDefaults.standard.set(Date(), forKey: Self.grantedDateKey(for: provider))
    }

    /// Withdraw consent for one provider. The next hosted send re-prompts.
    ///
    /// Reachable in production from Settings → Flo → *provider* →
    /// Withdraw consent, and called automatically when the provider's API key
    /// is removed. Without a production caller the disclosure would be
    /// one-way: agree once, never take it back.
    func revoke(_ provider: ProviderID) {
        acknowledgedProviders.remove(provider)
        UserDefaults.standard.removeObject(forKey: Self.storageKey(for: provider))
        UserDefaults.standard.removeObject(forKey: Self.grantedDateKey(for: provider))
    }

    /// When the user consented to the current schema for this provider, or nil
    /// if they have not. Used by Settings to show what was agreed and when.
    func consentGrantedAt(_ provider: ProviderID) -> Date? {
        UserDefaults.standard.object(forKey: Self.grantedDateKey(for: provider)) as? Date
    }
}
