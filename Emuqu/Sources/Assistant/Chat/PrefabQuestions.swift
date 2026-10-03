import Foundation

/// The fixed set of questions surfaced as suggestion chips above the chat input.
///
/// Backed by the existing analysis layer. Selecting a chip just sends the
/// `prompt` text as a regular user message — there's no special routing.
/// The model's answer quality comes from the structured `AssistantContext`
/// it receives alongside, not from any per-question logic.
enum PrefabQuestion: String, CaseIterable, Identifiable {
    case howAmIDoing
    case whyIsScoreThis
    case shouldITrainHard
    case whatChanged
    case howVsBaseline
    case wasSleepGood
    case isTrainingLoadOK
    case focusThisWeek
    case trendingUpDown
    case whatDoesHRVTellYou

    var id: String {
        rawValue
    }

    /// Short label for the chip
    var label: String {
        let bundle = LanguageManager.appBundle
        return switch self {
        case .howAmIDoing: String(localized: "How am I doing today?", bundle: bundle)
        case .whyIsScoreThis: String(localized: "Why is my score what it is?", bundle: bundle)
        case .shouldITrainHard: String(localized: "Should I train hard today?", bundle: bundle)
        case .whatChanged: String(localized: "What changed from yesterday?", bundle: bundle)
        case .howVsBaseline: String(localized: "How do I compare to my baseline?", bundle: bundle)
        case .wasSleepGood: String(localized: "Was my sleep good?", bundle: bundle)
        case .isTrainingLoadOK: String(localized: "Is my training load okay?", bundle: bundle)
        case .focusThisWeek: String(localized: "What should I focus on this week?", bundle: bundle)
        case .trendingUpDown: String(localized: "Am I trending up or down?", bundle: bundle)
        case .whatDoesHRVTellYou: String(localized: "What does my HRV tell you?", bundle: bundle)
        }
    }

    /// Slightly expanded version sent to the model as the user message.
    /// More specific phrasing produces better answers across providers.
    /// In the app language: it shows in the chat as the user's message, and
    /// the model answers in the language it was asked in.
    var prompt: String {
        let bundle = LanguageManager.appBundle
        return switch self {
        case .howAmIDoing: String(localized: "Give me a clear summary of how I'm doing today based on my recovery data. Hit the highlights and the things to watch.", bundle: bundle)
        case .whyIsScoreThis: String(localized: "Explain why my recovery score is what it is today. Use the factor breakdown and probable causes — be specific about which factors are dragging or carrying the score, and reference the actual numbers.", bundle: bundle)
        case .shouldITrainHard: String(localized: "Based on today's recovery and my training load (ATL/CTL/TSB), should I train hard today, train easy, or rest? Tell me why.", bundle: bundle)
        case .whatChanged: String(localized: "Compare today to yesterday. What changed in HRV, sleep, training load, and vitals? Call out anything notable.", bundle: bundle)
        case .howVsBaseline: String(localized: "How do today's numbers compare to my personal baseline? Use the rolling baseline stats and call out any meaningful deviations.", bundle: bundle)
        case .wasSleepGood: String(localized: "Walk me through last night's sleep — duration, efficiency, deep, REM, awake time. Was it actually good for me, or just OK?", bundle: bundle)
        case .isTrainingLoadOK: String(localized: "Look at my ATL, CTL, and TSB. Am I in a good training-load zone, undertraining, high strain, or freshening up?", bundle: bundle)
        case .focusThisWeek: String(localized: "Based on the 7-day trend, what should I focus on this week to improve recovery? Be concrete.", bundle: bundle)
        case .trendingUpDown: String(localized: "Looking at the 7-day and 30-day trends, am I trending up or down overall? In which metrics specifically?", bundle: bundle)
        case .whatDoesHRVTellYou: String(localized: "Translate my HRV numbers into plain English. What do RMSSD, SDNN, LF/HF, and DFA α1 tell you about my autonomic state right now?", bundle: bundle)
        }
    }
}
