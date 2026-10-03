import SwiftUI
import UIKit

/// Transient notification (memory updated, sync
/// complete, brief errors). Slides in over 250ms, holds 2.5s, slides out
/// 200ms. Soft material background, glyph + 13pt text.
///
/// Usage:
///   .modifier(ToastBannerModifier(toast: $toast))
struct ToastBanner: View {
    /// Materials go opaque when the user asks for reduced transparency —
    /// iOS does not substitute for you. See `AdaptiveMaterial`.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let glyph: String
    let message: String
    var tint: Color = AppTheme.wongOptimal

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: glyph)
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(tint)
            Text(verbatim: message)
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(AppTheme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(AdaptiveMaterial.ultraThin(reduceTransparency))
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        // The toast auto-dismisses, so VoiceOver users would otherwise
        // never learn it appeared — combine it into one element with the
        // message as its label.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: message))
    }
}

struct ToastPayload: Equatable, Identifiable {
    let id = UUID()
    let glyph: String
    let message: String
    var tint: Color = AppTheme.wongOptimal

    static func == (lhs: ToastPayload, rhs: ToastPayload) -> Bool {
        lhs.id == rhs.id
    }
}

struct ToastBannerModifier: ViewModifier {
    @Binding var toast: ToastPayload?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) { banner }
            .animation(.easeOut(duration: 0.25), value: toast?.id)
    }

    @ViewBuilder
    private var banner: some View {
        if let toast {
            ToastBanner(glyph: toast.glyph, message: toast.message, tint: toast.tint)
                .padding(.top, 16)
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity
                ))
                .task(id: toast.id) { await announceThenDismiss(toast) }
        }
    }

    /// Speak the toast the moment it appears — it's a transient overlay that
    /// auto-dismisses, so without an explicit announcement VoiceOver users
    /// miss it entirely.
    private func announceThenDismiss(_ toast: ToastPayload) async {
        UIAccessibility.post(notification: .announcement, argument: toast.message)
        await sleepQuietly(2_500_000_000, context: "announceThenDismiss")
        // A newer toast cancels this task; clearing then would wipe the new one.
        guard !Task.isCancelled, self.toast?.id == toast.id else { return }
        withAnimation(.easeOut(duration: 0.2)) { self.toast = nil }
    }
}

extension View {
    /// Show a toast notification.
    func toastBanner(_ toast: Binding<ToastPayload?>) -> some View {
        modifier(ToastBannerModifier(toast: toast))
    }
}
