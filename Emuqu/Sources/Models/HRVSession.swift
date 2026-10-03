import Foundation
import SwiftUI

// MARK: - Lightweight Decoding Support

extension CodingUserInfoKey {
    /// When set to `true` in a JSONDecoder's `userInfo`, HRVSession skips
    /// decoding the heavyweight `rrSeries` field (sets it to nil). This cuts
    /// per-session deserialization from ~450 KB to ~10 KB for dashboard use.
    static let skipRRSeries = decodeFlag("skipRRSeries")

    /// `CodingUserInfoKey.init(rawValue:)` is failable only for an empty raw
    /// value, and every caller here passes a non-empty literal. Trapping with a
    /// named reason beats a bare `!`: if the precondition ever fires, the crash
    /// report says which literal was rejected instead of pointing at a `nil`.
    private static func decodeFlag(_ raw: String) -> CodingUserInfoKey {
        guard let key = CodingUserInfoKey(rawValue: raw) else {
            preconditionFailure("CodingUserInfoKey rejected raw value: \(raw)")
        }
        return key
    }
}

// MARK: - Reading Tags

/// Tag for categorizing HRV readings
struct ReadingTag: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let colorHex: String
    let isSystem: Bool

    init(id: UUID = UUID(), name: String, colorHex: String, isSystem: Bool = false) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.isSystem = isSystem
    }

    var color: Color {
        Color(hex: colorHex) ?? .gray
    }

    /// The name to show. A system tag's stored `name` is its English storage
    /// key; on screen it reads in the app's language. A user tag shows the
    /// name the user typed.
    var displayName: String {
        guard isSystem, let suffix = Self.systemSuffix(of: id) else { return name }
        return Self.localizedSystemName(suffix: suffix) ?? name
    }

    private static func systemSuffix(of id: UUID) -> String? {
        let text = id.uuidString
        guard text.hasPrefix("00000000-0000-0000-0000-00000000000"), let last = text.last else { return nil }
        return String(last)
    }

    private static func localizedSystemName(suffix: String) -> String? {
        let b = LanguageManager.appBundle
        return switch suffix {
        case "1": String(localized: "Morning", bundle: b, comment: "Reading tag")
        case "2": String(localized: "Post-Exercise", bundle: b, comment: "Reading tag")
        case "3": String(localized: "Recovery", bundle: b)
        case "4": String(localized: "Evening", bundle: b, comment: "Reading tag")
        case "5": String(localized: "Pre-Sleep", bundle: b, comment: "Reading tag")
        case "6": String(localized: "Stressed", bundle: b)
        case "7": String(localized: "Relaxed", bundle: b, comment: "Reading tag")
        case "8": String(localized: "Alcohol", bundle: b, comment: "Reading tag")
        case "9": String(localized: "Poor Sleep", bundle: b, comment: "Reading tag")
        case "A": String(localized: "Travel", bundle: b, comment: "Reading tag")
        case "B": String(localized: "Late Meal", bundle: b, comment: "Reading tag")
        case "C": String(localized: "Caffeine", bundle: b, comment: "Reading tag")
        case "D": String(localized: "Illness", bundle: b, comment: "Reading tag")
        case "E": String(localized: "Menstrual", bundle: b, comment: "Reading tag")
        default: nil
        }
    }

    // MARK: - System Preset Tags

    /// Data-driven system tag definitions: (uuid suffix, name, color hex).
    /// Adding a new system tag only requires appending one row here.
    private static let systemTagDefinitions: [(suffix: String, name: String, colorHex: String)] = [
        ("1", "Morning", "#4A90D9"),
        ("2", "Post-Exercise", "#E85D4C"),
        ("3", "Recovery", "#50C878"),
        ("4", "Evening", "#9B59B6"),
        ("5", "Pre-Sleep", "#34495E"),
        ("6", "Stressed", "#E74C3C"),
        ("7", "Relaxed", "#1ABC9C"),
        ("8", "Alcohol", "#C0392B"),
        ("9", "Poor Sleep", "#7F8C8D"),
        ("A", "Travel", "#3498DB"),
        ("B", "Late Meal", "#E67E22"),
        ("C", "Caffeine", "#784212"),
        ("D", "Illness", "#27AE60"),
        ("E", "Menstrual", "#E91E63")
    ]

    private static func systemTag(suffix: String, name: String, colorHex: String) -> ReadingTag {
        let uuidString = "00000000-0000-0000-0000-00000000000\(suffix)"
        guard let uuid = UUID(uuidString: uuidString) else {
            assertionFailure("Invalid system UUID suffix: \(suffix)")
            return ReadingTag(name: name, colorHex: colorHex, isSystem: true)
        }
        return ReadingTag(id: uuid, name: name, colorHex: colorHex, isSystem: true)
    }

    /// The system tag with this suffix, built from `systemTagDefinitions` so
    /// the table is the one place a tag's name and colour live.
    private static func definedTag(_ suffix: String) -> ReadingTag {
        guard let def = systemTagDefinitions.first(where: { $0.suffix == suffix }) else {
            preconditionFailure("No system tag definition for suffix \(suffix)")
        }
        return systemTag(suffix: def.suffix, name: def.name, colorHex: def.colorHex)
    }

    static let morning = definedTag("1")
    static let postExercise = definedTag("2")
    static let recovery = definedTag("3")
    static let evening = definedTag("4")
    static let preSleep = definedTag("5")
    static let stressed = definedTag("6")
    static let relaxed = definedTag("7")
    static let alcohol = definedTag("8")
    static let poorSleep = definedTag("9")
    static let travel = definedTag("A")
    static let lateMeal = definedTag("B")
    static let caffeine = definedTag("C")
    static let illness = definedTag("D")
    static let menstrual = definedTag("E")

    static var systemTags: [ReadingTag] {
        systemTagDefinitions.map { systemTag(suffix: $0.suffix, name: $0.name, colorHex: $0.colorHex) }
    }
}

// MARK: - Color Extension for Hex

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }

    var hexString: String {
        let uiColor = UIColor(self)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0

        // getRed handles both RGB and grayscale color spaces correctly
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        }

        // Fallback for colors that don't support getRed (rare)
        return "#000000"
    }
}
