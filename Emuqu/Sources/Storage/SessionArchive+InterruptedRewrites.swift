import Foundation

// The boot-time half of the interrupted-rewrite markers that
// `ArchiveStore+InterruptedRewrites.swift` leaves and clears.

extension SessionArchive {
    /// At boot: re-hash each session a marker says was being rewritten when
    /// the app stopped. A marker stays when the file cannot be read yet
    /// (locked device) so the next launch tries again; it goes once the file
    /// is re-hashed, found to match, or found not to decode (that is real
    /// damage, and reads keep reporting it).
    func healInterruptedRewrites() {
        // With no index loaded every session reads as unarchived: the
        // markers wait for a launch that has one.
        guard !state.indexReadFailed, !state.indexDecodeFailed else { return }
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: archiveDirectory.path)
        } catch {
            debugLog("[Archive] Could not list the archive for interrupted rewrites: \(error)", level: .warning)
            return
        }
        for name in names where name.hasSuffix(".rewriting") {
            guard let id = UUID(uuidString: String(name.dropLast(".rewriting".count))) else { continue }
            let result = repairSessionHashIfDecodable(sessionId: id)
            debugLog("[Archive] Interrupted rewrite of \(id.uuidString.prefix(8)): \(result)", level: .warning)
            if result != .notNow || !store.exists(id) { store.markRewriteSettled(id) }
        }
    }
}
