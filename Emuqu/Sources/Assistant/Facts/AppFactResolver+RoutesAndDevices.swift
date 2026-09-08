import CoreLocation
import Foundation

// The routes-library, now, devices and assistant-memory namespaces. These
// four answer questions about saved routes, connected hardware and
// remembered facts, none of which touch the live HRV / tags / HRR /
// composites resolvers in `AppFactResolver+Live.swift`.

// MARK: - routes.library.* namespace
//
// Surfaces the user's curated route library to the AI as both readable
// facts ("what routes do I have?", "tell me about Daily 1") AND
// mutation actions ("rename Daily 1 to Morning Loop", "save today's
// walk as Long Loop"). Mutations are gated by the system-prompt rule
// that mutation tools require explicit user instruction with the new
// value — the registry can't read intent, so the prompt enforces it.
//
// SavedRouteStore is @MainActor (it is `@Observable` and publishes route
// mutations to the Settings → My Routes view), so all
// reads/writes hop through MainActor.assumeIsolated. Resolver dispatch
// already runs on MainActor inside the assistant view-model loop, so
// this is fine.
//
// Save-workout uses the archive's most-recent finished workout as the
// implicit subject. The user says "save my last walk as Daily 1" — they
// don't supply an ID, they just mean the one they just finished. To
// disambiguate ("save the walk from Tuesday"), the user can name a
// date and the AI can call the read-only `routes.library.save_workout`
// with the optional `date` arg.
struct RoutesLibraryNamespace: FactNamespaceResolver {
    let namespace = "routes"
    let archive: SessionArchive

    private func currentRoutes() -> [SavedRoute] {
        MainActor.assumeIsolated { AppDependencies.current.location.savedRouteStore.routes }
    }

    private func mostRecentWorkout(matching dateISO: String? = nil) -> SessionArchiveEntry? {
        let workouts = archive.entries
            .filter { $0.sessionType == .workout }
            .sorted { $0.date > $1.date }
        guard let dateISO else { return workouts.first }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        guard let target = formatter.date(from: dateISO) else { return nil }
        let cal = Calendar.current
        let day = cal.startOfDay(for: target)
        guard let next = cal.date(byAdding: .day, value: 1, to: day) else { return nil }
        return workouts.first { $0.date >= day && $0.date < next }
    }

    private func renderRouteSummary(_ route: SavedRoute) -> FactValue {
        let dateFmt = ISO8601DateFormatter()
        dateFmt.formatOptions = [.withInternetDateTime]
        return .record([
            "id": .string(route.id.uuidString),
            "name": .string(route.name),
            "sport": .string(route.sport.rawValue),
            "created_at": .string(dateFmt.string(from: route.createdAt)),
            "distance_meters": .double(route.totalDistanceMeters),
            "ascent_meters": .double(route.totalAscentMeters),
            "descent_meters": .double(route.totalDescentMeters),
            "climb_count": .integer(route.climbCount)
        ])
    }

    var entries: [FactEntry] {
        [
            routesLibraryCountEntry,
            routesLibraryListEntry,
            routesLibraryRenameEntry,
            routesLibrarySaveWorkoutEntry,
            // Engage a saved route as the active
            // turn-by-turn navigation session. Synthesises a step
            // list from the saved polyline (turn detection +
            // OSM-resolved road names via SavedRouteStepBuilder)
            // and engages it as ActiveRouteSession — the same
            // session that powers the existing turn alerts +
            // turn-as-marker engines. Direction is auto-inferred:
            // user gets routed from whichever end of the saved
            routesLibraryEngageEntry
        ]
    }

    // ── Reads ─────────────────────────────────────────────────
    private var routesLibraryCountEntry: FactEntry {
        .fixed(
            key: "routes.library.count",
            description: "How many routes the user has saved in their route library. Cheap; call this first if you only need a count.",
            valueType: "Int"
        ) {
            .integer(self.currentRoutes().count)
        }
    }

    private var routesLibraryListEntry: FactEntry {
        .fixed(
            key: "routes.library.list",
            description: """
            All routes the user has saved in their library, newest-saved first. Each entry has id, name, sport, created_at, distance_meters, ascent_meters, descent_meters, climb_count. Use the 'name' field when speaking about a specific \
            route to the user — IDs are UUIDs and not user-facing.
            """,
            valueType: "List"
        ) {
            let routes = self.currentRoutes()
                .sorted { $0.createdAt > $1.createdAt }
            if routes.isEmpty {
                return .missing(reason: .notRecorded, detail: "user has no saved routes")
            }
            return .list(routes.map(self.renderRouteSummary))
        }
    }

    // ── Actions (mutations) ───────────────────────────────────
    private var routesLibraryRenameEntry: FactEntry {
        .action(
            key: "routes.library.rename",
            description: """
            [ACTION] Rename one of the user's saved routes. ONLY call this when the user explicitly asks for a rename and supplies the new name in the current turn — never on inference. Matches `current_name` case-insensitively. Errors \
            if no route matches, or if multiple routes share that name (saved-route names aren't unique). Returns a confirmation record with the old + new name on success.
            """,
            parameters: [
                ActionParam("current_name", "The exact current name of the saved route to rename (case-insensitive). Example: 'Daily 1'."),
                ActionParam("new_name", "The new name the user has asked for. Example: 'Morning Loop'.")
            ]
        ) { args in self.resolveRoutesLibraryRename(args) }
    }

    private func resolveRoutesLibraryRename(_ args: [String: String]) -> FactValue {
        guard let current = args["current_name"]?.trimmingCharacters(in: .whitespaces),
              !current.isEmpty
        else {
            return .missing(reason: .invalidParameter, detail: "current_name is required and must be non-empty")
        }
        guard let new = args["new_name"]?.trimmingCharacters(in: .whitespaces),
              !new.isEmpty
        else {
            return .missing(reason: .invalidParameter, detail: "new_name is required and must be non-empty")
        }
        let matches = self.currentRoutes().filter { $0.name.caseInsensitiveCompare(current) == .orderedSame }
        guard matches.count == 1 else {
            return ambiguousRoute(name: current, matches: matches.count)
        }
        return renamed(matches[0], to: new)
    }

    private func renamed(_ target: SavedRoute, to new: String) -> FactValue {
        MainActor.assumeIsolated {
            AppDependencies.current.location.savedRouteStore.rename(id: target.id, to: new)
        }
        return .record([
            "status": .string("renamed"),
            "id": .string(target.id.uuidString),
            "old_name": .string(target.name),
            "new_name": .string(new)
        ])
    }

    private var routesLibrarySaveWorkoutEntry: FactEntry {
        .action(
            key: "routes.library.save_workout",
            description: """
            [ACTION] Save a recent workout to the user's route library under the given name. ONLY call this when the user explicitly asks to save a workout and supplies the new route name in the current turn — never on inference. Without \
            a `date`, defaults to the most recently finished GPS workout. With `date` (yyyy-MM-dd), saves the workout from that date. Errors if the workout has no GPS polyline (indoor / no-fix sessions can't be saved as routes).
            """,
            parameters: [
                ActionParam("name", "The name the user has asked to save the route under. Example: 'Daily 1'."),
                ActionParam("date", "Optional yyyy-MM-dd date of the workout to save. Omit (or pass empty string) to save the most recent workout.", required: false)
            ]
        ) { args in self.resolveRoutesLibrarySaveWorkout(args) }
    }

    private func resolveRoutesLibrarySaveWorkout(_ args: [String: String]) -> FactValue {
        guard let name = args["name"]?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty
        else {
            return .missing(reason: .invalidParameter, detail: "name is required and must be non-empty")
        }
        guard let entry = self.mostRecentWorkout(matching: requestedDate(args)) else {
            let detail = requestedDate(args).map { "no workout on \($0)" } ?? "no recent workouts in archive"
            return .missing(reason: .notRecorded, detail: detail)
        }
        guard let session = self.archive.retrieveLightweightOrLog(entry.sessionId) else {
            return .missing(reason: .internalError, detail: "could not load workout from archive")
        }
        guard let saved = SavedRoute.from(session: session, name: name) else {
            return .missing(reason: .invalidParameter, detail: "workout has no GPS polyline — indoor or no-fix sessions can't be saved as routes")
        }
        MainActor.assumeIsolated {
            AppDependencies.current.location.savedRouteStore.add(saved)
        }
        return .record(savedRouteRecord(saved, from: entry))
    }

    private func requestedDate(_ args: [String: String]) -> String? {
        let dateArg = args["date"]?.trimmingCharacters(in: .whitespaces)
        return (dateArg?.isEmpty == false) ? dateArg : nil
    }

    private func savedRouteRecord(_ saved: SavedRoute, from entry: SessionArchiveEntry) -> [String: FactValue] {
        [
            "status": .string("saved"),
            "id": .string(saved.id.uuidString),
            "name": .string(saved.name),
            "sport": .string(saved.sport.rawValue),
            "distance_meters": .double(saved.totalDistanceMeters),
            "ascent_meters": .double(saved.totalAscentMeters),
            "climb_count": .integer(saved.climbCount),
            "from_workout_date": .string(ISO8601DateFormatter().string(from: entry.date))
        ]
    }

    // polyline they're currently closer to.
    private var routesLibraryEngageEntry: FactEntry {
        .actionAsync(
            key: "routes.library.engage",
            description: Self.routesLibraryEngageDescription,
            parameters: [
                ActionParam("name", "The exact name of the saved route to engage (case-insensitive). Match against the names returned by routes.library.list. Example: 'Daily 1', 'Saturday loop', 'Morning hill'.")
            ]
        ) { args in await self.resolveRoutesLibraryEngage(args) }
    }

    @MainActor private func resolveRoutesLibraryEngage(_ args: [String: String]) async -> FactValue {
        guard let name = args["name"]?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty
        else {
            return .missing(reason: .invalidParameter, detail: "name is required and must be non-empty — match against routes.library.list")
        }
        let matches = self.currentRoutes().filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard matches.count == 1 else {
            return ambiguousRoute(name: name, matches: matches.count)
        }
        // Need a current location fix to infer direction
        // and to engage the session.
        guard let userLoc = AppDependencies.current.location.ambientLocationService.cachedLocation(maxAgeSec: 60) else {
            return .missing(reason: .notRecorded, detail: "couldn't get a current location fix to engage the route — open the app foreground or start a workout to warm up the GPS pipeline")
        }
        return await engageSavedRoute(matches[0], from: userLoc)
    }

    @MainActor private func engageSavedRoute(
        _ saved: SavedRoute,
        from userLoc: CLLocation
    ) async -> FactValue {
        guard let result = await buildSyntheticRoute(saved, from: userLoc) else {
            return .missing(
                reason: .notRecorded,
                detail: "still building '\(saved.name)' — OSM tile prefetch in progress. Ask again in a few seconds; the cache will be warm."
            )
        }
        engage(result)
        return .record(engagedRouteRecord(result))
    }

    @MainActor private func engage(_ result: SavedRouteStepBuilder.BuildResult) {
        // Already on the MainActor (awaitable resolver body).
        AppDependencies.current.location.activeRouteSession.engageSyntheticRoute(
            steps: result.steps,
            totalDistance: result.totalDistanceMeters,
            totalDuration: result.totalDurationSeconds,
            destinationLabel: result.routeName,
            destinationCoord: result.destinationCoordinate
        )
    }

    private func ambiguousRoute(name: String, matches: Int) -> FactValue {
        guard matches > 1 else {
            return .missing(reason: .notRecorded, detail: "no saved route named '\(name)' — call routes.library.list to see available names")
        }
        return .missing(
            reason: .invalidParameter,
            detail: "multiple saved routes share the name '\(name)' (\(matches) matches) — disambiguate by asking the user which one (e.g. by date or distance)"
        )
    }

    // The step build is async (OSM tile fetch). It must not
    // be a sync→async semaphore bridge invoked from
    // `runToolUseLoop` on @MainActor — that BLOCKS THE MAIN
    // THREAD, and iOS App Watchdog kills the app at ~10 s of
    // unresponsive main, so a 30 s budget here is dangerous
    // (real-user termination report: workout killed at
    // 110 min, no memory/thermal pressure, 3-min sampler
    // gap = signature of main-thread block).
    //
    // Capped at 3 s. If OSM tile fetches
    // can't complete in time we fall back gracefully:
    // the build keeps running so the tile cache fills,
    // then we ask the user to try again. Subsequent calls
    // hit the warm cache and complete instantly.
    //
    // The cap is a suspending timeout race, not a
    // semaphore bridge, and FactResolveTimeout
    // deliberately does NOT cancel the loser, so the
    // timed-out build still warms the cache exactly as
    // documented above. Main suspends instead of parking.
    @MainActor private func buildSyntheticRoute(
        _ saved: SavedRoute,
        from userLoc: CLLocation
    ) async -> SavedRouteStepBuilder.BuildResult? {
        await FactResolveTimeout.withTimeout(seconds: 3) {
            await SavedRouteStepBuilder.build(
                savedRoute: saved,
                currentLocation: userLoc.coordinate
            )
        }
    }

    private func engagedRouteRecord(_ result: SavedRouteStepBuilder.BuildResult) -> [String: FactValue] {
        [
            "status": .string("engaged"),
            "name": .string(result.routeName),
            "direction": .string(result.direction.rawValue),
            "distance_meters": .double(result.totalDistanceMeters),
            "estimated_duration_seconds": .double(result.totalDurationSeconds),
            "step_count": .integer(result.steps.count),
            "has_unnamed_turns": .boolean(result.hasUnnamedTurns),
            "first_instruction": .string(result.steps.first?.instructions ?? "")
        ]
    }

    private static let routesLibraryEngageDescription = """
    [ACTION] Load one of the user's saved routes into navigation mode and follow IT (their exact recorded path), not whatever Apple's walking router would compute. Turn alerts (when `enableTurnByTurnAlerts` is on) and post-turn \
    split updates (when `enableTurnMarkerUpdates` is on) fire on each detected turn. Direction is auto-inferred from the user's current position — the engine picks whichever end of the saved polyline the user is closer to, then \
    routes them toward the other end. Returns the route name, distance, estimated duration, step count, direction (forward / reverse), and a `has_unnamed_turns` flag (true when some turns lack OSM road names, e.g. on unnamed \
    footpaths or in regions like Japan / Korea where most residential streets aren't named). Use when the user says 'load my Saturday loop' / 'engage Daily 1' / 'follow my morning route'. Calls routes.library.list first if the \
    user names a route you don't recognise.
    """
}

// MARK: - app.now.* namespace
//
// "What time is it for the user?" — surprisingly often the AI guesses
// wrong about TZ when the question depends on it. Three small facts
// close that gap.
struct AppNowNamespace: FactNamespaceResolver {
    let namespace = "app"

    var entries: [FactEntry] {
        [
            appNowIsoEntry,
            appNowLocalDateEntry,
            appNowTimezoneEntry,
            appNowDayOfWeekEntry
        ]
    }

    private var appNowIsoEntry: FactEntry {
        .fixed(
            key: "app.now.iso",
            description: "Current wall-clock timestamp in ISO8601 (UTC). Use this to anchor relative-time math instead of guessing.",
            valueType: "Date"
        ) {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return .string(f.string(from: Date()))
        }
    }

    private var appNowLocalDateEntry: FactEntry {
        .fixed(
            key: "app.now.local_date",
            description: "Today's date in the user's local timezone, yyyy-MM-dd. Use this when the user asks about 'today' / 'yesterday' / a relative day so date math respects their TZ.",
            valueType: "String"
        ) {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone.current
            return .string(f.string(from: Date()))
        }
    }

    private var appNowTimezoneEntry: FactEntry {
        .fixed(
            key: "app.now.timezone",
            description: "User's current timezone identifier (e.g. 'America/Chicago'). Pair with app.now.iso when you need to render a local time.",
            valueType: "String"
        ) {
            .string(TimeZone.current.identifier)
        }
    }

    private var appNowDayOfWeekEntry: FactEntry {
        .fixed(
            key: "app.now.day_of_week",
            description: "Today's day of week in the user's locale ('Monday', 'Tuesday', …).",
            valueType: "String"
        ) {
            let f = DateFormatter()
            f.dateFormat = "EEEE"
            f.locale = Locale.current
            return .string(f.string(from: Date()))
        }
    }
}

// MARK: - app.devices.* namespace (Polar + foot-pod + rower + Zwift)
//
// Sensor-and-device state visible to the AI any time, regardless of
// whether a workout is active. Polar state comes from the canonical
// `RRCollector.current` (set by `makeDefault()`); foot-pod / rower /
// broadcaster come from their existing singletons.
struct AppDevicesNamespace: FactNamespaceResolver {
    let namespace = "app"

    private func polar() -> PolarManager? {
        MainActor.assumeIsolated { RRCollector.current?.polarManager }
    }

    var entries: [FactEntry] {
        [
            appDevicesPolarConnectedEntry,
            appDevicesPolarBatteryPercentEntry,
            polarHoursSinceChargeEntry,
            appDevicesPolarSpecCapacityHoursEntry,
            appDevicesPolarDeviceTypeEntry,
            appDevicesPolarFirmwareEntry,
            appDevicesPolarKnownCountEntry,
            appDevicesFootPodConnectedEntry,
            appDevicesFootPodKnownCountEntry,
            appDevicesFootPodSnapshotEntry,
            appDevicesPm5ConnectedEntry,
            appDevicesPm5KnownCountEntry,
            appDevicesZwiftBroadcastAdvertisingEntry,
            zwiftSubscriberCountEntry
        ]
    }

    // ── Polar strap / Verity ──────────────────────────────────
    private var appDevicesPolarConnectedEntry: FactEntry {
        .fixed(
            key: "app.devices.polar.connected",
            description: "Whether a Polar device (H10 or Verity Sense) is currently connected over BLE.",
            valueType: "Bool"
        ) {
            guard let p = self.polar() else { return .boolean(false) }
            return .boolean(MainActor.assumeIsolated { p.connectionState == .connected })
        }
    }

    private var appDevicesPolarBatteryPercentEntry: FactEntry {
        .fixed(
            key: "app.devices.polar.battery_percent",
            description: "Last reported Polar battery level (0–100). May be stale — Polar's BLE SDK reports opportunistically. Cross-check with app.devices.polar.recording_hours_since_charge for the honest 'how much capacity is left' answer.",
            valueType: "Int"
        ) {
            guard let p = self.polar() else {
                return .missing(reason: .notRecorded, detail: "no Polar connected")
            }
            let lvl = MainActor.assumeIsolated { p.batteryLevel }
            return .from(lvl, detail: "battery never reported")
        }
    }

    private var polarHoursSinceChargeEntry: FactEntry {
        .fixed(
            key: "app.devices.polar.recording_hours_since_charge",
            description: "Hours of recording the connected Polar has accumulated since the last detected full charge. Compare against app.devices.polar.spec_capacity_hours for an honest battery prediction (Polar's reported percentage often stalls).",
            valueType: "Double"
        ) {
            guard let p = self.polar() else {
                return .missing(reason: .notRecorded, detail: "no Polar connected")
            }
            let h = MainActor.assumeIsolated { p.hoursRecordedSinceBatteryChanged }
            return .double(h)
        }
    }

    private var appDevicesPolarSpecCapacityHoursEntry: FactEntry {
        .fixed(
            key: "app.devices.polar.spec_capacity_hours",
            description: "Manufacturer-published recording capacity for the connected Polar (H10 ≈ 400 h, Verity Sense ≈ 30 h). Use as the denominator for 'how much battery time is left'.",
            valueType: "Double"
        ) {
            guard let p = self.polar(),
                  let t = MainActor.assumeIsolated({ p.connectedDeviceType })
            else {
                return .missing(reason: .notRecorded, detail: "no Polar connected")
            }
            return .double(t.specRecordingHours)
        }
    }

    private var appDevicesPolarDeviceTypeEntry: FactEntry {
        .fixed(
            key: "app.devices.polar.device_type",
            description: "Connected Polar device type ('H10' chest strap or 'Verity Sense' optical).",
            valueType: "String"
        ) {
            guard let p = self.polar(), let t = MainActor.assumeIsolated({ p.connectedDeviceType }) else {
                return .missing(reason: .notRecorded, detail: "no Polar connected")
            }
            return .string(String(describing: t))
        }
    }

    private var appDevicesPolarFirmwareEntry: FactEntry {
        .fixed(
            key: "app.devices.polar.firmware",
            description: "Firmware/software revision string of the connected Polar device.",
            valueType: "String"
        ) {
            guard let p = self.polar() else {
                return .missing(reason: .notRecorded, detail: "no Polar connected")
            }
            let fw = MainActor.assumeIsolated { p.firmwareVersion }
            return .from(fw, detail: "firmware not yet read")
        }
    }

    private var appDevicesPolarKnownCountEntry: FactEntry {
        .fixed(
            key: "app.devices.polar.known_count",
            description: "Number of Polar devices the user has paired (across H10 + Verity). The user's library; not all of them need be connected right now.",
            valueType: "Int"
        ) {
            guard let p = self.polar() else { return .integer(0) }
            return .integer(MainActor.assumeIsolated { p.knownDevices.count })
        }
    }

    // ── Stryd / FTMS bike (FootPodManager wraps both) ─────────
    private var appDevicesFootPodConnectedEntry: FactEntry {
        .fixed(
            key: "app.devices.foot_pod.connected",
            description: "Whether a Stryd-style foot pod (or any FTMS-spec bike trainer) is currently connected over BLE. Source for running power and FTMS bike power.",
            valueType: "Bool"
        ) {
            .boolean(MainActor.assumeIsolated { AppDependencies.current.collection.footPodManager.connectionState == .connected })
        }
    }

    private var appDevicesFootPodKnownCountEntry: FactEntry {
        .fixed(
            key: "app.devices.foot_pod.known_count",
            description: "Number of paired foot pods / FTMS devices in the user's library.",
            valueType: "Int"
        ) {
            .integer(MainActor.assumeIsolated { AppDependencies.current.collection.footPodManager.knownDevices.count })
        }
    }

    private var appDevicesFootPodSnapshotEntry: FactEntry {
        .fixed(
            key: "app.devices.foot_pod.snapshot",
            description: """
            One-record summary of foot pod state — what the user means when they ask 'is my foot pod working'. Returns connection state, paired-device count, last status string, and the LIVE values currently streaming (instant power \
            watts, cadence steps/min, instant speed m/s) when available. Use this in preference to the per-field facts when the user asks an open question about foot pod / Stryd / FTMS sensor health.
            """,
            valueType: "Record"
        ) { self.resolveAppDevicesFootPodSnapshot() }
    }

    private func resolveAppDevicesFootPodSnapshot() -> FactValue {
        MainActor.assumeIsolated {
            let m = AppDependencies.current.collection.footPodManager
            return .record([
                "connection_state": .string(String(describing: m.connectionState)),
                "is_connected": .boolean(m.connectionState == .connected),
                "known_device_count": .integer(m.knownDevices.count),
                "last_status_line": .string(m.lastStatusLine),
                "instant_power_watts": .from(m.instantaneousPowerWatts),
                "cadence_spm": .from(m.cadenceStepsPerMin),
                "instant_speed_ms": .from(m.instantaneousSpeedMS),
                "stride_length_m": .from(m.strideLengthMeters)
            ])
        }
    }

    // ── Concept2 PM5 rower ────────────────────────────────────
    private var appDevicesPm5ConnectedEntry: FactEntry {
        .fixed(
            key: "app.devices.pm5.connected",
            description: "Whether a Concept2 PM5 rower is currently connected over BLE.",
            valueType: "Bool"
        ) {
            .boolean(MainActor.assumeIsolated { AppDependencies.current.collection.concept2Manager.connectionState == .connected })
        }
    }

    private var appDevicesPm5KnownCountEntry: FactEntry {
        .fixed(
            key: "app.devices.pm5.known_count",
            description: "Number of paired Concept2 PM5 rowers in the user's library.",
            valueType: "Int"
        ) {
            .integer(MainActor.assumeIsolated { AppDependencies.current.collection.concept2Manager.knownDevices.count })
        }
    }

    // ── Zwift / TrainerRoad / Rouvy broadcaster ───────────────
    private var appDevicesZwiftBroadcastAdvertisingEntry: FactEntry {
        .fixed(
            key: "app.devices.zwift_broadcast.advertising",
            description: "Whether Emuqu is currently advertising itself as a BLE Heart Rate + Cycling Power peripheral so Zwift / TrainerRoad / Rouvy can pair to it. Off by default; gated on the Settings → Broadcast as BLE sensor toggle.",
            valueType: "Bool"
        ) {
            .boolean(MainActor.assumeIsolated { AppDependencies.current.collection.zwiftPeripheralBroadcaster.isAdvertising })
        }
    }

    private var zwiftSubscriberCountEntry: FactEntry {
        .fixed(
            key: "app.devices.zwift_broadcast.subscriber_count",
            description: "How many BLE centrals (Zwift / TrainerRoad / etc.) are currently subscribed to the Emuqu broadcast.",
            valueType: "Int"
        ) {
            .integer(MainActor.assumeIsolated { AppDependencies.current.collection.zwiftPeripheralBroadcaster.subscriberCount })
        }
    }
}
