//
//  MedicalQueryGuard.swift
//  Emuqu
//
//  Pre-send filter that intercepts AFib / arrhythmia / symptom-triage
//  questions BEFORE they reach the LLM, replaces the model's output with
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
        /// the LLM for this turn. The string is intentionally identical
        /// to the wording in the system prompt so users get a consistent
        /// experience whether the local guard or the model handles it.
        case refuse(reply: String)
    }

    /// Which family of concern fired. Surfaced so the caller can log the
    /// category without logging the user's text.
    enum Trigger: String {
        case rhythm
        case symptom
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

    // MARK: - Replies

    /// Reply text MUST match the system prompt's wording so that
    /// guard-triggered refusals look identical to model-generated ones.
    /// Updating either site requires updating the other.
    static var arrhythmiaReply: String {
        String(
            localized: "Emuqu doesn't detect AFib or arrhythmia — it isn't a medical device. If you're worried about your heart rhythm, talk to your doctor. Apple Watch has a clinically validated ECG feature that's designed for that specific purpose.",
            bundle: LanguageManager.appBundle
        )
    }

    static var symptomReplyTemplate: String {
        String(
            localized: "Talk to your doctor about that. I can't assess your health — Emuqu is a fitness coaching app, not a medical device. If you're feeling unwell, please contact a clinician (or your local emergency number for severe symptoms).",
            bundle: LanguageManager.appBundle
        )
    }

    // MARK: - Evaluation

    /// Run the guard against a user message.
    static func evaluate(_ text: String) -> Outcome {
        switch classify(text) {
        case .rhythm?: return .refuse(reply: arrhythmiaReply)
        case .symptom?: return .refuse(reply: symptomReplyTemplate)
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
        // reply that points at a clinically validated ECG.
        let matches = { (patterns: [NSRegularExpression]) in
            patterns.contains { $0.firstMatch(in: trimmed, range: range) != nil }
        }
        if matches(emergencyPatterns) { return .symptom }
        if matches(rhythmPatterns) { return .rhythm }
        if matches(generalConcernPatterns) { return .symptom }
        return nil
    }
}
