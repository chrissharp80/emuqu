//
//  MedicalQueryGuard.swift
//  Emuqu
//
//  Pre-send filter that intercepts AFib / arrhythmia / symptom-triage
//  questions and injury reports BEFORE they reach the LLM, replaces the model's output with
//  a hardcoded refusal, and routes the user back to a clinician.
//
//  The system prompt has the same
//  guidance, but a hardcoded check at the entry point is the belt-and-
//  suspenders second leg — it works even when:
//    • the user picks a provider whose model ignores system-prompt rules
//      (smaller / older / fine-tuned models),
//    • the system prompt is truncated by token budget,
//    • a future refactor moves or shortens the medical-boundary section,
//    • a jailbreak prompt convinces the model to ignore prior instructions.
//
//  The guard runs locally, takes ~1 ms, and is impossible to bypass via
//  prompt injection. If it fires, no PHI leaves the device for that turn.
//
//  NOT ENGLISH ONLY. The app ships sixteen non-English
//  localizations at 100% catalogue coverage and its assistant answers in the
//  user's language, so English-only regexes would mean the guard did not
//  exist for sixteen of seventeen shipped languages ("¿tengo fibrilación
//  auricular?" would slip through). The
//  vocabulary comes from `MedicalTermLexicon`, which is shared with
//  `CoachVoiceGuard` and covers every shipped locale.
//
//  The refusal copy is localized too — hardcoded English would mean that on
//  the one path where the guard DOES fire for a non-English user, they get a
//  safety message they might not read.
//

import Foundation

enum MedicalQueryGuard {
    /// Outcome of running the user's input through the guard.
    enum Outcome: Equatable {
        /// Input is safe to send to the LLM.
        case proceed
        /// Input matched a medical/AFib trigger. The bundled string is
        /// the canned assistant turn to render — do NOT send anything to
        /// the LLM for this turn. The symptom and self-harm replies are the
        /// wording rule B of the system prompt tells the model to use, so
        /// users get the same answer whether the guard or the model handles it.
        case refuse(reply: String)
    }

    /// Which family of concern fired. Surfaced so the caller can log the
    /// category without logging the user's text.
    enum Trigger: String {
        case rhythm
        case symptom
        case selfHarm
        case injury
    }

    // MARK: - Compiled patterns

    /// Rhythm-related concepts: we do not detect, rule out, or discuss the
    /// user's own rhythm. Compiled once — this runs on every send.
    ///
    /// Composed from `MedicalTermLexicon.refuseAsRhythm`
    /// rather than re-listing the concepts here: a hand-written copy
    /// drifts from the lexicon group that documents this guard's job.
    private static let rhythmPatterns: [NSRegularExpression] =
        MedicalTermLexicon.refuseAsRhythm.compactMap(MedicalTermLexicon.regex(for:))

    /// Symptoms that warrant a "talk to your clinician" redirect. Deliberately
    /// narrow — discussing one's own training data is fine, symptom triage is
    /// not.
    /// Split in two so the ORDER of the checks in `classify` can encode which
    /// answer matters more when a question matches both families. See
    /// `MedicalTermLexicon.refuseAsEmergency`.
    private static let emergencyPatterns: [NSRegularExpression] =
        MedicalTermLexicon.refuseAsEmergency.compactMap(MedicalTermLexicon.regex(for:))

    private static let generalConcernPatterns: [NSRegularExpression] =
        MedicalTermLexicon.refuseAsGeneralConcern.compactMap(MedicalTermLexicon.regex(for:))

    /// Checked before everything else. Someone saying they are suicidal was
    /// matched as an emergency and got the symptom reply — "talk to your
    /// doctor", with no crisis line — which is the wrong answer to the most
    /// serious thing a user can type.
    private static let selfHarmPatterns: [NSRegularExpression] =
        [MedicalTermLexicon.selfHarm].compactMap(MedicalTermLexicon.regex(for:))

    /// "I'm hurt", "I fell", "I think my ankle is broken". Answered here, not
    /// by the model, so someone who is injured is told to call the local
    /// emergency number before anything else — the model's navigation tool
    /// would otherwise offer a walking route to a hospital.
    private static let injuryPatterns: [NSRegularExpression] =
        MedicalTermLexicon.refuseAsInjury.compactMap(MedicalTermLexicon.regex(for:))

    // MARK: - Replies

    /// States the position of rule C in the system prompt (the app cannot
    /// detect or rule out an arrhythmia; Apple Watch's ECG is built for it).
    /// Rule C lets the model go on to discuss the topic; the guard does not.
    static var arrhythmiaReply: String {
        String(
            localized: "Emuqu doesn't detect AFib or arrhythmia — it isn't a medical device. If you're worried about your heart rhythm, talk to your doctor. Apple Watch has a clinically validated ECG feature that's designed for that specific purpose.",
            bundle: LanguageManager.appBundle
        )
    }

    /// Word for word the reply rule B of the system prompt asks for on a
    /// severe symptom. Updating either site requires updating the other.
    /// It opens by telling anyone mid-workout to stop: chest pain or
    /// fainting during exercise is the case where that matters most, and
    /// the line is harmless for someone at rest.
    static var symptomReplyTemplate: String {
        String(
            localized: "If you're exercising, stop now. Talk to your doctor about that. I can't assess your health — Emuqu is a fitness coaching app, not a medical device. If you're feeling unwell, please contact a clinician (or your local emergency number for severe symptoms).",
            bundle: LanguageManager.appBundle
        )
    }

    /// Points at people, not at the app: a crisis line anywhere in the world,
    /// the US number for the largest share of users, and the emergency number
    /// for immediate danger. Must match rule B's self-harm wording in the
    /// system prompt.
    static var selfHarmReply: String {
        String(
            localized: "I'm really sorry you're feeling this way. You don't have to go through it alone — please reach out to someone now. If you might act on these thoughts or you're in danger, call your local emergency number. You can find a free, confidential crisis line in your country at findahelpline.com, or in the US call or text 988.",
            bundle: LanguageManager.appBundle
        )
    }

    /// Word for word the injury reply rule B of the system prompt asks for.
    /// Non-diagnostic: it does not judge how serious the injury is, it says
    /// who can. Updating either site requires updating the other.
    static var injuryReply: String {
        String(
            localized: """
            If you're hurt, stop what you're doing. If it could be serious or you need help now, call your local emergency number. \
            I can't assess injuries — Emuqu is a fitness coaching app, not a medical device. Otherwise, please see a clinician.
            """,
            bundle: LanguageManager.appBundle
        )
    }

    // MARK: - Evaluation

    /// Run the guard against a user message.
    static func evaluate(_ text: String) -> Outcome {
        switch classify(text) {
        case .selfHarm?: return .refuse(reply: selfHarmReply)
        case .rhythm?: return .refuse(reply: arrhythmiaReply)
        case .symptom?: return .refuse(reply: symptomReplyTemplate)
        case .injury?: return .refuse(reply: injuryReply)
        case nil: return .proceed
        }
    }

    /// The trigger family, or nil when the text is safe to send. Split out from
    /// `evaluate` so callers can log the category without holding the reply.
    static func classify(_ text: String) -> Trigger? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        // Order is the safety decision, not an implementation detail. An acute
        // symptom outranks a rhythm question, because its reply is the one that
        // names an emergency number; a request for a risk judgement does not,
        // because "should I be worried about my AFib" is better served by the
        // reply that points at a clinically validated ECG. An injury comes after
        // the acute symptoms, whose reply also names the emergency number, and
        // before rhythm, because someone who is hurt needs that number first.
        let matches = { (patterns: [NSRegularExpression]) in
            patterns.contains { $0.firstMatch(in: trimmed, range: range) != nil }
        }
        if matches(selfHarmPatterns) { return .selfHarm }
        if matches(emergencyPatterns) { return .symptom }
        if matches(injuryPatterns) { return .injury }
        if matches(rhythmPatterns) { return .rhythm }
        if matches(generalConcernPatterns) { return .symptom }
        return nil
    }
}
