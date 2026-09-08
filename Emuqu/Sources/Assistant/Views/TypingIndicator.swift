import SwiftUI

/// Three pulsing dots shown while waiting for the first token of an assistant
/// response. Reads as "the model is thinking" rather than a frozen UI.
struct TypingIndicator: View {
    @State private var phase = 0
    @State private var timer: Timer?

    var body: some View {
        dots
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .onAppear { startAnimating() }
            .onDisappear { stopAnimating() }
    }

    private var dots: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< 3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1.0 : 0.3)
            }
        }
    }

    /// Stored timer + onDisappear invalidation. Without the store, every
    /// assistant response leaked a Timer that captured the view's state
    /// closure forever.
    private func startAnimating() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { _ in
            MainActor.assumeIsolated { phase = (phase + 1) % 3 }
        }
    }

    private func stopAnimating() {
        timer?.invalidate()
        timer = nil
    }
}
