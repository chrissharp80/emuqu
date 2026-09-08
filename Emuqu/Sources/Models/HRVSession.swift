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

    // Individual accessors preserved for existing call sites
    static let morning = systemTag(suffix: "1", name: "Morning", colorHex: "#4A90D9")
    static let postExercise = systemTag(suffix: "2", name: "Post-Exercise", colorHex: "#E85D4C")
    static let recovery = systemTag(suffix: "3", name: "Recovery", colorHex: "#50C878")
    static let evening = systemTag(suffix: "4", name: "Evening", colorHex: "#9B59B6")
    static let preSleep = systemTag(suffix: "5", name: "Pre-Sleep", colorHex: "#34495E")
    static let stressed = systemTag(suffix: "6", name: "Stressed", colorHex: "#E74C3C")
    static let relaxed = systemTag(suffix: "7", name: "Relaxed", colorHex: "#1ABC9C")
    static let alcohol = systemTag(suffix: "8", name: "Alcohol", colorHex: "#C0392B")
    static let poorSleep = systemTag(suffix: "9", name: "Poor Sleep", colorHex: "#7F8C8D")
    static let travel = systemTag(suffix: "A", name: "Travel", colorHex: "#3498DB")
    static let lateMeal = systemTag(suffix: "B", name: "Late Meal", colorHex: "#E67E22")
    static let caffeine = systemTag(suffix: "C", name: "Caffeine", colorHex: "#784212")
    static let illness = systemTag(suffix: "D", name: "Illness", colorHex: "#27AE60")
    static let menstrual = systemTag(suffix: "E", name: "Menstrual", colorHex: "#E91E63")

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
