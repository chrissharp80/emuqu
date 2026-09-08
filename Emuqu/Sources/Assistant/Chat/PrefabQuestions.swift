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
        switch self {
        case .howAmIDoing: "How am I doing today?"
        case .whyIsScoreThis: "Why is my score what it is?"
        case .shouldITrainHard: "Should I train hard today?"
        case .whatChanged: "What changed from yesterday?"
        case .howVsBaseline: "How do I compare to my baseline?"
        case .wasSleepGood: "Was my sleep good?"
        case .isTrainingLoadOK: "Is my training load okay?"
        case .focusThisWeek: "What should I focus on this week?"
        case .trendingUpDown: "Am I trending up or down?"
        case .whatDoesHRVTellYou: "What does my HRV tell you?"
        }
    }

    /// Slightly expanded version sent to the model as the user message.
    /// More specific phrasing produces better answers across providers.
    var prompt: String {
        switch self {
        case .howAmIDoing: "Give me a clear summary of how I'm doing today based on my recovery data. Hit the highlights and the things to watch."
        case .whyIsScoreThis: "Explain why my recovery score is what it is today. Use the factor breakdown and probable causes — be specific about which factors are dragging or carrying the score, and reference the actual numbers."
        case .shouldITrainHard: "Based on today's recovery and my training load (ATL/CTL/TSB), should I train hard today, train easy, or rest? Tell me why."
        case .whatChanged: "Compare today to yesterday. What changed in HRV, sleep, training load, and vitals? Call out anything notable."
        case .howVsBaseline: "How do today's numbers compare to my personal baseline? Use the rolling baseline stats and call out any meaningful deviations."
        case .wasSleepGood: "Walk me through last night's sleep — duration, efficiency, deep, REM, awake time. Was it actually good for me, or just OK?"
        case .isTrainingLoadOK: "Look at my ATL, CTL, and TSB. Am I in a good training-load zone, undertraining, high strain, or freshening up?"
        case .focusThisWeek: "Based on the 7-day trend, what should I focus on this week to improve recovery? Be concrete."
        case .trendingUpDown: "Looking at the 7-day and 30-day trends, am I trending up or down overall? In which metrics specifically?"
        case .whatDoesHRVTellYou: "Translate my HRV numbers into plain English. What do RMSSD, SDNN, LF/HF, and DFA α1 tell you about my autonomic state right now?"
        }
    }
}
