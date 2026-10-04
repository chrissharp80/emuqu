import CoreLocation
import MapKit
import MessageUI
import SwiftUI
import UIKit

// Recap-card generation, PDF mail/share and the share-sheet rows, split out of
// `FitnessPostSummaryView+Cards.swift`. These produce artifacts the
// user sends elsewhere; the cards in that file are what the screen renders.

extension FitnessSummaryCards {

    /// Render the workout RecapCard variant to a 1080×1920 PNG and
    /// present the share sheet. Renders on a utility queue so the
    /// CoreGraphics work doesn't pin the UI thread.
    @MainActor
    func generateRecapCard() async {
        guard !recapGenerating else { return }
        recapGenerating = true
        defer { recapGenerating = false }
        let meta = session.workoutMetadata
        let mapImage = await renderTrackImage()
        let card = RecapCard(variant: .workout(
            distance: recapDistance(meta: meta),
            duration: recapDuration(),
            pace: recapPace(meta: meta),
            verdict: recapVerdict(meta: meta),
            summary: recapSummary(meta: meta),
            date: session.startDate,
            routeMap: mapImage
        ))
        guard let img = card.renderImage() else { return }
        recapImage = img
        recapImageURL = writeRecapPNG(img, meta: meta)
        recapSharePresented = true
    }

    /// Seconds of elapsed workout, floored at zero.
    private var recapElapsedSeconds: TimeInterval {
        max(0, (session.endDate ?? session.startDate).timeIntervalSince(session.startDate))
    }

    private func recapDuration() -> String {
        let secs = recapElapsedSeconds
        guard secs > 0 else { return "—" }
        return LocalizedDuration.hoursMinutes(minutes: Int(secs / 60))
    }

    private func recapPace(meta: WorkoutMetadata?) -> String {
        let secs = recapElapsedSeconds
        guard let m = meta?.distanceMeters, m > 0, secs > 0 else { return "—" }
        return UnitsPreferenceStore.current.formatPace(secondsPerMeter: secs / m) ?? "—"
    }

    /// Use `preferredTrainingLoad` so power-equipped sessions show
    /// their TSS instead of an HR-only TRIMP.
    private func recapSummary(meta: WorkoutMetadata?) -> String {
        guard let load = meta?.preferredTrainingLoad, load.value > 0 else { return "Emuqu" }
        let label: String
        switch load.source {
        case .power, .hr, .mets: label = String(localized: "Load", bundle: LanguageManager.appBundle)
        case .banister, .routeHistory: label = "TRIMP"
        }
        // Round to match other load displays
        return "\(label) \(Int(load.value.rounded()))"
    }

    /// Render the route map off-main if we have a track.
    private func renderTrackImage() async -> UIImage? {
        let trackCopy = track
        let tint = UIColor(AppTheme.primary) // palette read on the main actor, drawn off it
        return await Task.detached(priority: .utility) {
            guard !trackCopy.isEmpty else { return nil }
            let coords = trackCopy.map { CLLocationCoordinate2D(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
            return await RecapCard.renderRouteMap(coordinates: coords, tint: tint)
        }.value
    }

    /// Write to temp file with meaningful name so the share sheet
    /// doesn't auto-label it "Image". Sport name + date gives users a
    /// human-readable filename in Photos / Strava. The date is a machine
    /// format (POSIX locale, Gregorian calendar) whatever the language.
    private func writeRecapPNG(_ img: UIImage, meta: WorkoutMetadata?) -> URL? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "yyyy-MM-dd"
        let sport = meta?.sport.rawValue ?? "workout"
        let stem = "emuqu-\(sport)-\(df.string(from: session.startDate))"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(stem).png")
        guard let pngData = img.pngData(), attempt("share.png.write", { try pngData.write(to: url) }) != nil else { return nil }
        return url
    }

    /// Share and Email buttons for the PDF report. When a PDF for this
    /// session is already cached (`pdfURL`, cleared whenever the archived
    /// session changes), the render is skipped and the file is shared as is.
    @ViewBuilder
    var pdfShareButton: some View {
        VStack(spacing: 6) {
            sharePDFButton

            emailPDFButton
        }
        .sheet(isPresented: $pdfSharePresented) {
            pdfShareSheet
        }
        .sheet(isPresented: $pdfMailPresented) { pdfMailSheet }
        .alert(String(localized: "Email failed", bundle: LanguageManager.appBundle), isPresented: pdfMailErrorBinding) {
            Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) {}
        } message: {
            Text(pdfMailError ?? "")
        }
    }

    @ViewBuilder
    private var pdfMailSheet: some View {
        if let url = pdfURL {
            MailComposerView(
                subject: pdfMailSubject,
                recipients: trainingMailRecipients,
                ccRecipients: trainingMailCC,
                attachmentURL: url
            )
        }
    }

    private var pdfMailErrorBinding: Binding<Bool> {
        Binding(
            get: { pdfMailError != nil },
            set: { if !$0 { pdfMailError = nil } }
        )
    }

    @ViewBuilder
    private var pdfShareSheet: some View {
        if let url = pdfURL {
            ShareSheet(activityItems: [url])
        }
    }

    /// Primary: Share PDF (system share sheet — Apple Mail, Files,
    /// Messages, AirDrop, etc.)
    private var sharePDFButton: some View {
        Button {
            Task { await generateAndShowPDFShare() }
        } label: {
            sharePDFLabel
        }
        .buttonStyle(.plain)
        .disabled(pdfGenerating)
    }

    private var sharePDFLabel: some View {
        HStack(spacing: 12) {
            sharePDFGlyph
            sharePDFText
            Spacer()
            sharePDFTrailingGlyph
        }
    }

    @ViewBuilder
    private var sharePDFGlyph: some View {
        if pdfGenerating {
            ProgressView().scaleEffect(0.9)
        } else {
            Image(systemName: "doc.richtext.fill")
                .font(.title3)
                .foregroundStyle(AppTheme.primary)
                .frame(width: 28)
        }
    }

    private var sharePDFText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pdfGenerating
                ? String(localized: "Preparing PDF…", bundle: LanguageManager.appBundle)
                : String(localized: "Share PDF Report", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(String(localized: "α1 centerpiece · route map · charts · splits", bundle: LanguageManager.appBundle))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    @ViewBuilder
    private var sharePDFTrailingGlyph: some View {
        if !pdfGenerating {
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    /// Direct: Email PDF — pre-fills To / Cc from the user's
    /// training-email defaults (Settings →
    /// Profile → Training emails). One tap to send when defaults
    /// are set; composer opens with empty To/Cc when not.
    private var emailPDFButton: some View {
        Button {
            Task { await generateAndShowPDFMail() }
        } label: {
            emailPDFLabel
        }
        .buttonStyle(.plain)
        .disabled(pdfGenerating)
    }

    private var emailPDFLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope.fill")
                .font(.callout)
                .foregroundStyle(AppTheme.fitnessAccent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Email PDF Report", bundle: LanguageManager.appBundle))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(emailDestinationHint)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.forward")
                .accessibilityHidden(true)
                .font(.caption2)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    /// Hint shown under the "Email PDF Report" button so the user knows
    /// what destination is pre-filled (or that defaults aren't set yet).
    var emailDestinationHint: String {
        let to = trainingMailRecipients.first ?? ""
        let cc = trainingMailCC.joined(separator: ", ")
        if to.isEmpty, cc.isEmpty {
            return String(localized: "Set defaults in Profile to skip typing addresses", bundle: LanguageManager.appBundle)
        }
        if cc.isEmpty {
            return String(localized: "to \(to)", bundle: LanguageManager.appBundle)
        }
        if to.isEmpty {
            return String(localized: "cc \(cc)", bundle: LanguageManager.appBundle)
        }
        return String(localized: "to \(to) · cc \(cc)", bundle: LanguageManager.appBundle)
    }

    var trainingMailRecipients: [String] {
        // Prefer the training default, then fall through the
        // resolved chain (training → recovery → legacy generic), matching
        // MainTabView's report mailer and MorningResultsView's recovery
        // mailer. Reading `defaultTrainingEmailRecipient` alone leaves
        // the workout PDF blank when the user has only set a recovery /
        // legacy default while the other report types pre-fill.
        if let to = settingsManager.settings.defaultTrainingEmailRecipient,
           !to.trimmingCharacters(in: .whitespaces).isEmpty {
            return [to]
        }
        return settingsManager.settings.resolvedDefaultEmailRecipient.map { [$0] } ?? []
    }

    var trainingMailCC: [String] {
        let trainingCC = (settingsManager.settings.defaultTrainingEmailCC ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !trainingCC.isEmpty { return trainingCC }
        return settingsManager.settings.resolvedDefaultEmailCC
    }

    var pdfMailSubject: String {
        let dateStr = session.startDate.formatted(date: .abbreviated, time: .omitted)
        let sport = session.workoutMetadata?.sport.localizedName ?? "Workout"
        return "Emuqu — \(sport), \(dateStr)"
    }

    /// Same generate flow as `generateAndShowPDFShare`, but presents the
    /// mail composer instead of the system share sheet on completion.
    /// Reuses the cached `pdfURL` when one exists for this session.
    func generateAndShowPDFMail() async {
        guard MFMailComposeViewController.canSendMail() else {
            pdfMailError = String(localized: "Mail isn't set up on this device. Use Share PDF Report and pick Mail from the share sheet to compose without a Emuqu default account.", bundle: LanguageManager.appBundle)
            return
        }
        if let url = pdfURL, FileManager.default.fileExists(atPath: url.path) {
            pdfMailPresented = true
            return
        }
        pdfGenerating = true
        let outcome = await renderWorkoutPDF()
        pdfGenerating = false
        switch outcome {
        case .success(let url):
            pdfURL = url
            pdfMailPresented = true
        case .failure(let error):
            pdfMailError = String(localized: "PDF render failed: \(error.localizedDescription)", bundle: LanguageManager.appBundle)
        }
    }

    func generateAndShowPDFShare() async {
        // Fast path: already rendered for this session and not invalidated.
        if let url = pdfURL, FileManager.default.fileExists(atPath: url.path) {
            pdfSharePresented = true
            return
        }
        pdfGenerating = true
        let outcome = await renderWorkoutPDF()
        pdfGenerating = false
        switch outcome {
        case .success(let url):
            pdfURL = url
            pdfSharePresented = true
        case .failure(let error):
            exportError = String(localized: "PDF failed: \(error.localizedDescription)", bundle: LanguageManager.appBundle)
        }
    }

    /// CRITICAL: run the entire PDF render on a background task.
    /// `WorkoutPDFReport` is NOT @MainActor; it's self-contained with
    /// value-type inputs. A plain `Task { … }` inherits the calling actor and
    /// would pin the UI thread for every CoreGraphics draw call in the 6-page
    /// report — a user-visible freeze of 500 ms–2 s. The drawing happens on a
    /// utility queue and the caller only hops back to MainActor for the final
    /// state-flip that presents.
    private func renderWorkoutPDF() async -> Result<URL, Error> {
        let s = settingsManager.settings
        let snapshotSession = session
        let snapshotTrack = track
        let snapshotUnits = units
        let base = "emuqu-workout-\(Int(session.startDate.timeIntervalSince1970))"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(base).pdf")
        return await Task.detached(priority: .userInitiated) {
            let report = WorkoutPDFReport(
                session: snapshotSession, track: snapshotTrack,
                userMaxHR: s.effectiveMaxHR, userRestingHR: s.effectiveRestingHR,
                userLTHR: s.effectiveLTHR, units: snapshotUnits
            )
            do {
                try await report.generate(to: url)
                return .success(url)
            } catch {
                return .failure(error)
            }
        }.value
    }

    /// Native `ShareLink` row. We hand it a pre-written URL so the share sheet
    /// opens instantly — UIActivityViewController-via-.sheet-item hangs for
    /// 1–2 minutes cold-starting its extension scan; ShareLink sidesteps that
    /// entirely. Disabled + dimmed until the
    /// background file-write finishes (usually <100ms, visible only for very
    /// long tracks).
    @ViewBuilder
    func shareRow(icon: String, title: String, subtitle: String, url: URL?) -> some View {
        if let url {
            // ShareLink with preview so Strava / Garmin Connect / TrainingPeaks
            // — all of which register as handlers for .gpx / .tcx — appear
            // directly in the share sheet without the "More…" dance. The
            // preview title is what shows at the top of the system sheet;
            // keeping it short + recognisable ("Emuqu · Walk · 2.3 mi")
            // reads better than the raw filename.
            ShareLink(
                item: url,
                preview: SharePreview(previewTitle(title: title), icon: Image(systemName: icon))
            ) {
                shareRowLabel(icon: icon, title: title, subtitle: subtitle)
            }
            .buttonStyle(.plain)
        } else {
            shareRowLabel(icon: icon, title: title, subtitle: subtitle)
                .opacity(0.4)
        }
    }

    /// Builds "Emuqu · Walk · 2.3 mi" — used as the SharePreview
    /// title so the share sheet shows a meaningful preview instead of the
    /// raw filename.
    func previewTitle(title: String) -> String {
        var parts: [String] = ["Emuqu"]
        if let sport = session.workoutMetadata?.sport { parts.append(sport.localizedName) }
        if let dist = session.workoutMetadata?.distanceMeters, dist > 0 {
            parts.append(UnitsPreferenceStore.current.formatDistance(meters: dist))
        }
        parts.append(title)
        return parts.joined(separator: " · ")
    }

    func shareRowLabel(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(AppTheme.primary)
                .frame(width: 22)
            shareRowCaption(title: title, subtitle: subtitle)
            Spacer()
            Image(systemName: "square.and.arrow.up")
                .font(.subheadline)
                .foregroundStyle(AppTheme.primary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(AppTheme.primary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func headlineRow(_ label: String, value: String, caption: String? = nil) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            trailingValue(value, caption: caption)
        }
        .padding(.vertical, 4)
    }

    func regionForTrack(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        MapBoundsHelper.region(for: coords)
    }

    struct ElevationPoint {
        let distance: Double  // km from start
        let altitude: Double  // meters
    }

    func metricRow(label: String, value: String, caption: String? = nil) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            trailingValue(value, caption: caption)
        }
        .padding(.vertical, 4)
    }

    /// The right-hand column of a metric row: the value, optionally captioned.
    @ViewBuilder
    func trailingValue(_ value: String, caption: String?) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(.headline)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    /// The splits the summary renders and the unit they are bucketed in.
    struct ResolvedSplits {
        let splits: [Split]
        let isMile: Bool
    }

    /// Bucket unit of stored splits from the LONGEST split: full splits are
    /// ~1 609 m (mile) or ~1 000 m (km), and the tail split is a partial of
    /// any length. Nil when there is no full split to tell by (a walk shorter
    /// than one split) — a lone 1.2 km partial could be either.
    nonisolated static func storedSplitsAreMiles(_ splits: [Split]) -> Bool? {
        let longest = splits.map(\.distanceMeters).max() ?? 0
        if longest > 1500 { return true }
        if longest >= 900 { return false }
        return nil
    }

    /// The splits the summary should render, in the user's unit. Stored
    /// splits are used when their bucket matches the preference; otherwise
    /// (or when the bucket can't be told) they are re-bucketed from the GPS
    /// track. Without a track (indoor) whatever is stored is kept. Runs once
    /// per load, off the main thread, not on every render.
    nonisolated static func resolveSplits(
        stored: [Split]?, track: [CLLocation], rrPoints: [RRPoint], startDate: Date, wantsMile: Bool
    ) -> ResolvedSplits? {
        let storedSplits = (stored ?? []).isEmpty ? nil : stored
        if let storedSplits, storedSplitsAreMiles(storedSplits) == wantsMile {
            return ResolvedSplits(splits: storedSplits, isMile: wantsMile)
        }
        let recomputed = track.isEmpty ? [] : WorkoutAnalyzer.computeSplits(
            track: track, rrPoints: rrPoints, startDate: startDate,
            splitDistanceMeters: wantsMile ? 1609.344 : 1000.0
        )
        if !recomputed.isEmpty { return ResolvedSplits(splits: recomputed, isMile: wantsMile) }
        return storedSplits.map { ResolvedSplits(splits: $0, isMile: storedSplitsAreMiles($0) ?? wantsMile) }
    }

    /// `unitLabel` comes from the whole series (`ResolvedSplits.isMile`,
    /// resolved once by `splitsCard`), not this row: the LAST split is
    /// always partial (e.g. 400 m on a 3.95 mi walk binned by mile), and a
    /// per-row threshold would mislabel it "km".
    func splitRow(_ split: Split, unitLabel: String) -> some View {
        HStack {
            Text(verbatim: "\(unitLabel) \(split.index)")
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 60, alignment: .leading)
            Spacer()
            splitPaceText(split)
            if let hr = split.averageHR {
                Text(String(localized: "\(Int(hr)) bpm", bundle: LanguageManager.appBundle))
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 70, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }

    /// Pace is stored as sec/km; convert to sec/m for the units helper.
    @ViewBuilder
    private func splitPaceText(_ split: Split) -> some View {
        if let pace = split.averagePaceSecPerKm,
           let formatted = units.formatPace(secondsPerMeter: pace / 1_000) {
            Text(formatted)
                .font(.subheadline.monospacedDigit())
        }
    }
}

// MARK: - File-scope helpers
//
// Kept outside the view. Each touches none of the view's members —
// including its private statics — and calls nothing inside it. `private`
// at file scope is fileprivate, so every call site in this file resolves.

private func recapDistance(meta: WorkoutMetadata?) -> String {
    guard let m = meta?.distanceMeters, m > 0 else { return "—" }
    return UnitsPreferenceStore.current.formatDistance(meters: m)
}

private func recapVerdict(meta: WorkoutMetadata?) -> String {
    if let peak = meta?.samples?.compactMap({ $0.heartRate }).max() {
        return String(localized: "Peak HR \(peak)", bundle: LanguageManager.appBundle)
    }
    return String(localized: "Workout", bundle: LanguageManager.appBundle)
}

@MainActor
private func shareRowCaption(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
        Text(String(localized: "Share as \(title)", bundle: LanguageManager.appBundle))
            .font(.subheadline.weight(.medium))
            .foregroundStyle(AppTheme.textPrimary)
        Text(subtitle)
            .font(.caption2)
            .foregroundStyle(AppTheme.textTertiary)
            .lineLimit(1)
    }
}
