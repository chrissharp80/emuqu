//
//  ProviderConsentTrackerTests.swift
//  EmuquTests
//
//  ProviderConsentTracker is the gate that prevents
//  PHI/PII reaching a third-party AI provider before the user explicitly
//  agrees. A regression here means HRV / sleep / location data flows to
//  OpenAI / Anthropic / etc. silently — directly violates the App Store
//  privacy posture and the wellness-app contract documented in SECURITY.md.
//
//  The tracker reads `UserDefaults.standard` directly, so these tests work on
//  the shared state and reset every provider they touch in setUp / tearDown.
//

@testable import Emuqu
import XCTest

@MainActor
final class ProviderConsentTrackerTests: XCTestCase {

    /// Note: ProviderConsentTracker uses `UserDefaults.standard` directly.
    /// We can't inject a custom suite
    /// without touching production code, so we work on the shared state
    /// and clean up after ourselves with `setUp` / `tearDown`.
    private let providersToReset: [ProviderID] = [.anthropic, .openai, .gemini, .grok, .deepseek]

    override func setUp() async throws {
        try await super.setUp()
        for p in providersToReset {
            ProviderConsentTracker.shared.revoke(p)
        }
    }

    override func tearDown() async throws {
        for p in providersToReset {
            ProviderConsentTracker.shared.revoke(p)
        }
        try await super.tearDown()
    }

    func testAppleIntelligenceDoesNotRequireConsent() {
        // On-device — no data leaves the device, so consent isn't a gate.
        XCTAssertFalse(ProviderConsentTracker.shared.requiresConsent(.apple))
    }

    func testCloudProvidersRequireConsentByDefault() {
        for p in providersToReset {
            XCTAssertTrue(
                ProviderConsentTracker.shared.requiresConsent(p),
                "Cloud provider \(p.rawValue) must require consent before first send"
            )
        }
    }

    func testAcknowledgeFlipsRequiresConsent() {
        let p: ProviderID = .anthropic
        XCTAssertTrue(ProviderConsentTracker.shared.requiresConsent(p))
        ProviderConsentTracker.shared.acknowledge(p)
        XCTAssertFalse(ProviderConsentTracker.shared.requiresConsent(p))
    }

    func testAcknowledgePersistsAcrossInstances() {
        let p: ProviderID = .openai
        ProviderConsentTracker.shared.acknowledge(p)
        // Construct a second instance — values come back from UserDefaults.
        let newInstance = ProviderConsentTracker()
        XCTAssertFalse(newInstance.requiresConsent(p))
    }

    func testRevokeRequiresConsentAgain() {
        let p: ProviderID = .gemini
        ProviderConsentTracker.shared.acknowledge(p)
        XCTAssertFalse(ProviderConsentTracker.shared.requiresConsent(p))
        ProviderConsentTracker.shared.revoke(p)
        XCTAssertTrue(ProviderConsentTracker.shared.requiresConsent(p))
    }

    func testAcknowledgeAppleIsNoOp() {
        // Apple is not in providersRequiringConsent — acknowledge() must
        // not add it to acknowledgedProviders or persist anything.
        ProviderConsentTracker.shared.acknowledge(.apple)
        XCTAssertFalse(ProviderConsentTracker.shared.acknowledgedProviders.contains(.apple))
    }

    // MARK: - Consent record

    /// The schema version is what invalidates old consent when the disclosure
    /// changes. Three material additions shipped under version 1 without a
    /// bump — a DeepSeek data-residency note, a Tavily web-search disclosure
    /// and a location-services disclosure — so nobody re-consented to any of
    /// them. This pins the bump that fixed it: if someone edits the sheet and
    /// forgets the constant again, they have to walk past this test to do it.
    func testSchemaVersionIsAtLeastTwo() {
        XCTAssertGreaterThanOrEqual(
            ProviderConsentTracker.consentSchemaVersion, 2,
            "Version 1 predates the DeepSeek, Tavily and location disclosures. "
                + "Bump the schema in the same change that edits ProviderConsentSheet."
        )
    }

    /// Version 2 consent was given to a sheet that did not name overnight
    /// vitals, the profile, or saved memory facts, all of which were sent.
    func testSchemaVersionCoversTheFullDataList() {
        XCTAssertGreaterThanOrEqual(ProviderConsentTracker.consentSchemaVersion, 3)
    }

    /// Version 3 consent was given to a sheet that did not name the saved email
    /// contacts the assistant reads, or Anthropic's own web search on Claude.
    func testSchemaVersionCoversContactsAndServerSearch() {
        XCTAssertGreaterThanOrEqual(ProviderConsentTracker.consentSchemaVersion, 4)
    }

    /// Version 4 consent was given to a sheet that did not name today's steps,
    /// the Get Me Back trail, the saved home address, recording notes and tags,
    /// or memory notes and to-dos, all of which the assistant can send.
    func testSchemaVersionCoversStepsTrailHomeAndNotes() {
        XCTAssertGreaterThanOrEqual(ProviderConsentTracker.consentSchemaVersion, 5)
    }

    /// Version 5 consent was given to a sheet that named Open-Meteo for
    /// weather and heat tracking; weather now goes to MET Norway.
    func testSchemaVersionCoversTheWeatherProviderChange() {
        XCTAssertGreaterThanOrEqual(ProviderConsentTracker.consentSchemaVersion, 6)
    }

    /// Consent carries the date it was granted so Settings can show the user
    /// what they agreed to and when — a bare Bool cannot answer that.
    func testAcknowledgeRecordsGrantDate() {
        XCTAssertNil(ProviderConsentTracker.shared.consentGrantedAt(.openai))
        let before = Date()
        ProviderConsentTracker.shared.acknowledge(.openai)
        let granted = ProviderConsentTracker.shared.consentGrantedAt(.openai)
        XCTAssertNotNil(granted)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(granted), before.addingTimeInterval(-1))
    }

    /// Withdrawal must clear the record as well as the flag. A stale date left
    /// behind would let Settings report "Agreed 25 Aug" for a provider the
    /// user had just switched off.
    func testRevokeClearsGrantDate() throws {
        ProviderConsentTracker.shared.acknowledge(.gemini)
        XCTAssertNotNil(ProviderConsentTracker.shared.consentGrantedAt(.gemini))
        ProviderConsentTracker.shared.revoke(.gemini)
        XCTAssertNil(ProviderConsentTracker.shared.consentGrantedAt(.gemini))
        XCTAssertTrue(ProviderConsentTracker.shared.requiresConsent(.gemini))
    }

    /// Withdrawal survives a relaunch. Consent that came back on next launch
    /// would be worse than no withdrawal control at all, because the user
    /// would believe they had stopped it.
    func testRevokePersistsAcrossInstances() {
        ProviderConsentTracker.shared.acknowledge(.grok)
        XCTAssertFalse(ProviderConsentTracker().requiresConsent(.grok))
        ProviderConsentTracker.shared.revoke(.grok)
        XCTAssertTrue(ProviderConsentTracker().requiresConsent(.grok))
    }

    func testRequiresConsentSetMatchesEnum() {
        // Defensive: every cloud provider in ProviderID should be in the
        // requiring-consent set. Forgetting to add a new provider here
        // is the exact regression this test catches.
        let cloudProviders = ProviderID.allCases.filter { $0 != .apple }
        for p in cloudProviders {
            XCTAssertTrue(
                ProviderConsentTracker.providersRequiringConsent.contains(p),
                "New cloud provider \(p.rawValue) is missing from providersRequiringConsent — would silently bypass the gate"
            )
        }
    }
}
