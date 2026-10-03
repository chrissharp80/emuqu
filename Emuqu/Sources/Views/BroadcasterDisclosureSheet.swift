//
//  BroadcasterDisclosureSheet.swift
//  Emuqu
//
//  In-app disclosure shown the first time the user enables the
//  Zwift / TrainerRoad / Rouvy BLE broadcaster (Settings → Wearables →
//  "Broadcast HR + Power to indoor-trainer apps").
//
//  The OS Bluetooth
//  purpose string already covers all three BLE roles (HR consumer +
//  Stryd consumer + outbound broadcaster). What it can't convey is the
//  *direction shift* — from "your sensors connect to your phone" to
//  "your phone is now broadcasting your HR and power outbound to any
//  app on your local network that scans for it". The user accepts that
//  shift here, once.
//

import SwiftUI

struct BroadcasterDisclosureSheet: View {
    /// Materials go opaque when the user asks for reduced transparency —
    /// iOS does not substitute for you. See `AdaptiveMaterial`.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let onAccept: () -> Void
    let onDecline: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            disclosureScroll
        }
    }

    private var disclosureScroll: some View {
        ScrollView {
            disclosureBody
        }
        .navigationTitle(String(localized: "BLE Broadcast", bundle: LanguageManager.appBundle))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { disclosureActionBar }
        .interactiveDismissDisabled()
    }

    private var disclosureActionBar: some View {
        VStack(spacing: 10) {
            enableBroadcastingButton
            dontEnableButton
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .background(AdaptiveMaterial.ultraThin(reduceTransparency))
    }

    private var enableBroadcastingButton: some View {
        Button {
            onAccept()
            dismiss()
        } label: {
            Text(String(localized: "Enable broadcasting", bundle: LanguageManager.appBundle))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var disclosureBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            disclosureHeader
            whatThisTurnsOnSection
            whatItDoesNotShareSection
            whoCanSeeItSection
            Text(String(localized: "You can turn this off any time in Settings → Wearables. The next workout won't broadcast.", bundle: LanguageManager.appBundle))
                .font(.callout)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(20)
    }

    private var disclosureHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(.tint)
            Text(String(localized: "Broadcast your heart rate and power to other apps?", bundle: LanguageManager.appBundle))
                .font(.headline)
        }
    }

    @ViewBuilder
    private var whatThisTurnsOnSection: some View {
        Text(String(localized: "What this turns on", bundle: LanguageManager.appBundle))
            .font(.subheadline.bold())

        bulletList([
            String(localized: "During a workout, your iPhone advertises as a standard BLE peripheral.", bundle: LanguageManager.appBundle),
            String(localized: "Apps like Zwift, TrainerRoad, and Rouvy on the same device — or on a paired iPad / Apple TV — can pair to it as a heart-rate monitor and a cycling power meter.", bundle: LanguageManager.appBundle),
            String(localized: "Your live HR (from your strap) and your live cycling power (from a connected FTMS bike trainer) are sent outbound on Bluetooth so those apps can read them.", bundle: LanguageManager.appBundle)
        ])

    }

    @ViewBuilder
    private var whatItDoesNotShareSection: some View {
        Text(String(localized: "What it doesn't share", bundle: LanguageManager.appBundle))
            .font(.subheadline.bold())

        bulletList([
            String(localized: "No HRV. No GPS coordinates or routes. No personal identity. No Apple Health data.", bundle: LanguageManager.appBundle),
            String(localized: "Only the live HR + live cycling power, only while the workout is active.", bundle: LanguageManager.appBundle),
            String(localized: "Anything else (workouts, sleep, training history) stays on your device.", bundle: LanguageManager.appBundle)
        ])

    }

    @ViewBuilder
    private var whoCanSeeItSection: some View {
        Text(String(localized: "Who can see it", bundle: LanguageManager.appBundle))
            .font(.subheadline.bold())

        bulletList([
            String(localized: "Any BLE-capable app or device within Bluetooth range during the workout (typically ~10 m / 30 ft).", bundle: LanguageManager.appBundle),
            String(localized: "Your iPhone advertises as \"Emuqu\" so the receiving app can identify it.", bundle: LanguageManager.appBundle),
            String(localized: "Off completely between workouts; advertising stops the moment the workout ends.", bundle: LanguageManager.appBundle)
        ])
    }

    private var dontEnableButton: some View {
        Button {
            onDecline()
            dismiss()
        } label: {
            Text(String(localized: "Don't enable", bundle: LanguageManager.appBundle))
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { bulletRow($0) }
        }
    }

    private func bulletRow(_ item: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(String(localized: "•", bundle: LanguageManager.appBundle))
                .foregroundStyle(AppTheme.textSecondary)
            Text(item)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}
