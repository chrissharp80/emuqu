import Foundation

/// Intercepts forbidden LLM output before it reaches the
/// user. Pairs with the build-time copy linter (`Tools/copy_linter/`) which
/// guards static strings; this guard runs at request time on freshly
/// generated assistant responses.
///
/// ## Wiring
///
/// Two call sites, both AHEAD of the user:
///
///  1. `StreamTextBuffer.flush` scrubs each COMPLETE SENTENCE before it is
///     appended to the visible turn text. Incomplete tails are held back until
///     the sentence closes, so a prohibited phrase never renders even
///     transiently, and the voice speakable-cursor never advances past
///     unscrubbed text.
///  2. `VoiceConversationController.speak(_:)` scrubs every utterance. That is
///     the single choke point every spoken path routes through — streamed
///     chunks, finalized remainders, completed turns, error lines.
///
/// `AssistantViewModel.applyPostStreamEffects` keeps a final whole-message pass
/// as belt-and-braces for text assembled outside the streaming buffer.
///
/// `CoachVoiceGuardTests` asserts this wiring rather than trusting the prose:
/// a doc that describes a control which is not actually in place would lead a
/// reviewer to conclude the control exists.
///
/// ## Behaviour
///
///   • Each prohibited concept has a deflection — a generic, non-diagnostic
///     replacement that preserves the conversational thread without
///     reproducing the regulated framing.
///   • Replacement is regex-based and case-insensitive; the deflection
///     replaces the entire matched phrase plus the sentence it sits in,
///     since "you may have COVID, so see a doctor" needs the whole
///     thought neutralised, not just one phrase.
///   • Triggered replacements are surfaced via `result.triggers` so callers
///     can log incidents (a "FDA copy perimeter
///     violation in LLM output" risk).
///   • The vocabulary is `MedicalTermLexicon`, shared with
///     `MedicalQueryGuard` and covering English plus the sixteen other
///     shipped languages.
///     `scripts/check_perimeter_sync.sh` fails the build if the build-time
///     linter grows a term this lexicon cannot match.
enum CoachVoiceGuard {
    /// One scrub rule: a concept from the shared lexicon plus the copy that
    /// replaces it.
    struct Rule {
        let concept: MedicalTermLexicon.Concept
        let reason: String

        var id: String { concept.id }
        /// Resolved at use, not stored, so it follows the in-app language
        /// when the user switches it mid-session.
        var deflection: String { CoachVoiceGuard.deflection(for: concept.id) }
    }

    /// Deflections are keyed by concept id so a lexicon addition without a
    /// deflection is a compile-time-visible omission rather than a silent
    /// pass-through. `CoachVoiceGuardTests.testEveryScrubbedConceptHasARule`
    /// asserts the mapping is total.
    static let rules: [Rule] = MedicalTermLexicon.scrubFromOutput.map { concept in
        Rule(concept: concept, reason: "Coach output: \(concept.id).")
    }

    /// The replacement sentence for each concept, in the in-app language.
    ///
    /// Deflections come from the string catalogue: the scrubbed reply is
    /// spliced into the model's text and spoken by the voice coach, so it has
    /// to be in the language the model is answering in. Every translation must
    /// stay clear of `MedicalTermLexicon`, or the guard would rewrite its own
    /// output.
    static func deflection(for conceptID: String) -> String {
        deflections[conceptID] ?? observationFallback
    }

    /// Used for anything without a more specific line, and for the two
    /// diagnosis-shaped concepts, which want exactly this framing.
    private static var observationFallback: String {
        String(
            localized: "Your data shows a notable pattern. The cause is for you to investigate.",
            bundle: LanguageManager.appBundle
        )
    }

    /// Internal rather than private so
    /// `CoachVoiceGuardTests.testDeflectionsCoverExactlyTheScrubbedConcepts`
    /// can assert the mapping in BOTH directions. Checking only that every
    /// scrubbed concept has a deflection left the other direction — a
    /// deflection for a concept nothing scrubs — invisible, and there was one.
    /// Rebuilt on each read so the strings follow the in-app language; it is
    /// only read when a rule has matched.
    static var deflections: [String: String] {
        specificDeflections.merging(sharedDeflections) { specific, _ in specific }
    }

    /// Concepts with a sentence of their own.
    private static var specificDeflections: [String: String] {
        let bundle = LanguageManager.appBundle
        return [
            MedicalTermLexicon.medicalReferral.id: String(
                localized: "Worth checking with a healthcare professional if you're concerned.", bundle: bundle),
            MedicalTermLexicon.symptomOfDisease.id: String(
                localized: "These signals are observations of your physiology, not symptoms of any condition.",
                bundle: bundle),
            MedicalTermLexicon.namedCardiacCondition.id: String(
                localized: "Emuqu measures beat-to-beat timing and cannot identify any cardiac condition. A clinician is the right place for that question.",
                bundle: bundle),
            MedicalTermLexicon.neurovascularEvent.id: String(
                localized: "Emuqu measures beat-to-beat timing and cannot identify any condition of that kind. A clinician is the right place for that question.",
                bundle: bundle),
            MedicalTermLexicon.overtraining.id: String(
                localized: "Your training pattern shows accumulated stress.", bundle: bundle),
            MedicalTermLexicon.regulatoryClearance.id: String(
                localized: "Emuqu is a wellness tool, not a medical device, and holds no regulatory clearance.",
                bundle: bundle)
        ].merging(verdictDeflections) { specific, _ in specific }
    }

    /// Replacements that keep the observation and drop the verdict — the
    /// register the app is supposed to use. The model is free to describe any
    /// metric; it may not tell the user which of their readings is the real one.
    private static var verdictDeflections: [String: String] {
        let bundle = LanguageManager.appBundle
        return [
            MedicalTermLexicon.categoricalAutonomicState.id: String(
                localized: "Your numbers sit in a range often associated with that pattern. One reading can't establish a state on its own.",
                bundle: bundle),
            MedicalTermLexicon.physiologicalCertainty.id: String(
                localized: "Something in your numbers is outside your usual range. What it means is for you to look into, alongside how you feel.",
                bundle: bundle),
            MedicalTermLexicon.unsupportedMetricVerdict.id: String(
                localized: "That's one signal among several, and it describes a range rather than settling anything. Read it next to your sleep, training and how you feel.",
                bundle: bundle)
        ]
    }

    /// Concepts that share one sentence with others of their kind.
    private static var sharedDeflections: [String: String] {
        let lexicon = MedicalTermLexicon.self
        let groups: [(ids: [String], text: String)] = [
            ([lexicon.speculativeDiagnosis.id, lexicon.diagnosis.id, lexicon.pathology.id,
              lexicon.clinicalPhysiologyLabels.id], observationFallback),
            ([lexicon.atrialFibrillation.id, lexicon.arrhythmia.id, lexicon.irregularHeartbeat.id],
             rhythmDeflection),
            ([lexicon.injuryRisk.id, lexicon.riskZoneFraming.id], loadDeflection),
            ([lexicon.cure.id, lexicon.treatmentClaim.id, lexicon.prescription.id], outOfScopeDeflection)
        ]
        return Dictionary(
            groups.flatMap { group in group.ids.map { ($0, group.text) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static var rhythmDeflection: String {
        String(
            localized: "Emuqu measures beat-to-beat timing; it doesn't assess heart rhythm. A clinician or a clinically validated ECG is the right place for that question.",
            bundle: LanguageManager.appBundle
        )
    }

    private static var loadDeflection: String {
        String(
            localized: "Your training has been heavier than usual — easier days help your body absorb it.",
            bundle: LanguageManager.appBundle
        )
    }

    private static var outOfScopeDeflection: String {
        String(localized: "That's outside what this app can advise on.", bundle: LanguageManager.appBundle)
    }

    /// Compiled once. `scrub` is called per completed sentence at streaming
    /// rate, so compiling twenty regexes per call is not acceptable.
    private static let compiled: [(rule: Rule, regex: NSRegularExpression)] =
        rules.compactMap { rule in
            MedicalTermLexicon.regex(for: rule.concept).map { (rule, $0) }
        }

    /// Result of a scrub pass.
    struct Result {
        /// Output safe to display.
        let scrubbed: String
        /// Reasons + matched sentences for any triggered rule. Empty when
        /// the input was clean. Callers should log these for review.
        let triggers: [(reason: String, originalSentence: String)]
        /// Convenience flag.
        var didIntercept: Bool { !triggers.isEmpty }
    }

    /// Scrub `output` against the rule set. Returns a `Result` with the
    /// safe-to-display text plus an audit trail.
    ///
    /// The text is split into sentences ONCE, and each sentence is mapped
    /// through the rules independently — first matching rule wins, and a
    /// rewritten sentence is never re-examined. Sentences that match nothing
    /// are returned byte-identical, whitespace included.
    ///
    /// Not a per-rule "find first match, rewrite, re-scan the whole string"
    /// loop bounded by an iteration cap. Such a cap reads as a safety net
    /// against a self-matching deflection, but it is also a quota on the
    /// perimeter: a reply tripping one rule in more sentences than the cap
    /// has the rest DELIVERED VERBATIM (measured with a 32-cap on a
    /// 200-prohibited-sentence input: 64 rewritten, 136 passed through
    /// untouched, with only a debug log to show for it). Mapping over a
    /// fixed sentence list terminates by construction, so there is nothing
    /// to cap; it is also linear in the input rather than quadratic.
    static func scrub(_ output: String) -> Result {
        guard !output.isEmpty, let wholeTextMatch = firstMatchingEntry(in: output) else {
            return Result(scrubbed: output, triggers: [])
        }
        let segments = sentenceSegments(of: output)
        var triggers: [(reason: String, originalSentence: String)] = []
        var rebuilt = ""
        rebuilt.reserveCapacity(output.count)
        for segment in segments {
            rebuilt += rewrite(segment, triggers: &triggers)
        }
        guard !triggers.isEmpty else {
            return deflectStraddlingMatch(output, segments: segments, entry: wholeTextMatch)
        }
        return Result(scrubbed: tidy(rebuilt), triggers: triggers)
    }

    /// The whole text matched a rule but no single sentence did, so the phrase
    /// straddles a sentence terminator — `see a\ndoctor` wrapped across a
    /// newline, or a term split by the Arabic comma.
    ///
    /// Replace the sentences the match actually spans, keeping the rest of the
    /// reply. If that is not possible, or if the result would still trip a rule,
    /// fall back to deflecting the whole message: this guard has already proved
    /// it can detect the phrase, so handing it back is not an option.
    private static func deflectStraddlingMatch(
        _ output: String,
        segments: [Substring],
        entry: (rule: Rule, regex: NSRegularExpression)
    ) -> Result {
        debugLog(
            "[CoachVoiceGuard] cross-sentence match for rule \(entry.rule.id)",
            level: .error
        )
        let whole = NSRange(output.startIndex..., in: output)
        guard let match = entry.regex.firstMatch(in: output, options: [], range: whole),
              let matched = Range(match.range, in: output),
              let rebuilt = replacing(segments, spanning: matched, with: entry.rule.deflection),
              firstMatchingEntry(in: rebuilt) == nil
        else {
            return Result(scrubbed: entry.rule.deflection, triggers: [(entry.rule.reason, output)])
        }
        return Result(scrubbed: tidy(rebuilt),
                      triggers: [(entry.rule.reason, String(output[matched]))])
    }

    /// Rebuild the text with every segment overlapping `matched` collapsed into
    /// a single `deflection`. Nil when no segment overlaps, which would mean
    /// returning the original text with the match still in it.
    private static func replacing(
        _ segments: [Substring],
        spanning matched: Range<String.Index>,
        with deflection: String
    ) -> String? {
        var rebuilt = ""
        var replaced = false
        for segment in segments {
            guard segment.startIndex < matched.upperBound,
                  matched.lowerBound < segment.endIndex else {
                rebuilt += segment
                continue
            }
            if !replaced {
                rebuilt += deflection
                replaced = true
            }
        }
        return replaced ? rebuilt : nil
    }

    /// Cheap pre-check: does this text contain anything at all worth rewriting?
    /// Lets the streaming path skip the rewrite machinery on the overwhelming
    /// majority of sentences, which are clean.
    ///
    /// Shares `firstMatchingEntry` with `scrub`, so the pre-check and the scrub
    /// cannot disagree about what counts as prohibited.
    static func containsProhibitedLanguage(_ text: String) -> Bool {
        firstMatchingEntry(in: text) != nil
    }

    /// The first rule whose pattern appears anywhere in `text`, with the regex
    /// that matched it, or nil.
    ///
    /// Tries the text as written, then with inline markdown emphasis removed.
    /// Without that, `You may have *atrial* fibrillation.` evades every
    /// rule, because `atrial\s+fib` needs whitespace directly after `atrial`
    /// and finds an asterisk. `**atrial fibrillation**` is caught anyway
    /// (the markers sit outside the phrase); emphasis INSIDE a multi-word term
    /// is the hole. Models emit markdown constantly, so this is an ordinary
    /// output shape rather than an exotic one.
    ///
    /// The second pass is safe here because every caller that needs a match
    /// RANGE (`deflectStraddlingMatch`) re-runs the regex against the original
    /// text and fails closed if it finds nothing; the callers that only need a
    /// yes/no answer replace the whole sentence anyway.
    private static func firstMatchingEntry(
        in text: String
    ) -> (rule: Rule, regex: NSRegularExpression)? {
        guard !text.isEmpty else { return nil }
        if let direct = firstMatch(in: text) { return direct }
        let plain = withoutInlineEmphasis(text)
        return plain == text ? nil : firstMatch(in: plain)
    }

    private static func firstMatch(
        in text: String
    ) -> (rule: Rule, regex: NSRegularExpression)? {
        let range = NSRange(text.startIndex..., in: text)
        return compiled.first {
            $0.regex.firstMatch(in: text, options: [], range: range) != nil
        }
    }

    /// Strip `*`, `_` and backticks used as inline emphasis. Deliberately not a
    /// markdown parser: the guard only needs the words to sit next to each
    /// other again.
    private static func withoutInlineEmphasis(_ text: String) -> String {
        text.filter { !emphasisMarkers.contains($0) }
    }

    private static let emphasisMarkers: Set<Character> = ["*", "_", "`"]

    /// Tidy double spaces / orphaned punctuation introduced by sentence
    /// replacement. Only runs when something was actually replaced.
    private static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " ,", with: ",")
    }

    /// Replace one sentence if any rule matches it, else return it unchanged.
    ///
    /// The segment is treated as `[leading whitespace][core][trailing
    /// whitespace]` and only the core is replaced, so the spacing that joined
    /// this sentence to its neighbours survives — the same thing the old
    /// `expandToSentence` achieved by skipping whitespace before replacing.
    private static func rewrite(
        _ segment: Substring,
        triggers: inout [(reason: String, originalSentence: String)]
    ) -> String {
        var coreStart = segment.startIndex
        while coreStart < segment.endIndex, segment[coreStart].isWhitespace {
            coreStart = segment.index(after: coreStart)
        }
        var coreEnd = segment.endIndex
        while coreEnd > coreStart, segment[segment.index(before: coreEnd)].isWhitespace {
            coreEnd = segment.index(before: coreEnd)
        }
        guard coreStart < coreEnd else { return String(segment) }
        let core = String(segment[coreStart ..< coreEnd])
        guard let entry = firstMatchingEntry(in: core) else { return String(segment) }
        triggers.append((entry.rule.reason, core))
        return String(segment[..<coreStart]) + entry.rule.deflection + String(segment[coreEnd...])
    }

    /// Split `text` into segments that concatenate back to `text` exactly.
    /// Each segment runs up to and including its terminator, plus any
    /// whitespace separating it from the next.
    private static func sentenceSegments(of text: String) -> [Substring] {
        var segments: [Substring] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            guard isSentenceTerminator(in: text, at: index) else {
                index = text.index(after: index)
                continue
            }
            let end = endOfSegment(in: text, terminatorAt: index)
            segments.append(text[start ..< end])
            start = end
            index = end
        }
        if start < text.endIndex { segments.append(text[start...]) }
        return segments
    }

    /// Where the segment closed by the terminator at `index` ends: past any
    /// further terminators — a run like `?!` or `...` closes one sentence, not
    /// three — and then past the whitespace before the next sentence.
    ///
    /// The two runs are separate on purpose. Folding them into one condition
    /// would also swallow a terminator that FOLLOWS whitespace, merging `". ."`
    /// into a single segment.
    private static func endOfSegment(in text: String, terminatorAt index: String.Index) -> String.Index {
        var end = text.index(after: index)
        while end < text.endIndex, isSentenceTerminator(in: text, at: end) {
            end = text.index(after: end)
        }
        while end < text.endIndex, text[end].isWhitespace {
            end = text.index(after: end)
        }
        return end
    }

    /// `。`, `？`, `！` are the CJK forms; `؟` is the Arabic question mark.
    /// Without these a match in a CJK or Arabic reply expands to the whole
    /// message.
    static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", "\n", "。", "！", "？", "،", "؟", "…"
    ]

    /// Whether the character at `index` ends a sentence. A "." right after a
    /// digit is a decimal point when a digit follows it ("RMSSD 22.5"), and
    /// undecided when the text ends there (a stream may still deliver the
    /// digits), so neither splits a sentence. A stream's undecided tail is
    /// published when the round ends.
    static func isSentenceTerminator(in text: String, at index: String.Index) -> Bool {
        let char = text[index]
        guard sentenceTerminators.contains(char) else { return false }
        guard char == ".", index > text.startIndex, text[text.index(before: index)].isNumber else { return true }
        let next = text.index(after: index)
        return next < text.endIndex && !text[next].isNumber
    }

    /// Split `text` into (complete sentences, incomplete tail).
    ///
    /// Used by the streaming path: only the complete part is safe to scrub and
    /// publish, because a rule can only judge a whole sentence. The tail waits
    /// for its terminator.
    static func splitAtLastSentenceBoundary(_ text: String) -> (complete: String, tail: String) {
        guard let lastTerminator = text.indices.last(where: { isSentenceTerminator(in: text, at: $0) }) else {
            return ("", text)
        }
        let cut = text.index(after: lastTerminator)
        return (String(text[..<cut]), String(text[cut...]))
    }
}
