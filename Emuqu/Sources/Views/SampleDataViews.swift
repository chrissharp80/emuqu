import SwiftUI

// The ways into and out of sample data. Two for the Dashboard — an offer on
// the first-run screen and a banner while sample nights are showing — and one
// Settings section, shown in Troubleshooting and on its own page for Settings
// search. They share `SampleDataModel`, so each says the same thing about the
// same state.

/// Progress and outcome of a sample-data load or removal, for one screen.
@MainActor
@Observable
final class SampleDataModel {
    enum Phase: Equatable {
        case idle
        case loading(built: Int, total: Int)
        case removing
    }

    private(set) var phase: Phase = .idle
    private(set) var isPresent = false
    /// The last failure, shown until the next attempt.
    private(set) var failure: String?

    var isWorking: Bool {
        phase != .idle
    }

    func refresh(_ library: SampleDataLibrary) {
        isPresent = library.isPresent
    }

    func load(_ library: SampleDataLibrary) async {
        phase = .loading(built: 0, total: DemoSessionSeeder.defaultNightCount)
        failure = nil
        do {
            try await library.load { built, total in self.phase = .loading(built: built, total: total) }
        } catch {
            failure = error.localizedDescription
        }
        phase = .idle
        refresh(library)
    }

    func remove(_ library: SampleDataLibrary) async {
        phase = .removing
        failure = nil
        do {
            try await library.remove()
        } catch {
            failure = error.localizedDescription
        }
        phase = .idle
        refresh(library)
    }

    /// "Analyzing night 5 of 21…" while loading, "Removing…" while removing.
    var progressText: String? {
        switch phase {
        case .idle: nil
        case let .loading(built, total):
            String(localized: "Analyzing night \(min(built + 1, total)) of \(total)…", bundle: LanguageManager.appBundle)
        case .removing: String(localized: "Removing sample data…", bundle: LanguageManager.appBundle)
        }
    }

    var progressFraction: Double? {
        guard case let .loading(built, total) = phase, total > 0 else { return nil }
        return Double(built) / Double(total)
    }
}

/// Shared copy, so the Dashboard and Settings describe sample data the same way.
@MainActor
enum SampleDataCopy {
    static var loadTitle: String {
        String(localized: "Load sample data", bundle: LanguageManager.appBundle)
    }

    static var removeTitle: String {
        String(localized: "Remove sample data", bundle: LanguageManager.appBundle)
    }

    static var removeConfirmMessage: String {
        String(
            localized: "Deletes the sample nights, including any iCloud copies, and nothing else. Your own recordings are not touched.",
            bundle: LanguageManager.appBundle
        )
    }

    static var explanation: String {
        String(
            localized: "Three weeks of synthetic nights, scored by the same analysis as a real recording. Tagged Demo; remove them any time.",
            bundle: LanguageManager.appBundle
        )
    }
}

// MARK: - Dashboard

/// The way in for someone with no strap yet: one line directly under
/// "Building your baseline", in the slot the baseline pip takes once there
/// is a night, above the Get started card. Placed there rather
/// than at the end of that card so it is on screen without scrolling on a
/// 390×844 phone — a reviewer who does not scroll still sees it.
struct SampleDataOfferRow: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(RRCollector.self) private var collector
    @State private var model = SampleDataModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: load) { buttonLabel }
                .buttonStyle(.bordered)
                .tint(AppTheme.primary)
                .disabled(model.isWorking)
                .accessibilityIdentifier("dashboard.sampleDataOffer")
                .accessibilityHint(String(localized: "Three weeks of example nights. Remove them any time.", bundle: LanguageManager.appBundle))
            SampleDataProgress(model: model)
        }
    }

    private func load() {
        let library = SampleDataLibrary(collector: collector, cloudSync: dependencies.storage.cloudKitSyncManager)
        Task { await model.load(library) }
    }

    private var buttonLabel: some View {
        // Primary-text label on the tinted fill: the tint colour itself on
        // its own 15% wash failed the dashboard's contrast audit.
        // Shrinks rather than growing without limit: at the largest
        // accessibility text size the unbounded label pushed the button off
        // the bottom of the dashboard and under the tab bar.
        Label(String(localized: "No strap yet? Explore with sample data", bundle: LanguageManager.appBundle), systemImage: "wand.and.stars")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.textPrimary)
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity)
    }
}

/// Shown above the score whenever sample nights are in the archive, so they
/// are never mistaken for the user's own and are one tap from gone.
struct SampleDataBanner: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(RRCollector.self) private var collector
    @State private var model = SampleDataModel()
    @State private var confirmingRemoval = false

    /// Presence is read in `body`, not refreshed from a `.task`: while there
    /// is no sample data this view draws nothing, and a task attached to
    /// nothing never runs. Reading `archiveVersion` here re-evaluates the body
    /// on every archive change, which is when the answer can change.
    var body: some View {
        let _ = collector.archiveVersion
        if model.isWorking || library.isPresent {
            banner.modifier(SampleDataRemovalConfirmation(isPresented: $confirmingRemoval, onConfirm: remove))
        }
    }

    private var library: SampleDataLibrary {
        SampleDataLibrary(collector: collector, cloudSync: dependencies.storage.cloudKitSyncManager)
    }

    private func remove() {
        Task { await model.remove(library) }
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 8) {
            bannerCaption
            SampleDataProgress(model: model)
            removeButton
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(AppTheme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.wongGood.opacity(0.35), lineWidth: 1))
        .accessibilityIdentifier("dashboard.sampleDataBanner")
    }

    private var bannerCaption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(String(localized: "You're viewing sample data", bundle: LanguageManager.appBundle), systemImage: "wand.and.stars")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(String(localized: "These nights are synthetic examples, not your recordings.", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            confirmingRemoval = true
        } label: {
            Text(SampleDataCopy.removeTitle)
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .disabled(model.isWorking)
    }
}

/// Progress while working, the failure after one.
private struct SampleDataProgress: View {
    let model: SampleDataModel

    var body: some View {
        if let text = model.progressText {
            VStack(alignment: .leading, spacing: 4) {
                progressBar
                Text(text).font(.caption).foregroundStyle(AppTheme.textSecondary)
            }
        } else if let failure = model.failure {
            Text(failure).font(.caption).foregroundStyle(AppTheme.alert)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if let fraction = model.progressFraction {
            ProgressView(value: fraction)
        } else {
            ProgressView()
        }
    }
}

/// "Remove sample data?" before anything is deleted, worded the same wherever
/// removal is offered.
private struct SampleDataRemovalConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(SampleDataCopy.removeTitle, isPresented: $isPresented, titleVisibility: .visible) {
            Button(SampleDataCopy.removeTitle, role: .destructive, action: onConfirm)
        } message: {
            Text(SampleDataCopy.removeConfirmMessage)
        }
    }
}

// MARK: - Settings

/// The Settings section: load, or remove when present. Troubleshooting shows
/// it outside Debug Mode on purpose: App Review is sent there, and a reviewer
/// should not have to find a developer toggle first.
struct SampleDataSection: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(RRCollector.self) private var collector
    @State private var model = SampleDataModel()
    @State private var confirmingRemoval = false

    var body: some View {
        Section {
            SampleDataProgress(model: model)
            loadButton
            if model.isPresent {
                removeButton
            }
        } header: {
            Text(String(localized: "Sample data", bundle: LanguageManager.appBundle))
        } footer: {
            Text(SampleDataCopy.explanation)
        }
        .task(id: collector.archiveVersion) { model.refresh(library) }
        .modifier(SampleDataRemovalConfirmation(isPresented: $confirmingRemoval, onConfirm: remove))
    }

    private var library: SampleDataLibrary {
        SampleDataLibrary(collector: collector, cloudSync: dependencies.storage.cloudKitSyncManager)
    }

    private func remove() {
        Task { await model.remove(library) }
    }

    private var loadButton: some View {
        Button {
            Task { await model.load(library) }
        } label: {
            Label(SampleDataCopy.loadTitle, systemImage: "wand.and.stars")
        }
        .disabled(model.isWorking || model.isPresent)
        .accessibilityIdentifier("settings.sampleData.load")
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            confirmingRemoval = true
        } label: {
            Label(SampleDataCopy.removeTitle, systemImage: "trash")
        }
        .disabled(model.isWorking)
        .accessibilityIdentifier("settings.sampleData.remove")
    }
}

/// Sample data on a page of its own, where Settings search lands.
struct SampleDataPage: View {
    var body: some View {
        Form {
            SampleDataSection()
        }
        .navigationTitle(String(localized: "Sample data", bundle: LanguageManager.appBundle))
    }
}
