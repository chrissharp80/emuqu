import SwiftUI

/// **The Marco Altini moment.** The
/// three-question subjective questionnaire that gates score reveal.
/// Full-screen sheet (large detent, no swipe-to-dismiss).
///
/// Sequencing:
///   1. Reading completes (caller already invoked us).
///   2. Q1 "How are you feeling?" — five emoji buttons.
///   3. Tap → light haptic → the next question fades in in its place.
///   4. Q2 "Any soreness?" — three emoji buttons.
///   5. Tap → light haptic.
///   6. Q3 "Motivation today?" — three emoji buttons.
///   7. Tap → medium haptic.
///   8. All three answers visible at top as confirmation pills.
///   9. "Show my score" button slides up at bottom.
///   10. Tap → score reveal animation begins (caller-supplied closure).
///
/// Skip: tertiary "Skip this time" link at bottom. Always available.
/// Skipping still gates the reveal — there is no bypass to a non-gated
/// state.
///
/// It is shown before every score reveal, so the answer is not anchored to
/// the number (Altini).
struct PreScorePromptView: View {
    @Environment(\.dependencies) var dependencies
    /// Three captured answers (any may be nil if user skipped).
    struct Answers: Equatable, Sendable {
        var feeling: Feeling?
        var soreness: Soreness?
        var motivation: Motivation?
    }

    enum Feeling: String, CaseIterable, Sendable {
        case terrible, hard, ok, good, great
        var emoji: String {
            switch self {
            case .terrible: "😩"
            case .hard:     "😕"
            case .ok:       "😐"
            case .good:     "🙂"
            case .great:    "🤩"
            }
        }
        var label: String {
            switch self {
            case .terrible: String(localized: "Terrible", bundle: LanguageManager.appBundle)
            case .hard:     String(localized: "Hard", bundle: LanguageManager.appBundle)
            case .ok:       String(localized: "OK", bundle: LanguageManager.appBundle)
            case .good:     String(localized: "Good", bundle: LanguageManager.appBundle)
            case .great:    String(localized: "Great", bundle: LanguageManager.appBundle)
            }
        }
    }

    enum Soreness: String, CaseIterable, Sendable {
        case aLot, some, none
        var emoji: String {
            switch self {
            case .aLot: "😣"
            case .some: "😬"
            case .none: "😌"
            }
        }
        var label: String {
            switch self {
            case .aLot: String(localized: "A lot", bundle: LanguageManager.appBundle)
            case .some: String(localized: "Some", bundle: LanguageManager.appBundle)
            case .none: String(localized: "None", bundle: LanguageManager.appBundle)
            }
        }
    }

    enum Motivation: String, CaseIterable, Sendable {
        case high, normal, low
        var emoji: String {
            switch self {
            case .high:   "🔥"
            case .normal: "😐"
            case .low:    "😴"
            }
        }
        var label: String {
            switch self {
            case .high:   String(localized: "High", bundle: LanguageManager.appBundle)
            case .normal: String(localized: "Normal", bundle: LanguageManager.appBundle)
            case .low:    String(localized: "Low", bundle: LanguageManager.appBundle)
            }
        }
    }

    /// Called with the captured answers. On skip, `skipped` is true and the
    /// answers are whatever was given before skipping.
    let onComplete: (Answers, _ skipped: Bool) -> Void

    @State private var step: Int = 0
    @State private var answers = Answers()

    var body: some View {
        ZStack {
            Color.black.opacity(0.95).ignoresSafeArea()
            VStack(spacing: 0) {
                topPills
                Spacer()
                currentQuestion
                Spacer()
                bottomActions
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
        .task { dependencies.services.preScorePromptTelemetry.recordShown() }
    }

    private var topPills: some View {
        HStack(spacing: 8) {
            if let f = answers.feeling { pill(f.emoji + " " + f.label) }
            if let s = answers.soreness { pill(s.emoji + " " + s.label) }
            if let m = answers.motivation { pill(m.emoji + " " + m.label) }
            Spacer(minLength: 0)
        }
        .frame(height: 32)
    }

    private func pill(_ text: String) -> some View {
        Text(verbatim: text)
            .scaledFont(size: 13, weight: .medium)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(0.12)))
    }

    @ViewBuilder
    private var currentQuestion: some View {
        switch step {
        case 0: feelingQuestion
        case 1: sorenessQuestion
        case 2: motivationQuestion
        default: loggedConfirmation
        }
    }

    private var feelingQuestion: some View {
        questionScreen(
            heading: String(localized: "How are you feeling?", bundle: LanguageManager.appBundle),
            subheading: String(localized: "Quick check before we show your score.", bundle: LanguageManager.appBundle),
            content: { feelingOptions }
        )
    }

    private var sorenessQuestion: some View {
        questionScreen(
            heading: String(localized: "Any soreness?", bundle: LanguageManager.appBundle),
            subheading: nil,
            content: { sorenessOptions }
        )
    }

    private var motivationQuestion: some View {
        questionScreen(
            heading: String(localized: "Motivation today?", bundle: LanguageManager.appBundle),
            subheading: nil,
            content: { motivationOptions }
        )
    }

    private var feelingOptions: some View {
        HStack(spacing: 6) {
            ForEach(Feeling.allCases, id: \.self) { feelingButton($0) }
        }
    }

    private func feelingButton(_ f: Feeling) -> some View {
        emojiButton(emoji: f.emoji, label: f.label) {
            answers.feeling = f
            hapticLight()
            advance()
        }
    }

    private var sorenessOptions: some View {
        HStack(spacing: 18) {
            ForEach(Soreness.allCases, id: \.self) { sorenessButton($0) }
        }
    }

    private func sorenessButton(_ s: Soreness) -> some View {
        emojiButton(emoji: s.emoji, label: s.label) {
            answers.soreness = s
            hapticLight()
            advance()
        }
    }

    private var motivationOptions: some View {
        HStack(spacing: 18) {
            ForEach(Motivation.allCases, id: \.self) { motivationButton($0) }
        }
    }

    private func motivationButton(_ m: Motivation) -> some View {
        emojiButton(emoji: m.emoji, label: m.label) {
            answers.motivation = m
            hapticMedium()
            advance()
        }
    }

    private var loggedConfirmation: some View {
        VStack(spacing: 12) {
            Text(String(localized: "Logged.", bundle: LanguageManager.appBundle))
                .scaledFont(size: 28, weight: .semibold)
                .foregroundStyle(.white)
            Text(String(localized: "Tap below to see your score.", bundle: LanguageManager.appBundle))
                .scaledFont(size: 15)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    @ViewBuilder
    private func questionScreen(heading: String, subheading: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 24) {
            questionHeading(heading, subheading: subheading)
            content()
        }
    }

    @ViewBuilder
    private func questionHeading(_ heading: String, subheading: String?) -> some View {
        VStack(spacing: 6) {
            Text(verbatim: heading)
                .scaledFont(size: 28, weight: .semibold)
                .foregroundStyle(.white)
            if let sub = subheading {
                Text(verbatim: sub)
                    .scaledFont(size: 15)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    private func emojiButton(emoji: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(verbatim: emoji)
                    .scaledFont(size: 36)
                Text(verbatim: label)
                    .scaledFont(size: 12)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.center)
            }
            // Shares the row's width instead of a fixed 60 pt: five fixed
            // buttons overflowed a 375 pt phone and clipped translated labels.
            .frame(minWidth: 44, maxWidth: .infinity, minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var bottomActions: some View {
        VStack(spacing: 16) {
            showMyScoreSection
            skipThisTimeSection
        }
    }

    @ViewBuilder
    private var showMyScoreSection: some View {
        if step >= 3 {
            Button {
                dependencies.services.preScorePromptTelemetry.recordCompleted()
                onComplete(answers, false)
            } label: {
                Text(String(localized: "Show my score", bundle: LanguageManager.appBundle))
                    .scaledFont(size: 17, weight: .semibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60) // 60pt
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(AppTheme.wongOptimal)
                    )
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }

    private var skipThisTimeSection: some View {
        Button {
            dependencies.services.preScorePromptTelemetry.recordSkipped()
            onComplete(answers, true)
        } label: {
            Text(String(localized: "Skip this time", bundle: LanguageManager.appBundle))
                .scaledFont(size: 14)
                .foregroundStyle(.white.opacity(0.6))
                .underline()
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(String(localized: "Skip the subjective check and go straight to your score.", bundle: LanguageManager.appBundle)))
    }

    // MARK: - Helpers

    private func advance() {
        withAnimation(.easeOut(duration: 0.25)) {
            step += 1
        }
    }

    private func hapticLight() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func hapticMedium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
