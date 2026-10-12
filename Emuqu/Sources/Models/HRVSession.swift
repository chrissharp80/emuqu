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
        systemTagDefinitions.first { $0.suffix == suffix }?.localizedName()
    }

    // MARK: - System Preset Tags

    /// Data-driven system tag definitions: (uuid suffix, English storage
    /// name, color hex, the name in the app's language). Adding a new system
    /// tag only requires appending one row here, and the row cannot be
    /// written without its localized name.
    private static let systemTagDefinitions: [(suffix: String, name: String, colorHex: String, localizedName: @Sendable () -> String)] = [
        ("1", "Morning", "#4A90D9", { String(localized: "Morning", bundle: LanguageManager.appBundle, comment: "Reading tag") }),
        ("2", "Post-Exercise", "#E85D4C", { String(localized: "Post-Exercise", bundle: LanguageManager.appBundle, comment: "Reading tag") }),
        ("3", "Recovery", "#50C878", { String(localized: "Recovery", bundle: LanguageManager.appBundle) }),
        ("4", "Evening", "#9B59B6", { String(localized: "Evening", bundle: LanguageManager.appBundle, comment: "Reading tag") }),
        ("5", "Pre-Sleep", "#34495E", { String(localized: "Pre-Sleep", bundle: LanguageManager.appBundle, comment: "Reading tag") }),
        ("6", "Stressed", "#E74C3C", { String(localized: "Stressed", bundle: LanguageManager.appBundle) }),
        ("7", "Relaxed", "#1ABC9C", { String(localized: "Relaxed", bundle: LanguageManager.appBundle, comment: "Reading tag") }),
        ("8", "Alcohol", "#C0392B", { String(localized: "Alcohol", bundle: LanguageManager.appBundle, comment: "Reading tag") }),
        ("9", "Poor Sleep", "#7F8C8D", { String(localized: "Poor Sleep", bundle: LanguageManager.appBundle, comment: "Reading tag") }),
        ("A", "Travel", "#3498DB", { String(localized: "Travel", bundle: LanguageManager.appBundle, comment: "Reading tag") }),
        ("B", "Late Meal", "#E67E22", { String(localized: "Late Meal", bundle: LanguageManager.appBundle, comment: "Reading tag") }),
        ("C", "Caffeine", "#784212", { String(localized: "Caffeine", bundle: LanguageManager.appBundle, comment: "Reading tag") }),
        ("D", "Illness", "#27AE60", { String(localized: "Illness", bundle: LanguageManager.appBundle, comment: "Reading tag") }),
        ("E", "Menstrual", "#E91E63", { String(localized: "Menstrual", bundle: LanguageManager.appBundle, comment: "Reading tag") })
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
    /// `#RRGGBB` or the `#RGB` shorthand (the "#" optional). Anything else —
    /// another length, or a character that is not a hex digit — is nil
    /// rather than a guess.
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        if hexSanitized.count == 3 { hexSanitized = hexSanitized.map { "\($0)\($0)" }.joined() }

        var rgb: UInt64 = 0
        guard hexSanitized.count == 6, hexSanitized.allSatisfy(\.isHexDigit),
              Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

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

        // getRed handles both RGB and grayscale color spaces correctly.
        // Components are rounded, and clamped to 0…1 because an
        // extended-sRGB colour from ColorPicker can fall outside it.
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            let byte = { (c: CGFloat) in Int((min(max(c, 0), 1) * 255).rounded()) }
            return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
        }

        // Fallback for colors that don't support getRed (rare)
        return "#000000"
    }
}
