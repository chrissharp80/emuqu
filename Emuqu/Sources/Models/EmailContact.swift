import Foundation

// MARK: - EmailContact + EmailContactStore
//
// Tiny address book for the AI's email-compose action. The user
// adds contacts in Settings (or by asking the AI directly) — name +
// email. The AI then resolves names ("chris", "coach") in the `to` /
// `cc` arguments of `assistant.email.compose` against this store, so
// the user can say "email my workout summary to chris and charlie"
// without spelling the addresses every time.
//
// Distinct from the user's default-recipient settings (which pre-fill
// the composer with one fixed To + Cc). Contacts are for AD-HOC
// addressing — different person each time, addressed by name.
//
// Single JSON file in Application Support. Same pattern + lifecycle
// as `SavedRouteStore`.
struct EmailContact: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    /// Free-text name the user knows the contact by ("Chris", "Coach
    /// John", "Doctor Lee"). Case-insensitive when matched. Need not
    /// be unique — multiple "Chris" entries are allowed; the resolver
    /// surfaces an `invalidParameter` error asking the user to
    /// disambiguate when there are duplicates.
    var name: String
    var email: String
    /// Optional notes ("training partner", "PCP"). Surfaced in the
    /// settings list and in the AI's contacts.list fact for context.
    var notes: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        email: String,
        notes: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.notes = notes
        self.createdAt = createdAt
    }
}

@Observable

@MainActor
final class EmailContactStore {
    static let shared = EmailContactStore()

    private(set) var contacts: [EmailContact] = []

    /// Delete All My Data: drops the in-memory copy so nothing reads it
    /// afterwards, and discards any pending write (removing the file again if
    /// one landed after the purge deleted it).
    func forgetAfterPurge() {
        contacts = []
        loadFailed = false
        writer.discard()
    }

    private let storeURL: URL

    /// Set when the contacts file exists but could not be read (file
    /// protection before first unlock). Saves are blocked while it is set,
    /// so an edit never overwrites the user's saved contacts with the empty
    /// list this store fell back to — the same guard as `SavedRouteStore`.
    /// A file that reads but does not decode is set aside instead
    /// (`undecodableBackupName`) and does not block saves.
    private var loadFailed = false

    /// Where `load()` sets aside a contacts file it read but could not decode.
    private static let undecodableBackupName = "email_contacts.undecodable.json"

    /// Serial, newest-wins writer: saves land in the order they were made, so
    /// a delete followed by an add cannot bring the deleted contact back.
    /// Contact emails are PII, so the file gets an explicit protection class,
    /// matching the archive and backup writers.
    private let writer: LatestWinsFileWriter<[EmailContact]>

    /// `storeURL` is injectable so a test can use its own file. Without it,
    /// every `EmailContactStore()` shares one on-disk book: contacts written by
    /// one test persist into the next run, and a name that resolved cleanly the
    /// first time reads as ambiguous the second.
    ///
    /// When Application Support cannot be resolved the book goes in the App
    /// Group container instead, which persists like it; the temporary
    /// directory would lose the contacts whenever iOS purges it.
    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let fm = FileManager.default
            let support = attempt("emailContacts.supportDir") { try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) }
                ?? AppConfig.sharedContainerURL()
            self.storeURL = support.appendingPathComponent("email_contacts.json")
        }
        self.writer = LatestWinsFileWriter(
            url: self.storeURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication],
            label: "emailContacts"
        )
        load()
    }

    /// False, adding nothing, while the contacts file still cannot be read
    /// after a retry (before first unlock): the change could not be saved,
    /// so memory is kept matching disk.
    @discardableResult
    func add(_ contact: EmailContact) -> Bool {
        retryLoadIfBlocked()
        guard !loadFailed else { return false }
        contacts.append(contact)
        save()
        return true
    }

    /// False, removing nothing, while the contacts file still cannot be read
    /// after a retry; see `add`.
    @discardableResult
    func remove(id: UUID) -> Bool {
        retryLoadIfBlocked()
        guard !loadFailed else { return false }
        contacts.removeAll { $0.id == id }
        save()
        return true
    }

    /// Find contacts by case-insensitive name match. Returns ALL matches
    /// — multiple-match handling is the caller's job (the AI resolver
    /// surfaces an `invalidParameter` to ask the user which "Chris" they
    /// meant).
    func find(name: String) -> [EmailContact] {
        let target = name.trimmingCharacters(in: .whitespaces)
        return contacts.filter { $0.name.caseInsensitiveCompare(target) == .orderedSame }
    }

    /// Resolve a comma-separated list of names → unique email addresses.
    /// Returns:
    ///   • `resolved`: the addresses found (may include duplicates if
    ///     the user typed the same name twice — caller dedupes if it
    ///     cares)
    ///   • `unknown`: names that didn't match anything in the book
    ///   • `ambiguous`: names that matched MORE than one contact —
    ///     caller surfaces these to the user for disambiguation
    func resolveNames(_ csvNames: String) -> (resolved: [String], unknown: [String], ambiguous: [String]) {
        let names = csvNames
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var resolved: [String] = []
        var unknown: [String] = []
        var ambiguous: [String] = []
        for name in names {
            switch classify(name) {
            case let .resolved(email): resolved.append(email)
            case .unknown: unknown.append(name)
            case .ambiguous: ambiguous.append(name)
            }
        }
        return (resolved, unknown, ambiguous)
    }

    /// What one name in the CSV list resolved to.
    private enum NameResolution {
        case resolved(String)
        case unknown
        case ambiguous
    }

    /// Pre-check: if it already looks like an email address, pass through —
    /// AI may mix names and explicit addresses.
    private func classify(_ name: String) -> NameResolution {
        if Self.looksLikeEmailAddress(name) { return .resolved(name) }
        let matches = find(name: name)
        if matches.isEmpty { return .unknown }
        guard matches.count == 1 else { return .ambiguous }
        return .resolved(matches[0].email)
    }

    /// One address, not a name: a single "@" with something before it, a
    /// domain after it with a dot that is neither first nor last, and no
    /// whitespace. "j.smith@" or "chris.p" are names to look up.
    static func looksLikeEmailAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !text.contains(where: \.isWhitespace) else { return false }
        let domain = parts[1]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: storeURL)
        } catch {
            // The file exists, so these are saved recipients the user entered.
            // Keep the file untouched rather than overwrite it on the next edit.
            loadFailed = true
            debugLog("[EmailContact] store present but unreadable, blocking saves: \(error)", level: .error)
            return
        }
        do {
            contacts = try JSONDecoder().decode([EmailContact].self, from: data)
            loadFailed = false
        } catch {
            loadFailed = !Self.setAsideUndecodable(storeURL, reason: error)
        }
    }

    /// Copies a contacts file that read but did not decode to
    /// `undecodableBackupName` beside it, replacing an older copy, so the
    /// book can start empty without destroying it. True when the copy is in
    /// place; otherwise saves stay blocked.
    private static func setAsideUndecodable(_ url: URL, reason: Error) -> Bool {
        let backup = url.deletingLastPathComponent().appendingPathComponent(undecodableBackupName)
        let copied = attempt("emailContacts.setAside") { () throws -> Void in
            if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
            try FileManager.default.copyItem(at: url, to: backup)
        } != nil
        debugLog("[EmailContact] store failed to decode (\(reason)) — \(copied ? "set aside; starting an empty book" : "could not set it aside; blocking saves")", level: .error)
        return copied
    }

    /// A file that was unreadable at launch (file protection before first
    /// unlock) is read again before the next edit, so the edit applies to
    /// the real list. Contacts added while it was unreadable are kept: they
    /// exist only in memory, and the reload would otherwise drop them.
    private func retryLoadIfBlocked() {
        guard loadFailed else { return }
        let addedWhileBlocked = contacts
        load()
        guard !loadFailed else { return }
        let known = Set(contacts.map(\.id))
        contacts.append(contentsOf: addedWhileBlocked.filter { !known.contains($0.id) })
    }

    private func save() {
        guard !loadFailed else {
            debugLog("[EmailContact] skipping save — the contacts file could not be read; refusing to overwrite it", level: .error)
            return
        }
        writer.enqueue(contacts)
    }
}
