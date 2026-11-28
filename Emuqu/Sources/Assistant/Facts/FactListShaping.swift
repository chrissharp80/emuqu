import Foundation

// Two rules that keep long per-period lists usable, applied by
// `FactResolverRegistry` to every namespace's lists alike.
//
// Field projection. A key tail after a list lookup keeps only the named
// fields of each item, plus the fields that say which item it is:
//   `hrv.recent(2026-02).overnight_min_hr_bpm`
//   `sleep.recent(90d).total_sleep_minutes,deep_minutes`
// A tail of several dotted tokens walks into each item the way a single
// record lookup walks its tail (`SessionNamespace.field(of:tail:)`). When
// the lookup itself already answered the tail (a single record's field, or
// a list whose items do not carry the field), its answer stands.
//
// Size truncation. A list over the per-call byte cap comes back as the
// newest items that fit, wrapped as `{items, truncated, returned_count,
// omitted_count, detail}`, so the model answers from what fits or asks for
// a shorter period. A record whose largest field is a list is cut the same
// way in place, with the markers added beside it. Anything else over the
// cap stays `.tooMuchData`.
enum FactListShaping {
    /// Fields every projected item keeps, when it has them, so each one
    /// still says which night or session it is.
    static let projectionIdentityFields = ["date", "session_type", "session_id", "id", "started_at"]

    /// The key without its plain trailing tokens, and those tokens, when
    /// the key has a parameterised token followed by plain ones.
    static func projectionSplit(_ key: FactKey) -> (base: FactKey, tail: FactKey)? {
        guard let lastArgument = key.tokens.lastIndex(where: { $0.argument != nil }),
              lastArgument < key.tokens.count - 1
        else { return nil }
        let tail = Array(key.tokens[(lastArgument + 1)...])
        guard tail.allSatisfy({ $0.argument == nil }) else { return nil }
        return (FactKey(tokens: Array(key.tokens[...lastArgument])), FactKey(tokens: tail))
    }

    /// `value` with each item cut down to `tail`'s fields, or nil when
    /// `value` is not a list of records any of which carries one of them.
    static func projected(_ value: FactValue, tail: FactKey) -> FactValue? {
        guard case .list(let items) = value else { return nil }
        let paths = projectionPaths(tail)
        let cut = items.map { projectedItem($0, paths: paths) }
        guard cut.contains(where: { $0.found }) else { return nil }
        return .list(cut.map(\.value))
    }

    /// One path per comma-separated name in a single-token tail; a dotted
    /// tail is one nested path.
    private static func projectionPaths(_ tail: FactKey) -> [FactKey] {
        guard tail.tokens.count == 1, let only = tail.tokens.first else { return [tail] }
        let names = only.name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return names.map { FactKey(tokens: [FactKey.Token(name: $0)]) }
    }

    /// The item with only the identity fields and the paths it has; `found`
    /// says whether any path was there.
    private static func projectedItem(_ item: FactValue, paths: [FactKey]) -> (value: FactValue, found: Bool) {
        guard case .record(let fields) = item else { return (item, false) }
        var kept = fields.filter { projectionIdentityFields.contains($0.key) }
        var found = false
        for path in paths {
            let value = SessionNamespace.field(of: item, tail: path)
            guard !value.isMissing else { continue }
            kept[path.rendered] = value
            found = true
        }
        return (.record(kept), found)
    }

    /// The answer for a key whose full form no namespace matched: its base
    /// lookup projected onto the tail. A missing base answer stands; a base
    /// that is not a projectable list leaves the key unknown (nil).
    static func projectedFromBase(_ base: FactValue?, tail: FactKey) -> FactValue? {
        guard let base else { return nil }
        if base.isMissing { return base }
        return projected(base, tail: tail)
    }
}

// MARK: - Size truncation

extension FactListShaping {
    /// `value` cut to fit `capBytes`, or nil when it cannot be: not a list
    /// (or a record holding one), or not even one item fits.
    static func truncatedToFit(_ value: FactValue, capBytes: Int) -> FactValue? {
        switch value {
        case .list(let items):
            return truncatedList(items, capBytes: capBytes, wrap: wrappedList)
        case .record(let fields):
            guard let (name, items) = largestListField(fields) else { return nil }
            return truncatedList(items, capBytes: capBytes) { kept, omitted in
                cutRecord(fields, field: name, kept: kept, omitted: omitted)
            }
        default:
            return nil
        }
    }

    /// A cut top-level list: `{items, truncated, returned_count, omitted_count, detail}`.
    private static func wrappedList(_ kept: [FactValue], omitted: Int) -> FactValue {
        var record = truncationMarkers(returned: kept.count, omitted: omitted)
        record["items"] = .list(kept)
        return .record(record)
    }

    /// The record with `field` cut to `kept` and the markers beside it.
    private static func cutRecord(_ fields: [String: FactValue], field: String, kept: [FactValue], omitted: Int) -> FactValue {
        var cut = fields.merging(truncationMarkers(returned: kept.count, omitted: omitted)) { _, new in new }
        cut[field] = .list(kept)
        cut["truncated_field"] = .string(field)
        return .record(cut)
    }

    /// The largest count of the newest items whose wrapped form fits, found
    /// by bisection; nil when none fits.
    private static func truncatedList(_ items: [FactValue], capBytes: Int, wrap: ([FactValue], Int) -> FactValue) -> FactValue? {
        let isNewestFirst = newestFirst(items)
        let ordered = isNewestFirst ? items : items.reversed()
        func fitted(_ count: Int) -> FactValue {
            let kept = Array(ordered.prefix(count))
            return wrap(isNewestFirst ? kept : kept.reversed(), items.count - count)
        }
        var (low, high) = (0, items.count - 1)
        while low < high {
            let mid = (low + high + 1) / 2
            if fitted(mid).toolResultJSON.utf8.count <= capBytes { low = mid } else { high = mid - 1 }
        }
        return low > 0 ? fitted(low) : nil
    }

    private static func truncationMarkers(returned: Int, omitted: Int) -> [String: FactValue] {
        [
            "truncated": .boolean(true),
            "returned_count": .integer(returned),
            "omitted_count": .integer(omitted),
            "detail": .string("Too long for one answer: only the newest \(returned) items are here and \(omitted) older ones were left out. "
                + "Ask for a shorter period (e.g. one month: 2026-02) or one field (append .field_name to the key) to see the rest.")
        ]
    }

    /// The record's list field with the most items, when it has one.
    private static func largestListField(_ fields: [String: FactValue]) -> (String, [FactValue])? {
        let lists = fields.compactMap { field -> (String, [FactValue])? in
            guard case .list(let items) = field.value, items.count > 1 else { return nil }
            return (field.key, items)
        }
        return lists.max { $0.1.count < $1.1.count || $0.1.count == $1.1.count && $0.0 > $1.0 }
    }

    /// Whether the list runs newest to oldest, read from its first and last
    /// items' dates. Lists here are newest first unless their dates say
    /// otherwise.
    private static func newestFirst(_ items: [FactValue]) -> Bool {
        guard let first = items.first.flatMap(itemDate), let last = items.last.flatMap(itemDate) else { return true }
        return first >= last
    }

    /// An item's date as sortable text (ISO dates and yyyy-MM-dd days).
    private static func itemDate(_ item: FactValue) -> String? {
        guard case .record(let fields) = item else { return nil }
        for name in ["date", "started_at", "start_date"] {
            switch fields[name] {
            case .date(let date): return FactValue.localISO8601(date)
            case .string(let text): return text
            default: continue
            }
        }
        return nil
    }
}
