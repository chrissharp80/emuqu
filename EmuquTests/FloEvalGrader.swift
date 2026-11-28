@testable import Emuqu
import Foundation

/// A question's grade. `detail` says why, for the dev split only.
struct FloEvalGrade: Sendable {
    enum Outcome: String, Encodable, Sendable, Comparable {
        case fail
        case needsReview = "needs_review"
        case pass

        private var rank: Int {
            switch self {
            case .fail: 0
            case .needsReview: 1
            case .pass: 2
            }
        }

        static func < (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    var outcome: Outcome
    var detail: String
    /// Numbers neither the dataset, the question nor any tool result holds.
    var inventedNumbers: [String] = []
    /// Numbers not in the dataset that a tool result supplied: an app
    /// computation (a baseline, a sum), or a seed placeholder.
    var appNumbersNotInDataset: [String] = []

    var hallucination: Bool {
        !inventedNumbers.isEmpty
    }
}

/// Grades a reply against a question's expected value, deterministically,
/// by the README's rules: a number within its tolerance after the unit
/// changes the README allows; every listed date named; a not-recorded
/// answer that says so and states no value for it; a text answer by its
/// facts where they can be checked, else `needs_review`. Any number the
/// data does not hold fails the answer. No model judges anything.
struct FloEvalGrader {
    /// Every number in `dataset.json`, as text the grounding check reads.
    let datasetNumbers: String

    func grade(_ question: FloEvalQuestion, transcript: FloEvalTranscript) -> FloEvalGrade {
        let reply = FloEvalReplyReader(transcript.reply)
        guard !transcript.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return FloEvalGrade(outcome: .fail, detail: "no reply (\(transcript.error ?? "no error shown"))")
        }
        var grade = answerGrade(question, reply: reply, transcript: transcript)
        (grade.inventedNumbers, grade.appNumbersNotInDataset) = numberCheck(question, transcript: transcript)
        if grade.hallucination {
            grade.outcome = .fail
            grade.detail += "; states numbers the data does not hold: \(grade.inventedNumbers.joined(separator: ", "))"
        }
        return grade
    }

    private func answerGrade(_ question: FloEvalQuestion, reply: FloEvalReplyReader, transcript: FloEvalTranscript) -> FloEvalGrade {
        let expected = question.expected
        switch expected["type"]?.string {
        case "number": return FloEvalNumberRules.number(expected, reply: reply)
        case "date": return FloEvalNumberRules.date(expected, reply: reply)
        case "not_recorded": return FloEvalTextRules.notRecorded(expected, reply: reply, text: transcript.reply)
        default: return FloEvalTextRules.text(expected, reply: reply)
        }
    }

    /// The reply's numbers checked first against the dataset, the expected
    /// value and the question, then against the tool results as well.
    private func numberCheck(_ question: FloEvalQuestion, transcript: FloEvalTranscript) -> (invented: [String], app: [String]) {
        let expected = question.expected.allNumbers.map { String($0) }.joined(separator: " ")
        let data = [datasetNumbers, expected, question.question]
        let notInData = ReplyNumberGrounding.ungrounded(in: transcript.reply, sources: data)
        guard !notInData.isEmpty else { return ([], []) }
        let unexplained = Set(ReplyNumberGrounding.ungrounded(in: transcript.reply, sources: data + transcript.toolResults).map(\.text))
        let invented = notInData.map(\.text).filter { unexplained.contains($0) }
        let fromApp = notInData.map(\.text).filter { !unexplained.contains($0) }
        return (invented, fromApp)
    }
}

/// Tolerances as the questions write them: a number, "1%", "±0.5 ms", or
/// several at once ("±0.5 ms, ±0 bpm, ±5 min").
enum FloEvalTolerance {
    /// Unit to tolerance; a tolerance with no unit is under "", a relative one under "%".
    static func table(_ json: EvalJSON?) -> [String: Double] {
        if let number = json?.number { return ["": number] }
        guard let text = json?.string else { return [:] }
        let pairs = FloEvalReplyReader(text).matches(#"(\d+(?:\.\d+)?)\s*(%|ms|bpm|min|s/km|s\b|km|c\b)?"#)
        return pairs.reduce(into: [:]) { table, groups in
            guard let value = Double(groups[1]) else { return }
            table[groups[2] == "s/km" ? "s" : groups[2]] = value
        }
    }

    /// The tolerance for one expected value, picked by what its key measures.
    static func forKey(_ key: String, in table: [String: Double], value: Double) -> Double {
        let key = key.lowercased()
        let fallback = table[""] ?? (value.rounded() == value ? 0 : 0.5)
        if key.contains("pace") || key.contains("s_per_km") { return table["s"] ?? table[""] ?? 3 }
        if key.contains("temp") { return (table["c"] ?? 0.5) * (key.hasSuffix("_f") ? 1.8 : 1) }
        if key.contains("_ms") || key.hasSuffix("ms") { return table["ms"] ?? table[""] ?? 0.5 }
        if key.contains("bpm") { return table["bpm"] ?? table[""] ?? 0 }
        if key.contains("min") || key.contains("sleep") { return table["min"] ?? table[""] ?? 5 }
        if key.contains("km"), !key.contains("kmh") { return table["km"] ?? 0.05 }
        return fallback
    }

    static func within(_ target: Double, of candidates: [Double], tolerance: Double, relative: Bool = false) -> Bool {
        let allowed = relative ? abs(target) * tolerance / 100 : tolerance
        return candidates.contains { abs(abs($0) - abs(target)) <= allowed + 1e-9 }
    }
}

/// The measurements a reply states, as the app's grounding check reads
/// them: clock times, dates, years and small counts are not measurements.
enum FloEvalGraderNumbers {
    static func statedCount(_ reply: String) -> Int {
        ReplyNumberGrounding.replySentences(reply)
            .filter { !ReplyNumberGrounding.statesAGeneralNorm($0) }
            .flatMap(ReplyNumberGrounding.statedNumbers(in:)).count
    }
}
