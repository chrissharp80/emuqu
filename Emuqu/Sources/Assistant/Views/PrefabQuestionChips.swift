import SwiftUI

/// Horizontal scroller of suggested questions shown above the chat input.
///
/// Tapping a chip sends the corresponding pre-fab prompt as if the user
/// typed it. Pure UI affordance — no special routing.
struct PrefabQuestionChips: View {
    let onSelect: (PrefabQuestion) -> Void
    let isEnabled: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            chipRow
                .padding(.horizontal, 12)
        }
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            ForEach(PrefabQuestion.allCases) { question in
                chip(question)
            }
        }
    }

    private func chip(_ question: PrefabQuestion) -> some View {
        Button {
            onSelect(question)
        } label: {
            chipLabel(question)
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func chipLabel(_ question: PrefabQuestion) -> some View {
        Text(question.label)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(Color(.tertiarySystemFill))
            )
            .foregroundStyle(.primary)
            // The capsule stays compact; the tap target grows to the 44pt
            // minimum around it.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}
