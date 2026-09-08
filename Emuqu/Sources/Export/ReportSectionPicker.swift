import SwiftUI

/// Sheet that lets the user choose which sections to include in a PDF report.
/// Offers quick presets (Summary, Full, Sleep) and individual toggle switches.
struct ReportSectionPicker: View {
    let onGenerate: (PDFReportGenerator.ReportStyle, PDFReportGenerator.ReportSections) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var sections: PDFReportGenerator.ReportSections = .all
    @State private var style: PDFReportGenerator.ReportStyle = .comprehensive

    /// Which data sections are actually available for this session.
    /// Sections without data are shown disabled so the user understands
    /// why they're absent from the report.
    var availableSections: PDFReportGenerator.ReportSections = .all

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Presets

                presetsSection

                // MARK: - Custom Sections

                sectionsSection

                // MARK: - Depth

                detailLevelSection
            }
            .navigationTitle(String(localized: "Report Sections", bundle: LanguageManager.appBundle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { pickerToolbar }
        }
    }

    @ToolbarContentBuilder
    private var pickerToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Cancel", bundle: LanguageManager.appBundle)) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            generateButton
        }
    }

    private var generateButton: some View {
        Button(String(localized: "Generate", bundle: LanguageManager.appBundle)) {
            dismiss()
            onGenerate(style, sections)
        }
        .fontWeight(.semibold)
        .disabled(sections.rawValue == 0)
    }

    private var presetsSection: some View {
        Section {
            presetRow(String(localized: "Summary", bundle: LanguageManager.appBundle), icon: "doc.text", preset: .summaryPreset, presetStyle: .summary)
            presetRow(String(localized: "Full Report", bundle: LanguageManager.appBundle), icon: "doc.text.fill", preset: .all, presetStyle: .comprehensive)
            presetRow(String(localized: "Sleep Report", bundle: LanguageManager.appBundle), icon: "bed.double.fill", preset: .sleepPreset, presetStyle: .summary)
        } header: {
            Text(String(localized: "Presets", bundle: LanguageManager.appBundle))
        }
    }

    private var detailLevelSection: some View {
        Section {
            Picker(String(localized: "Detail Level", bundle: LanguageManager.appBundle), selection: $style) {
                Text(String(localized: "Summary", bundle: LanguageManager.appBundle)).tag(PDFReportGenerator.ReportStyle.summary)
                Text(String(localized: "Comprehensive", bundle: LanguageManager.appBundle)).tag(PDFReportGenerator.ReportStyle.comprehensive)
            }
            .pickerStyle(.segmented)
        } header: {
            Text(String(localized: "Detail Level", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "Comprehensive adds deep-dive metric analysis when the Deep-Dive section is enabled.", bundle: LanguageManager.appBundle))
        }
    }

    private func sectionToggle(
        _ item: (section: PDFReportGenerator.ReportSections, label: String, icon: String)
    ) -> some View {
        Toggle(isOn: binding(for: item.section)) {
            Label(item.label, systemImage: item.icon)
        }
        .disabled(!availableSections.contains(item.section))
        .tint(AppTheme.primary)
    }

    private func binding(for section: PDFReportGenerator.ReportSections) -> Binding<Bool> {
        Binding<Bool>(
            get: { sections.contains(section) },
            set: { newValue in
                if newValue {
                    sections.insert(section)
                } else {
                    sections.remove(section)
                }
            }
        )
    }

    private var sectionsSection: some View {
        Section {
            ForEach(PDFReportGenerator.ReportSections.sectionLabels, id: \.label) { item in
                sectionToggle(item)
            }
        } header: {
            Text(String(localized: "Sections", bundle: LanguageManager.appBundle))
        } footer: {
            Text(String(localized: "Unavailable sections are greyed out when data is not present.", bundle: LanguageManager.appBundle))
        }
    }

    // MARK: - Preset Row

    private func presetRow(_ label: String, icon: String, preset: PDFReportGenerator.ReportSections, presetStyle: PDFReportGenerator.ReportStyle) -> some View {
        Button { applyPreset(preset, style: presetStyle) } label: {
            presetRowLabel(label, icon: icon, preset: preset, presetStyle: presetStyle)
        }
    }

    /// `hrvSummary` is force-kept even if it somehow isn't in `availableSections`
    /// — every report needs it.
    private func applyPreset(_ preset: PDFReportGenerator.ReportSections, style presetStyle: PDFReportGenerator.ReportStyle) {
        withAnimation(.easeInOut(duration: 0.15)) {
            sections = preset.intersection(availableSections)
                .union(preset.contains(.hrvSummary) ? .hrvSummary : [])
            style = presetStyle
        }
    }

    private func presetRowLabel(_ label: String, icon: String, preset: PDFReportGenerator.ReportSections, presetStyle: PDFReportGenerator.ReportStyle) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .foregroundColor(AppTheme.textPrimary)
            Spacer()
            presetCheckmark(preset, presetStyle: presetStyle)
        }
    }

    @ViewBuilder
    private func presetCheckmark(_ preset: PDFReportGenerator.ReportSections, presetStyle: PDFReportGenerator.ReportStyle) -> some View {
        if sectionsMatch(preset, style: presetStyle) {
            Image(systemName: "checkmark")
                .foregroundColor(AppTheme.primary)
                .fontWeight(.semibold)
        }
    }

    private func sectionsMatch(_ preset: PDFReportGenerator.ReportSections, style presetStyle: PDFReportGenerator.ReportStyle) -> Bool {
        sections == preset.intersection(availableSections).union(
            preset.contains(.hrvSummary) ? .hrvSummary : []
        ) && style == presetStyle
    }
}
