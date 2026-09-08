import Foundation

/// Optional context tag for a morning feeling rating of 1 or 2 (Terrible/Poor).
///
/// Split into Body and Mind clusters following Kellmann's RESTQ-Sport
/// construct separation (Physical Complaints vs. Emotional Stress as
/// distinct subscales). Each tag routes the morning narrative to a
/// specific recommendation, so adding a tag only makes sense if the app
/// can act on it differently.
///
/// Nine tags total — the point where further splitting becomes noise in
/// a consumer app (DASS/RESTQ instruments require multi-item scales for
/// finer distinctions, which don't survive single-tag reporting).
enum MorningFeelingTag: String, Codable, CaseIterable {
    // Body (somatic)
    case infection // flu / cold / fever — training-stop signal
    case allergies // histamine response — train but expect less
    case hangover // alcohol aftermath — easy day
    case stomach // GI upset — rest
    case sore // DOMS — train another group
    case tired // general fatigue — easy day
    case headache // neurogenic — context-dependent

    // Mind (emotional)
    case stressed // psychogenic stress / anxiety
    case down // low mood / flat / sad

    enum Cluster: String, Codable {
        case body
        case mind
    }

    var cluster: Cluster {
        switch self {
        case .infection, .allergies, .hangover, .stomach, .sore, .tired, .headache:
            .body
        case .stressed, .down:
            .mind
        }
    }

    var emoji: String {
        switch self {
        case .infection: "\u{1F912}" // face with thermometer
        case .allergies: "\u{1F927}" // sneezing
        case .hangover: "\u{1F377}" // wine glass
        case .stomach: "\u{1F922}" // nauseated
        case .sore: "\u{1F4AA}" // flexed bicep
        case .tired: "\u{1F971}" // yawning
        case .headache: "\u{1F915}" // face with head bandage
        case .stressed: "\u{1F630}" // anxious face
        case .down: "\u{1F614}" // pensive
        }
    }

    var label: String {
        switch self {
        case .infection: "Infection"
        case .allergies: "Allergies"
        case .hangover: "Hangover"
        case .stomach: "Stomach"
        case .sore: "Sore"
        case .tired: "Tired"
        case .headache: "Headache"
        case .stressed: "Stressed"
        case .down: "Down"
        }
    }

    /// Additional context shown under the label for tags where the scope
    /// isn't obvious (e.g. "Infection" includes cold/flu/fever).
    var hint: String? {
        switch self {
        case .infection: "cold, flu, fever"
        case .headache: "or migraine"
        default: nil
        }
    }

    // MARK: - Codable with forward-compatible decode

    /// Decoding a SINGLE tag throws `DecodingError` on an unknown raw value.
    /// The forward-compat "silently drop unknown tags" behavior lives in the
    /// `MorningFeelingTagArray` wrapper below (which decodes each element
    /// leniently and skips any it can't map) — NOT here. Decode arrays
    /// through that wrapper, not the synthesized `[MorningFeelingTag]`
    /// decoder, when tolerance is required.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = MorningFeelingTag(rawValue: raw) else {
            throw try DecodingError.dataCorruptedError(
                in: decoder.singleValueContainer(),
                debugDescription: "Unknown MorningFeelingTag: \(raw)"
            )
        }
        self = value
    }
}

/// Convenience: decode `[MorningFeelingTag]` tolerating unknown entries.
/// Swift's default array decode fails the whole array on any single
/// unknown element — not what we want for a forward-compat tag list.
struct MorningFeelingTagArray: Codable {
    let tags: [MorningFeelingTag]

    init(_ tags: [MorningFeelingTag]) {
        self.tags = tags
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        tags = Self.decodeTags(from: &container)
    }

    /// CRITICAL: every loop iteration MUST advance the container, otherwise a
    /// malformed archive entry (non-string in the tags array) hangs the archive
    /// load in an infinite loop — triggering watchdog termination.
    ///
    /// Grabbing `superDecoder()` always increments the container index by one
    /// regardless of what's at that position. We then try to decode from it as
    /// a string; if that fails we just drop the entry.
    private static func decodeTags(from container: inout UnkeyedDecodingContainer) -> [MorningFeelingTag] {
        var result: [MorningFeelingTag] = []
        while !container.isAtEnd {
            let indexBefore = container.currentIndex
            guard let sub = try? container.superDecoder() else {
                // superDecoder shouldn't fail mid-array, but if it does we
                // can't proceed — bail to avoid infinite loop.
                break
            }
            if let raw = try? sub.singleValueContainer().decode(String.self),
               let tag = MorningFeelingTag(rawValue: raw) {
                result.append(tag)
            }
            // Defense-in-depth: if container didn't advance for any reason,
            // stop rather than loop forever.
            if container.currentIndex == indexBefore { break }
        }
        return result
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for tag in tags {
            try container.encode(tag.rawValue)
        }
    }
}
