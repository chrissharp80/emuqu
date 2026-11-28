import Foundation

/// Which questions the eval may show in full. The questions are a held-out
/// test: a tuner reads the dev half and never the held-out half.
///
/// Rule: sort the question ids ascending; the question at 0-based position
/// 0, 2, 4, ... is dev, the one at 1, 3, 5, ... is held out.
enum FloEvalSplit: String, Encodable, Sendable {
    case dev
    case heldout

    static let rule = "Question ids sorted ascending; 0-based positions 0, 2, 4, ... are dev, 1, 3, 5, ... are heldout."

    static func assign(_ questions: [FloEvalQuestion]) -> [String: FloEvalSplit] {
        let ids = questions.map(\.id).sorted()
        return Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0.isMultiple(of: 2) ? .dev : .heldout) })
    }
}

/// One answered question, everything kept in memory; what is written
/// depends on its split (`FloEvalReport`).
struct FloEvalOutcome: Sendable {
    let question: FloEvalQuestion
    let split: FloEvalSplit
    let transcript: FloEvalTranscript
    let grade: FloEvalGrade
}

/// The results file and its summary. A held-out question is written as its
/// id, category, outcome, tool-call count and hallucination flag only; a
/// dev question in full. The summary holds aggregates only.
enum FloEvalReport {
    static func write(_ outcomes: [FloEvalOutcome], run: FloEvalRunInfo, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let summary = FloEvalSummary(outcomes)
        let file = ResultsFile(
            splitRule: FloEvalSplit.rule, run: run, summary: summary,
            results: outcomes.sorted { $0.question.id < $1.question.id }.map(Record.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try encoder.encode(file).write(to: directory.appendingPathComponent("results.json"), options: .atomic)
        try summary.markdown(run: run).write(to: directory.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
    }

    private struct ResultsFile: Encodable {
        let splitRule: String
        let run: FloEvalRunInfo
        let summary: FloEvalSummary
        let results: [Record]
    }

    /// A result as written: sealed for a held-out question.
    private enum Record: Encodable {
        case sealed(Sealed)
        case full(Full)

        init(_ outcome: FloEvalOutcome) {
            self = outcome.split == .heldout ? .sealed(Sealed(outcome)) : .full(Full(outcome))
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case let .sealed(record): try record.encode(to: encoder)
            case let .full(record): try record.encode(to: encoder)
            }
        }
    }

    private struct Sealed: Encodable {
        let id: String
        let category: String
        let split: FloEvalSplit
        let outcome: FloEvalGrade.Outcome
        let toolCallCount: Int
        let hallucination: Bool

        init(_ outcome: FloEvalOutcome) {
            id = outcome.question.id
            category = outcome.question.category
            split = outcome.split
            self.outcome = outcome.grade.outcome
            toolCallCount = outcome.transcript.toolCalls.count
            hallucination = outcome.grade.hallucination
        }
    }

    private struct Full: Encodable {
        let id, category, question, asOf, gradingNote, reply, detail: String
        let split: FloEvalSplit
        let outcome: FloEvalGrade.Outcome
        let expected: EvalJSON
        let toolCallCount: Int
        let hallucination: Bool
        let toolCalls: [FloEvalTranscript.ToolCall]
        let refusalReasked, numbersReasked, sentencesCut, grokNudged, answeredOnDevice: Bool
        let requestCount: Int
        let inventedNumbers, appNumbersNotInDataset: [String]
        let error: String?

        init(_ outcome: FloEvalOutcome) {
            let (question, transcript, grade) = (outcome.question, outcome.transcript, outcome.grade)
            (id, category, self.question, asOf, gradingNote) = (question.id, question.category, question.question, question.asOf, question.gradingNote)
            (reply, detail, split, self.outcome, expected) = (transcript.reply, grade.detail, outcome.split, grade.outcome, question.expected)
            (toolCallCount, hallucination, toolCalls) = (transcript.toolCalls.count, grade.hallucination, transcript.toolCalls)
            (refusalReasked, numbersReasked, sentencesCut) = (transcript.refusalReasked, transcript.numbersReasked, transcript.sentencesCut)
            (grokNudged, answeredOnDevice, requestCount) = (transcript.grokNudged, transcript.answeredOnDevice, transcript.requestCount)
            (inventedNumbers, appNumbersNotInDataset, error) = (grade.inventedNumbers, grade.appNumbersNotInDataset, transcript.error)
        }
    }
}

/// What ran: the provider, the model and when.
struct FloEvalRunInfo: Encodable, Sendable {
    let provider: String
    let model: String
    let startedAt: String
    let questionCount: Int
}

/// Aggregates over every answered question.
struct FloEvalSummary: Encodable {
    struct Tally: Encodable {
        var count = 0
        var pass = 0
        var fail = 0
        var needsReview = 0
        /// Passes over every question.
        var accuracy: Double { count == 0 ? 0 : Double(pass) / Double(count) }
        /// Passes over the questions graded pass or fail.
        var accuracyOfDecided: Double { pass + fail == 0 ? 0 : Double(pass) / Double(pass + fail) }

        mutating func add(_ outcome: FloEvalGrade.Outcome) {
            count += 1
            switch outcome {
            case .pass: pass += 1
            case .fail: fail += 1
            case .needsReview: needsReview += 1
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(count, forKey: .count)
            try container.encode(pass, forKey: .pass)
            try container.encode(fail, forKey: .fail)
            try container.encode(needsReview, forKey: .needsReview)
            try container.encode(accuracy, forKey: .accuracy)
            try container.encode(accuracyOfDecided, forKey: .accuracyOfDecided)
        }

        private enum Keys: String, CodingKey {
            case count, pass, fail, needsReview, accuracy, accuracyOfDecided
        }
    }

    var overall = Tally()
    var dev = Tally()
    var heldout = Tally()
    var byCategory: [String: Tally] = [:]
    let hallucinationRate: Double
    let meanToolCalls: Double
    let refusalReaskRate: Double
    let numberReaskRate: Double
    let sentencesCutRate: Double
    let answeredOnDevice: Int
    let errors: Int

    init(_ outcomes: [FloEvalOutcome]) {
        let rate: ((FloEvalOutcome) -> Bool) -> Double = { test in
            outcomes.isEmpty ? 0 : Double(outcomes.filter(test).count) / Double(outcomes.count)
        }
        hallucinationRate = rate { $0.grade.hallucination }
        meanToolCalls = outcomes.isEmpty ? 0 : Double(outcomes.map(\.transcript.toolCalls.count).reduce(0, +)) / Double(outcomes.count)
        refusalReaskRate = rate { $0.transcript.refusalReasked }
        numberReaskRate = rate { $0.transcript.numbersReasked }
        sentencesCutRate = rate { $0.transcript.sentencesCut }
        answeredOnDevice = outcomes.filter(\.transcript.answeredOnDevice).count
        errors = outcomes.filter { $0.transcript.error != nil }.count
        for outcome in outcomes { tally(outcome) }
    }

    private mutating func tally(_ outcome: FloEvalOutcome) {
        overall.add(outcome.grade.outcome)
        if outcome.split == .dev { dev.add(outcome.grade.outcome) } else { heldout.add(outcome.grade.outcome) }
        byCategory[outcome.question.category, default: Tally()].add(outcome.grade.outcome)
    }

    func markdown(run: FloEvalRunInfo) -> String {
        let rows = [("overall", overall), ("dev", dev), ("heldout", heldout)] + byCategory.sorted { $0.key < $1.key }.map { ("category: \($0.key)", $0.value) }
        let table = rows.map { name, tally in
            "| \(name) | \(tally.count) | \(tally.pass) | \(tally.fail) | \(tally.needsReview) | \(percent(tally.accuracy)) | \(percent(tally.accuracyOfDecided)) |"
        }
        return ([
            "# Flo answer eval", "", "Provider \(run.provider), model \(run.model), started \(run.startedAt), \(overall.count) of \(run.questionCount) questions.", "",
            FloEvalSplit.rule, "", "| group | n | pass | fail | review | accuracy | accuracy of decided |", "|---|---|---|---|---|---|---|"
        ] + table + [
            "", "- hallucination rate: \(percent(hallucinationRate))", "- mean tool calls: \(String(format: "%.2f", meanToolCalls))",
            "- refusal re-ask rate: \(percent(refusalReaskRate))", "- number re-ask rate: \(percent(numberReaskRate))",
            "- sentences cut rate: \(percent(sentencesCutRate))", "- answered on device (medical guard): \(answeredOnDevice)", "- turns with an error: \(errors)", ""
        ]).joined(separator: "\n")
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}

extension EvalJSON: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .array(items): try container.encode(items)
        case let .object(fields): try container.encode(fields)
        case .null: try container.encodeNil()
        }
    }
}
