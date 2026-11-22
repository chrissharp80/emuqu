import Foundation

// MARK: - Export files

/// Where the files the app hands to the share sheet or a mail attachment are
/// written, and how.
///
/// They hold health data in the clear: a report PDF, a workout's GPS track and
/// per-second heart rate, a scrubbed log. Each is written with `.complete`
/// file protection, so it cannot be read while the phone is locked; only the
/// share sheet or composer the user has open reads it.
///
/// They all go in one temporary folder, `Exports`, never in Documents (an
/// iCloud-eligible container the share sheet probes for a CloudKit share
/// mode before it will open a file there). A share sheet presented from
/// SwiftUI's `ShareLink` gives the app no completion callback, so its file
/// cannot be deleted at the moment the sheet closes. Instead each export
/// replaces its own earlier copies when it is written again, and the whole
/// folder is emptied at the next launch (`removeLeftovers`), when no share
/// sheet from the previous run can still be reading it.
enum ExportFile {
    /// `tmp/Exports`.
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    /// Writes `data` as `name` in `directory`, atomically and with complete
    /// protection, and returns its URL. Files in the folder whose names start
    /// with `replacingPrefix` (earlier copies of the same export under a
    /// different timestamp) are removed first. Throws when the folder cannot
    /// be created or the file cannot be written.
    static func write(_ data: Data, named name: String, replacingPrefix prefix: String? = nil) throws -> URL {
        let folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let prefix { removeFiles(in: folder) { $0.hasPrefix(prefix) } }
        let url = folder.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Raises a file another writer produced (a PDF renderer writes its own
    /// file) to complete protection. A failure is logged and the file kept:
    /// the export still reaches the user, with the default protection class.
    static func protect(_ url: URL) {
        attempt("export.protect") {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        }
    }

    /// Empties `directory`. Called once at launch.
    static func removeLeftovers() {
        removeFiles(in: directory) { _ in true }
    }

    /// Removes the files in `folder` whose names pass `matches`; a failure is
    /// logged and the rest are still removed. A missing folder holds nothing.
    private static func removeFiles(in folder: URL, where matches: (String) -> Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path),
              let names = attempt("export.list", { try fm.contentsOfDirectory(atPath: folder.path) })
        else { return }
        for name in names where matches(name) {
            attempt("export.remove") { try fm.removeItem(at: folder.appendingPathComponent(name)) }
        }
    }
}
