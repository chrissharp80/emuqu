import Foundation

/// Decoding that survives a schema change.
///
/// Several types in this app are the forward/backward compatibility surface for
/// data a user already has on disk: settings, thresholds, backups. Their
/// decoders are deliberately tolerant — an absent key takes a documented
/// default rather than failing the whole payload and losing everything else
/// alongside it.
///
/// The spelling that tolerance was written in, `(try? c.decode(T.self, forKey:
/// k)) ?? d`, swallows two different failures with the same silence: a key that
/// is ABSENT, which is the expected case and needs no comment, and a key whose
/// value is the wrong TYPE, which means the stored data is corrupt and is the
/// one worth knowing about. This keeps the tolerance exactly and adds the
/// trace, so a setting that resets itself leaves a reason behind.
extension KeyedDecodingContainer {
    /// The decoded value, or `fallback` when the key is absent or unreadable.
    func value<T: Decodable>(_ type: T.Type, _ key: Key, or fallback: T) -> T {
        optionalValue(type, key) ?? fallback
    }

    /// The decoded value, or nil — for fields whose absence is itself the
    /// value rather than a missing setting.
    func optionalValue<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        do {
            return try decodeIfPresent(type, forKey: key)
        } catch {
            debugLog(
                "[Decoding] \(key.stringValue) present but unreadable — using the default: \(error)",
                level: .warning
            )
            return nil
        }
    }
}
