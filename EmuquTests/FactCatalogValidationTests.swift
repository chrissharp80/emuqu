@testable import Emuqu
import XCTest

/// Catalog validation suite (docs/FLO_ARCHITECTURE.md §6).
///
/// These tests lock the structural invariants of the FactCatalog. They run
/// in CI against a real registry built from `AppFactResolverFactory.build`
/// and guard against the common ways a catalog can rot between releases:
///
///   1. Duplicate tool names (multiple entries mapping to the same
///      schema-emitted name — the model sees one and we pick an unknown
///      one at call time).
///   2. Malformed parameter patterns (pattern says `$date` but no `$`
///      placeholder was actually provided).
///   3. Composites listing non-existent dependencies.
///   4. Composites depending on other composites (the flat-leaf
///      invariant `sourceFacts` relies on).
///   5. `availability()` closures that take longer than 1 ms — signal
///      they might be doing disk I/O, which violates the availability
///      purity rule
///   6. Deterministic schema serialisation — same catalog, same bytes.
///      Cache stability depends on this.
final class FactCatalogValidationTests: XCTestCase {
    // Build a registry once per test against an in-memory archive. Tests
    // only touch schema shape, so the archive can be the shared singleton
    // — no mutation happens here.
    private func makeRegistry() -> FactResolverRegistry {
        AppFactResolverFactory.build(
            archive: .shared,
            settings: { SettingsManager.shared.settingsSnapshot }
        )
    }

    // MARK: 1. No duplicate tool names

    func testNoDuplicateToolNames() {
        let specs = makeRegistry().toolSchema()
        let names = specs.map(\.name)
        let duplicates = Dictionary(grouping: names, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys
        XCTAssertTrue(
            duplicates.isEmpty,
            "Duplicate tool names in catalog: \(Array(duplicates)). Two FactEntry entries generate the same schema name."
        )
    }

    // MARK: 2. Parameterised entries must have a real placeholder

    func testParameterizedEntriesHaveValidPlaceholders() {
        for ns in makeRegistry().namespaces {
            for entry in ns.entries {
                switch entry {
                case .parameterized(let pattern, _, let description, _, _):
                    XCTAssertTrue(
                        pattern.contains("(") && pattern.contains(")"),
                        "Parameterised pattern '\(pattern)' is missing parens — would not match anything"
                    )
                    XCTAssertTrue(
                        pattern.contains("$"),
                        "Parameterised pattern '\(pattern)' has no $placeholder — description=\(description)"
                    )
                default:
                    break
                }
            }
        }
    }

    // MARK: 3 & 4. Composite dependencies exist; composites call atomics only

    func testCompositeDependenciesResolveToRealAtomics() {
        let registry = makeRegistry()
        // Collect every atomic key pattern in the catalog (literal or
        // with-placeholder). Composites may reference patterns with a
        // concrete period baked in (e.g., "walks.count(last_7d)") that
        // resolve at runtime — for the existence check we strip the
        // parens to get the bare namespace key.
        var atomicKeyRoots = Set<String>()
        var compositeKeyRoots = Set<String>()
        for ns in registry.namespaces {
            for entry in ns.entries {
                switch entry {
                case .fixed(let key, _, _, _, _):
                    atomicKeyRoots.insert(keyRoot(key))
                case .parameterized(let pattern, _, _, _, _):
                    atomicKeyRoots.insert(keyRoot(pattern))
                case .composite(let key, _, _, _, _, _):
                    compositeKeyRoots.insert(keyRoot(key))
                case .action:
                    // Actions are mutation tools, not facts — they have
                    // no place in the composite dependency graph.
                    continue
                }
            }
        }

        for ns in registry.namespaces {
            for entry in ns.entries {
                guard case let .composite(key, _, _, deps, _, _) = entry else { continue }
                for dep in deps {
                    let root = keyRoot(dep)
                    XCTAssertTrue(
                        atomicKeyRoots.contains(root),
                        "Composite '\(key)' lists dependency '\(dep)' (root=\(root)) that matches no atomic FactEntry. Every composite dep must resolve to an atomic."
                    )
                    XCTAssertFalse(
                        compositeKeyRoots.contains(root),
                        "Composite '\(key)' depends on '\(dep)' which is ANOTHER composite. Composites must call atomics only (flat-leaf invariant, design §4.2)."
                    )
                }
            }
        }
    }

    /// Strip parens/placeholders to get just the dotted key root.
    /// "walks.count($period)" → "walks.count"
    /// "walks.count(last_7d)" → "walks.count"
    /// "user.profile.max_hr" → "user.profile.max_hr"
    private func keyRoot(_ key: String) -> String {
        if let open = key.firstIndex(of: "(") {
            return String(key[..<open])
        }
        return key
    }

    // MARK: 5. Availability closures are metadata-only (fast)

    func testAvailabilityClosuresAreFast() {
        let registry = makeRegistry()
        for ns in registry.namespaces {
            for entry in ns.entries {
                let label = "\(ns.namespace) / \(entry.display)"
                let start = Date()
                _ = entry.currentAvailability
                let elapsed = Date().timeIntervalSince(start)
                XCTAssertLessThan(
                    elapsed,
                    0.05,
                    "Availability for \(label) took \(elapsed)s — design §2.2 requires metadata-only reads (<50ms). Did a disk read or HealthKit call leak in?"
                )
            }
        }
    }

    // MARK: 6. Deterministic schema serialisation

    func testSchemaSerializationIsDeterministic() {
        // Build two registries independently; their schemas MUST serialise
        // byte-identically. Cache stability depends on this; any
        // Dictionary-ordering drift in the encoding path is a P0 bug.
        let a = makeRegistry()
        let b = makeRegistry()
        let aHash = a.catalogHash()
        let bHash = b.catalogHash()
        XCTAssertEqual(
            aHash,
            bHash,
            "catalogHash() differs between two freshly-built registries. Non-deterministic schema serialisation — will blow the prompt cache every turn."
        )
    }

    // MARK: 7. Tool names are valid per provider constraints

    func testToolNamesAreValidForProviders() throws {
        // Anthropic + OpenAI accept ^[a-zA-Z0-9_-]{1,64}$. Our encoding
        // converts dots to underscores; any other special char means a
        // bad catalog entry.
        // Not `try!`: a malformed pattern here should fail the
        // test with a readable error, not trap the whole test runner.
        let valid = try NSRegularExpression(pattern: "^[a-zA-Z0-9_-]{1,64}$")
        for spec in makeRegistry().toolSchema() {
            let range = NSRange(spec.name.startIndex ..< spec.name.endIndex, in: spec.name)
            let match = valid.firstMatch(in: spec.name, range: range)
            XCTAssertNotNil(
                match,
                "Tool name '\(spec.name)' violates provider name constraints (^[a-zA-Z0-9_-]{1,64}$)"
            )
        }
    }

    // MARK: 8. All tools have non-empty descriptions

    func testAllToolsHaveDescriptions() {
        for spec in makeRegistry().toolSchema() {
            XCTAssertFalse(
                spec.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Tool '\(spec.name)' has empty description. Descriptions drive the model's tool selection — required."
            )
        }
    }

    // MARK: 9. Every catalog key round-trips through registry dispatch

    /// Regression guard for the first-namespace dispatch bug.
    /// Several namespaces legally share a head token (six register as
    /// "app"; "workout" hosts both the historical and the live-coaching
    /// resolvers). The registry must reach entries in EVERY namespace
    /// under a shared head, not just the first registered one — the old
    /// dispatch tried only the first head match and then excluded the
    /// whole head-group from the fallback scan, stranding every entry in
    /// 2nd+ same-head namespaces behind "no such key".
    ///
    /// Catalog-driven: derive a concrete key for each read entry and
    /// assert `resolve()` lands on the entry. Any result OTHER than the
    /// registry's "no such key" envelope counts as a successful round-trip
    /// — `.missing(.notRecorded, "no workout active")` or the awaitable
    /// sync-path guard envelope both prove dispatch FOUND the entry and
    /// ran (or correctly refused) its resolver. The async path is a
    /// documented structural copy of the sync dispatch, so pinning the
    /// sync walk pins both.
    func testEveryCatalogKeyRoundTripsThroughDispatch() {
        let registry = makeRegistry()
        for ns in registry.namespaces {
            for entry in ns.entries {
                let key: String
                switch entry {
                case .fixed(let k, _, _, _, _):
                    key = k
                case .parameterized(let pattern, let example, _, _, _):
                    key = substitutingPlaceholder(in: pattern, with: example)
                case .composite(let k, _, _, _, _, _):
                    // Literal composites resolve as-is. Parameterised
                    // composites don't declare a paramExample, so feed the
                    // placeholder name itself — a resolver treating it as a
                    // bad param still proves dispatch reached the entry.
                    key = k.contains("(")
                        ? substitutingPlaceholder(in: k, with: placeholderName(in: k) ?? "value")
                        : k
                case .action:
                    // Actions dispatch only via resolveTool, never via
                    // free-form key resolution — out of scope here.
                    continue
                }
                let value = registry.resolve(key)
                if case .missing(let reason, let detail) = value,
                   reason == .notRecorded,
                   let detail, detail.hasPrefix("no such key") {
                    XCTFail(
                        "Catalog key '\(key)' (namespace '\(ns.namespace)') does not round-trip through registry dispatch — resolve() returned \"no such key\". Entries in every namespace sharing a head token must be reachable."
                    )
                }
            }
        }
    }

    /// "session.by_date($date)" + "<example>" → "session.by_date(<example>)"
    private func substitutingPlaceholder(in pattern: String, with example: String) -> String {
        guard let open = pattern.firstIndex(of: "("),
              let close = pattern.firstIndex(of: ")"),
              open < close
        else { return pattern }
        return String(pattern[..<pattern.index(after: open)]) + example + String(pattern[close...])
    }

    /// "sleep.week_summary($period)" → "period"
    private func placeholderName(in pattern: String) -> String? {
        guard let open = pattern.firstIndex(of: "("),
              let close = pattern.firstIndex(of: ")"),
              open < close
        else { return nil }
        let inner = pattern[pattern.index(after: open) ..< close]
        guard inner.first == "$" else { return nil }
        return String(inner.dropFirst())
    }
}
