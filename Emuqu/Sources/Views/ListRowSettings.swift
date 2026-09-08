import LocalAuthentication
import SwiftUI

/// Build plan §3.8 — Standard SwiftUI Form .insetGrouped row variants.
///
/// A thin convenience over Form rows so consolidated Settings pages get
/// consistent visuals everywhere. Variants: link / toggle / value /
/// value-noChevron / destructive (red, Face-ID-gated by the component
/// itself).
enum ListRowSettings {
    /// Tappable row that pushes a destination via NavigationLink.
    struct Link<Destination: View>: View {
        let title: String
        var subtitle: String?
        var systemImage: String?
        let destination: () -> Destination

        var body: some View {
            NavigationLink {
                destination()
            } label: {
                rowLabel
            }
        }

        private var rowLabel: some View {
            HStack(spacing: 12) {
                glyph
                titleStack
            }
        }

        @ViewBuilder
        private var glyph: some View {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(AppTheme.primary)
                    .frame(width: 24)
            }
        }

        private var titleStack: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .foregroundStyle(AppTheme.textPrimary)
                subtitleText
            }
        }

        @ViewBuilder
        private var subtitleText: some View {
            if let subtitle {
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    /// Boolean-binding toggle row.
    struct Toggle: View {
        let title: String
        var subtitle: String?
        var systemImage: String?
        @Binding var isOn: Bool

        var body: some View {
            SwiftUI.Toggle(isOn: $isOn) {
                toggleLabel
            }
        }

        private var toggleLabel: some View {
            HStack(spacing: 12) {
                glyph
                titleStack
            }
        }

        @ViewBuilder
        private var glyph: some View {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(AppTheme.primary)
                    .frame(width: 24)
            }
        }

        private var titleStack: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                subtitleText
            }
        }

        @ViewBuilder
        private var subtitleText: some View {
            if let subtitle {
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
    }

    /// Read-only value row (no chevron).
    struct Value: View {
        let title: String
        let value: String
        var systemImage: String?

        var body: some View {
            HStack(spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(AppTheme.primary)
                        .frame(width: 24)
                }
                Text(verbatim: title)
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(verbatim: value)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    /// Destructive action row.
    ///
    /// Face ID gate is ENFORCED IN THE COMPONENT
    /// (BP §3.8 line 350). Pushing responsibility to
    /// callers ("caller should wrap…") means a single forgetful caller
    /// could let an irrecoverable action through without auth. The
    /// component owns the gate so the contract is unbreakable.
    ///
    /// Flow: tap → confirmation alert → Face/Touch/passcode prompt
    /// (`LAContext.evaluatePolicy(.deviceOwnerAuthentication)` so we
    /// fall back to passcode when biometry is unavailable) → action.
    /// Confirmation copy is callable-supplied so each row can match
    /// its destructive verb ("Delete all data?", "Erase route?").
    struct Destructive: View {
        let title: String
        var systemImage: String?
        /// Confirm-alert title. Defaults to "Are you sure?" but most
        /// callers will pass a verb-specific phrase.
        var confirmTitle: String = String(localized: "Are you sure?", bundle: LanguageManager.appBundle)
        var confirmMessage: String?
        /// Auth prompt reason shown by iOS in the Face ID overlay.
        var authReason: String = String(localized: "Confirm this destructive action.", bundle: LanguageManager.appBundle)
        let action: () -> Void

        @State private var showConfirm = false
        @State private var authError: String?

        var body: some View {
            Button(role: .destructive) {
                showConfirm = true
            } label: {
                rowLabel
            }
            .alert(confirmTitle, isPresented: $showConfirm) {
                confirmActions
            } message: {
                confirmMessageText
            }
            .alert(String(localized: "Authentication failed", bundle: LanguageManager.appBundle), isPresented: Binding(
                get: { authError != nil },
                set: { if !$0 { authError = nil } }
            )) {
                Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) { authError = nil }
            } message: {
                authErrorText
            }
        }

        private var rowLabel: some View {
            HStack(spacing: 12) {
                glyph
                Text(verbatim: title)
                    .foregroundStyle(AppTheme.alert)
            }
        }

        @ViewBuilder
        private var glyph: some View {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(AppTheme.alert)
                    .frame(width: 24)
            }
        }

        @ViewBuilder
        private var confirmActions: some View {
            Button(String(localized: "Cancel", bundle: LanguageManager.appBundle), role: .cancel) {}
            Button(title, role: .destructive) {
                Task { await runWithBiometricGate() }
            }
        }

        @ViewBuilder
        private var confirmMessageText: some View {
            if let confirmMessage {
                Text(verbatim: confirmMessage)
            }
        }

        @ViewBuilder
        private var authErrorText: some View {
            if let authError { Text(verbatim: authError) }
        }

        /// `.deviceOwnerAuthentication` falls back to passcode when biometry
        /// isn't available / enrolled. We do NOT want
        /// `.deviceOwnerAuthenticationWithBiometrics` here — that would lock
        /// out users who haven't set up Face ID at all.
        ///
        /// When the device has no passcode set (or the user disabled all auth)
        /// we treat the action as approved: there is nothing to gate against,
        /// and the confirmation alert already gave them an "are you sure"
        /// moment.
        @MainActor
        private func runWithBiometricGate() async {
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                action()
                return
            }
            do {
                let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: authReason)
                if ok { action() }
            } catch {
                authError = error.localizedDescription
            }
        }
    }
}
