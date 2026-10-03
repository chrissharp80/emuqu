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
        writer.discard()
    }

    private let storeURL: URL

    /// Serial, newest-wins writer: saves land in the order they were made, so
    /// a delete followed by an add cannot bring the deleted contact back.
    /// Contact emails are PII, so the file gets an explicit protection class,
    /// matching the archive and backup writers.
    private let writer: LatestWinsFileWriter<[EmailContact]>

    /// `storeURL` is injectable so a test can use its own file. Without it,
    /// every `EmailContactStore()` shares one on-disk book: contacts written by
    /// one test persist into the next run, and a name that resolved cleanly the
    /// first time reads as ambiguous the second.
    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let fm = FileManager.default
            let support = attempt("emailContacts.supportDir") { try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) }
                ?? fm.temporaryDirectory
            self.storeURL = support.appendingPathComponent("email_contacts.json")
        }
        self.writer = LatestWinsFileWriter(
            url: self.storeURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication],
            label: "emailContacts"
        )
        load()
    }

    func add(_ contact: EmailContact) {
        contacts.append(contact)
        save()
    }

    func update(id: UUID, name: String? = nil, email: String? = nil, notes: String? = nil) {
        guard let idx = contacts.firstIndex(where: { $0.id == id }) else { return }
        if let name { contacts[idx].name = name }
        if let email { contacts[idx].email = email }
        // notes: explicit nil-vs-omitted distinction not needed — the
        // store overwrites only if a value is supplied.
        if let notes { contacts[idx].notes = notes.isEmpty ? nil : notes }
        save()
    }

    func remove(id: UUID) {
        contacts.removeAll { $0.id == id }
        save()
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
        if name.contains("@"), name.contains(".") { return .resolved(name) }
        let matches = find(name: name)
        if matches.isEmpty { return .unknown }
        guard matches.count == 1 else { return .ambiguous }
        return .resolved(matches[0].email)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            contacts = try JSONDecoder().decode([EmailContact].self, from: data)
        } catch {
            // The file exists, so these are saved recipients the user entered.
            // Losing them silently means their next report goes nowhere and
            // they have no idea why.
            debugLog("[EmailContact] store present but failed to decode, keeping none: \(error)", level: .error)
        }
    }

    private func save() {
        writer.enqueue(contacts)
    }
}
