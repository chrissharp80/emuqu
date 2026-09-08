import Foundation

// MARK: - JSON Parsing

extension RRDataImporter {
    // MARK: - JSON Parsing

    func parseJSON(_ content: String) throws -> ([Int], [String: String], Date?) {
        guard let data = content.data(using: .utf8) else {
            throw ImportError.unreadableFile
        }
        // Try parsing as array of numbers first
        if let array = try? JSONDecoder().decode([Double].self, from: data) {
            return (array.map { convertToMilliseconds($0) }, [:], nil)
        }
        // Try parsing as structured HRV export
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return try parseStructuredJSON(dict)
        }
        // Try parsing as array of dicts with RR field
        if let arrayOfDicts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let rrValues = arrayOfDicts.compactMap { rrMilliseconds(in: $0) }
            if !rrValues.isEmpty {
                return (rrValues, [:], nil)
            }
        }
        throw ImportError.invalidFormat("Unable to parse JSON as RR data")
    }

    /// The RR interval one sample dictionary carries, under whichever of the
    /// field spellings exporters use. Nil when the sample names none of them.
    private func rrMilliseconds(in item: [String: Any]) -> Int? {
        if let rr = item["rr"] as? Double { return convertToMilliseconds(rr) }
        if let rr = item["RR"] as? Double { return convertToMilliseconds(rr) }
        if let rr = item["rr_ms"] as? Int { return rr }
        if let rr = item["rrInterval"] as? Double { return convertToMilliseconds(rr) }
        return nil
    }

    func parseStructuredJSON(_ dict: [String: Any]) throws -> ([Int], [String: String], Date?) {
        let rrValues = structuredRRValues(dict)
        guard !rrValues.isEmpty else {
            throw ImportError.noRRData
        }
        var metadata: [String: String] = [:]
        if let device = dict["device"] as? String {
            metadata["device"] = device
        }
        if let notes = dict["notes"] as? String {
            metadata["notes"] = notes
        }
        var recordingDate: Date?
        if let date = dict["date"] as? String ?? dict["timestamp"] as? String ?? dict["recordingDate"] as? String {
            recordingDate = parseDate(date)
        }
        return (rrValues, metadata, recordingDate)
    }

    /// RR intervals under whichever of the common top-level keys the export
    /// used. First key that holds a numeric array wins.
    private func structuredRRValues(_ dict: [String: Any]) -> [Int] {
        let rrKeys = ["rr", "RR", "rr_intervals", "rrIntervals", "RRIntervals", "ibi", "IBI", "nn", "NN"]
        for key in rrKeys {
            if let values = numericArray(dict[key]) { return values }
        }
        return []
    }

    /// A Double array is converted (some exports write seconds); an Int array is
    /// already milliseconds.
    private func numericArray(_ value: Any?) -> [Int]? {
        if let values = value as? [Double] { return values.map { convertToMilliseconds($0) } }
        return value as? [Int]
    }
}
