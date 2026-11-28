import Foundation

/// A stored session exactly as the archive persists it, as a `FactValue`
/// tree. The session's own `Codable` conformance writes the JSON, so every
/// stored property arrives under its stored key, a property added later
/// included, and nobody has to pick it for the assistant to see it. Only the
/// paths in `storedRecordDenyList` are taken out.
///
/// The encoder differs from the archive's in one choice: dates are written
/// as ISO 8601 in the user's time zone, so a bedtime reads as the clock the
/// user saw rather than UTC.
enum StoredSessionTree {
    /// Stored paths left out of every record, dotted from the session's top
    /// level. A path starting with `*.` matches that key at any depth.
    /// Everything not named here passes through.
    static let storedRecordDenyList: Set<String> = [
        // The raw beat series: tens of thousands of beats a night. hrv.timeline.by_date reads it.
        "rrSeries",
        // One artifact flag per raw beat, parallel to rrSeries.
        "artifactFlags",
        // The per-second sample stream of a workout. workout.timeline.by_date reads it.
        "workoutMetadata.samples",
        // HealthKit internal offsets: which per-second samples took Apple Health heart rate.
        "workoutMetadata.healthKitHROffsets",
        // The GPS track. The location consent discloses start points only, so nothing positional leaves.
        "workoutMetadata.gpsPolyline",
        // When each GPS fix was taken: positional, paired with the track.
        "workoutMetadata.gpsFixTimes",
        // Indices into the GPS track where a recorded segment starts: positional.
        "workoutMetadata.gpsSegmentStarts",
        // The assistant's own frozen context for the session, not the user's data.
        "aiContext",
        // Apple Health export bookkeeping: when the workout was pushed.
        "healthKitExportedAt",
        // Apple Health export bookkeeping: how many pushes failed.
        "healthKitExportFailureCount",
        // File format versions, at any depth: bookkeeping.
        "*.schemaVersion"
    ]

    /// The session as stored, minus the deny-listed paths.
    static func storedRecordTree(of session: HRVSession) -> FactValue {
        guard let data = attempt("assistant.storedRecord.encode", { try storedSessionJSONEncoder().encode(session) }),
              let object = attempt("assistant.storedRecord.parse", { try JSONSerialization.jsonObject(with: data) }),
              let tree = storedValue(object, path: "")
        else { return .missing(reason: .internalError, detail: "the stored session could not be read") }
        return tree
    }

    /// Whether a stored path is on the deny-list, by its full path or by its
    /// key at any depth.
    static func isStoredPathDenied(_ path: String, key: String) -> Bool {
        storedRecordDenyList.contains(path) || storedRecordDenyList.contains("*.\(key)")
    }

    /// The archive's own encoding (the session's `Codable` conformance), with
    /// dates in the user's time zone (the form every other date the
    /// assistant reads takes, `FactValue.localISO8601`) and a non-finite number written as text
    /// rather than failing the whole record.
    static func storedSessionJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, dateEncoder in
            var container = dateEncoder.singleValueContainer()
            try container.encode(FactValue.localISO8601(date))
        }
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return encoder
    }

    /// One JSON value as a fact value; nil for a JSON null, which is left out.
    private static func storedValue(_ object: Any, path: String) -> FactValue? {
        if let dictionary = object as? [String: Any] { return .record(storedFields(dictionary, path: path)) }
        if let array = object as? [Any] { return .list(array.compactMap { storedValue($0, path: path) }) }
        if let text = object as? String { return .string(text) }
        if let number = object as? NSNumber { return storedNumber(number) }
        return nil
    }

    /// An object's fields, each under its stored key, deny-listed paths out.
    private static func storedFields(_ dictionary: [String: Any], path: String) -> [String: FactValue] {
        var fields: [String: FactValue] = [:]
        for (key, child) in dictionary {
            let childPath = path.isEmpty ? key : "\(path).\(key)"
            guard !isStoredPathDenied(childPath, key: key) else { continue }
            fields[key] = storedValue(child, path: childPath)
        }
        return fields
    }

    /// JSON numbers keep their kind: a boolean, a whole number, or a decimal.
    private static func storedNumber(_ number: NSNumber) -> FactValue {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
        if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
        return .integer(number.intValue)
    }
}
