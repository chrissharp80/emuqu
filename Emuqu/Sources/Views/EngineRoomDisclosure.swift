import SwiftUI

/// Build plan §3.5 — the expandable "Advanced metrics" / "Recording
/// details" section beneath every detail view exposing power-user metrics.
///
/// Memory rule: if user expands once, default to expanded for 30 days;
/// after 30 days reset to collapsed. Stored under a per-instance UserDefaults
/// key so it survives app launch.
///
/// Confidence-pip behaviour: when current confidence is `●○○` (Building
/// baseline), Engine Room shows raw observational data only — caller is
/// responsible for not feeding z-scores in.
struct EngineRoomDisclosure<Content: View>: View {
    let title: String
    let memoryKey: String   // UserDefaults key for last-tapped timestamp
    @ViewBuilder let content: () -> Content

    @State private var expanded: Bool

    init(title: String, memoryKey: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.memoryKey = memoryKey
        self.content = content
        // 30-day memory: if user tapped within last 30 days, default expanded.
        let last = UserDefaults.standard.double(forKey: memoryKey)
        let recentlyTapped = last > 0 && Date().timeIntervalSince1970 - last < 60 * 60 * 24 * 30
        _expanded = State(initialValue: recentlyTapped)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggle()
            } label: {
                bodyLabel
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Tap to collapse" : "Tap to expand")
            if expanded {
                content()
                    .padding(.top, 12)
            }
        }
    }

    /// Remembers the last time this section was opened so the disclosure can
    /// restore its state on the next visit.
    private func toggle() {
        withAnimation(.easeInOut(duration: 0.22)) {
            expanded.toggle()
        }
        if expanded {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: memoryKey)
        }
    }

    private var bodyLabel: some View {
        HStack {
            Text(verbatim: title)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Image(systemName: "chevron.down")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(AppTheme.textTertiary)
                .rotationEffect(.degrees(expanded ? 0 : -90))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.sectionTint)
        )
    }
}
