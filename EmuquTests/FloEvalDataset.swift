import Foundation

/// The eval seed's `dataset.json`, decoded with snake_case keys turned to
/// camelCase. Field meanings and units are the file's own `schema` section;
/// every value here is as the file states it.
struct FloEvalDataset: Decodable {
    let overnights: [Overnight]
    let partialRecordings: [Partial]
    let shortReadings: [ShortReading]
    let workouts: [Workout]

    struct Overnight: Decodable {
        let id: String
        let wakeDate: String
        let device: String
        let recordingStartLocal: String
        let recordingEndLocal: String
        let bedtimeLocal: String
        let wakeTimeLocal: String
        let timeInBedMinutes: Int
        let totalSleepMinutes: Int
        let deepMinutes: Int
        let remMinutes: Int
        let lightMinutes: Int
        let awakeMinutes: Int
        let rmssdMs: Double
        let sdnnMs: Double
        let nadirHrBpm: Double
        let nadirTimeLocal: String
        let meanHrBpm: Double
        let maxHrBpm: Double
        let respiratoryRateBrpm: Double
        let spo2AvgPct: Double
        let wristTempDeviationC: Double
        let restingHrBpm: Double
        let recoveryScore0100: Int
        let recoveryFactors: [String: Int]
        let baselineRmssdMs: Double
        let baselineRestingHrBpm: Double
        let morningFeeling15: Int?
        let tags: [String]
        let notes: String?
    }

    struct Partial: Decodable {
        let id: String
        let wakeDate: String
        let startLocal: String
        let endLocal: String
        let rmssdMs: Double
        let meanHrBpm: Double
        let reason: String
    }

    struct ShortReading: Decodable {
        let id: String
        let kind: String
        let startLocal: String
        let endLocal: String
        let rmssdMs: Double
        let meanHrBpm: Double
    }

    struct Workout: Decodable {
        let id: String
        let type: String
        let startLocal: String
        let durationS: Int
        let distanceKm: Double?
        let avgPaceSPer500m: Double?
        let avgHrBpm: Double
        let maxHrBpm: Double
        let elevationGainM: Double?
        let splits: [WorkoutSplit]
        let weather: Weather?
        let indoor: Bool
        let feeling15: Int?
        let hrAtStopBpm: Int?
        let hrr60sBpm: Int?
        let trainingLoad: Double?
        let notes: String?
    }

    struct WorkoutSplit: Decodable {
        let split: Int
        let distanceKm: Double
        let durationS: Double
        let paceSPerKm: Double
        let avgHrBpm: Double
    }

    struct Weather: Decodable {
        let tempC: Double
        let conditions: String?
        let windKmh: Double?
    }

    static func load(from url: URL) throws -> FloEvalDataset {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(FloEvalDataset.self, from: Data(contentsOf: url))
    }
}

/// One question of `questions.json`. `expected` keeps its JSON shape: its
/// fields differ by answer type and the grader reads them as they are.
struct FloEvalQuestion: Sendable {
    let id: String
    let category: String
    let question: String
    let asOf: String
    let expected: EvalJSON
    let gradingNote: String

    static func load(from url: URL) throws -> [FloEvalQuestion] {
        guard case let .array(items)? = try EvalJSON.load(from: url)["questions"] else { throw EvalSeedError.malformed("questions") }
        return try items.map(question)
    }

    private static func question(_ item: EvalJSON) throws -> FloEvalQuestion {
        guard let id = item["id"]?.string, let category = item["category"]?.string, let text = item["question"]?.string,
              let asOf = item["as_of"]?.string, let expected = item["expected"]
        else { throw EvalSeedError.malformed("question") }
        return FloEvalQuestion(
            id: id, category: category, question: text, asOf: asOf, expected: expected, gradingNote: item["grading_note"]?.string ?? ""
        )
    }
}

enum EvalSeedError: Error {
    case malformed(String)
}

/// Any JSON value, for the parts of the seed whose shape varies.
enum EvalJSON: Sendable, Equatable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case array([EvalJSON])
    case object([String: EvalJSON])
    case null

    /// A value `JSONSerialization` produced. A boolean arrives as an
    /// `NSNumber` too, so it is told apart by its CoreFoundation type.
    init(_ value: Any) {
        switch value {
        case let flag as NSNumber where CFGetTypeID(flag) == CFBooleanGetTypeID(): self = .bool(flag.boolValue)
        case let number as NSNumber: self = .number(number.doubleValue)
        case let text as String: self = .string(text)
        case let items as [Any]: self = .array(items.map(EvalJSON.init))
        case let fields as [String: Any]: self = .object(fields.mapValues(EvalJSON.init))
        default: self = .null
        }
    }

    subscript(key: String) -> EvalJSON? {
        if case let .object(fields) = self { return fields[key] }
        return nil
    }

    var number: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// Every number anywhere inside, depth first.
    var allNumbers: [Double] {
        switch self {
        case let .number(value): [value]
        case let .array(items): items.flatMap(\.allNumbers)
        case let .object(fields): fields.values.flatMap(\.allNumbers)
        default: []
        }
    }

    static func load(from url: URL) throws -> EvalJSON {
        EvalJSON(try JSONSerialization.jsonObject(with: Data(contentsOf: url)))
    }
}

/// The seed's clock strings, in the dataset's time zone.
enum EvalClock {
    static let timeZone = TimeZone(identifier: "America/Denver") ?? .current

    /// "2025-11-30T22:08-07:00": a local time with its offset.
    static func instant(_ text: String) -> Date? {
        formatter("yyyy-MM-dd'T'HH:mmxxxxx").date(from: text)
    }

    /// "2026-03-24T07:30": a question's `as_of`, Denver wall clock.
    static func asOf(_ text: String) -> Date? {
        formatter("yyyy-MM-dd'T'HH:mm").date(from: text)
    }

    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter
    }
}
