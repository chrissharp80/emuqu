import Foundation

// Which heart-rate source the workout shows, decided each tick from the strap
// channels and the Watch's wrist HR. Split out of WorkoutRecorder+Ticker.swift.

extension WorkoutTicker {
    // MARK: - HR-source arbitration (pure decision core)

    /// HR source priority by `recorder.activeHRSource`:
    ///
    ///   - .strap  : strap is primary. Watch is the silent-strap fallback.
    ///               Order: (a) iPhone-paired strap (already in workoutHR
    ///               from RR derivation earlier in the tick), (b) Watch
    ///               direct-strap (also already applied in the tick when
    ///               the route is fresh), (c) Watch wrist HR.
    ///   - .watch  : Watch is primary. Always use Watch wrist HR.
    ///   - .none   : no HR at all.
    ///
    /// When the user is told (`strapNotice`):
    ///   • only in `.strap` mode;
    ///   • only past `strapNoticeGraceSec` of recording, so a strap still
    ///     connecting at the start is not an alarm;
    ///   • only while both strap channels are silent;
    ///   • "not connected" when there is no link, "silent" when the link
    ///     judges the feed stalled. A strap still setting up raises nothing.
    ///
    /// Pure: inputs in, `Decision` out. No clocks, no logging, no state.
    enum HRArbitration {
        /// Both strap channels silent past this → fall through to wrist HR.
        static let wristFallbackSilenceSec: TimeInterval = 10
        /// Recording time before a missing strap is worth telling the user about.
        static let strapNoticeGraceSec: TimeInterval = 15
        /// Wrist HR the Watch sent longer ago than this is treated as no
        /// longer arriving. The Watch sends a new reading every few seconds.
        static let wristHRMaxAgeSec: TimeInterval = 30

        /// Everything the per-tick cascade reads, snapshotted by the shell.
        /// The silence intervals are `.infinity` when that channel has never
        /// produced an event this workout (nil timestamp).
        struct Inputs {
            /// Which HR source the user picked for this workout.
            var sourceMode: WorkoutRecorder.HRSource
            /// Seconds of recording elapsed (frozen while paused, like the
            /// clock the user sees).
            var recordingElapsedSeconds: Int
            /// Seconds since the iPhone-paired Polar last produced a beat.
            var strapSilentFor: TimeInterval
            /// Seconds since the Watch-routed strap path last produced beats.
            /// Deliberately a separate channel from `strapSilentFor` — reusing
            /// one timestamp would mask a true Polar drop with stale freshness
            /// from the Watch path and break the wrist-HR tier (see
            /// `recorder.lastWatchRoutedHRAt`).
            var watchRoutedSilentFor: TimeInterval
            /// Watch wrist HR (optical), if the Watch is still reporting one.
            var latestWatchHR: Int?
            /// The strap's heart-rate feed as its link sees it.
            var strapFeed: StrapFeedHealth.Status
        }

        /// What the shell must apply. Pure data — no side effects here.
        struct Decision: Equatable {
            /// Wrist HR to copy into the live display (+ peak tracking), or
            /// nil to leave the display exactly as the RR-derived paths set it.
            var displayHRUpdate: Int?
            /// Why the strap is not supplying heart rate, when the user should know.
            var strapNotice: WorkoutStrapNotice?
            /// Every source the mode relies on is silent: the display drops
            /// its last value rather than recording it as current.
            var clearDisplayHR = false
        }

        /// Whether the heart rate on display after `decision` is the Watch's
        /// wrist HR: yes once wrist HR is copied in, no once the display is
        /// cleared, otherwise unchanged (the strap paths clear it when they
        /// write a reading).
        static func displayIsWrist(_ decision: Decision, wasWrist: Bool) -> Bool {
            if decision.displayHRUpdate != nil { return true }
            if decision.clearDisplayHR { return false }
            return wasWrist
        }

        static func decide(_ inputs: Inputs) -> Decision {
            let update = displayHRUpdate(inputs)
            return Decision(
                displayHRUpdate: update, strapNotice: strapNotice(inputs),
                clearDisplayHR: update == nil && allSourcesSilent(inputs)
            )
        }

        private static func allSourcesSilent(_ inputs: Inputs) -> Bool {
            switch inputs.sourceMode {
            case .strap:
                inputs.strapSilentFor > wristFallbackSilenceSec
                    && inputs.watchRoutedSilentFor > wristFallbackSilenceSec
                    && inputs.latestWatchHR == nil
            case .watch: inputs.latestWatchHR == nil
            case .none: false
            }
        }

        /// In `.strap` mode, both strap channels going silent falls through to
        /// Watch wrist HR — the chest-strap path earlier in the tick already
        /// handled the case where Watch-routed strap is fresh. nil wrist HR →
        /// no update here (`allSourcesSilent` decides whether to clear).
        private static func displayHRUpdate(_ inputs: Inputs) -> Int? {
            switch inputs.sourceMode {
            case .strap:
                guard inputs.strapSilentFor > wristFallbackSilenceSec,
                      inputs.watchRoutedSilentFor > wristFallbackSilenceSec
                else { return nil }
                return inputs.latestWatchHR
            case .watch:
                return inputs.latestWatchHR
            case .none:
                return nil
            }
        }

        private static func strapNotice(_ inputs: Inputs) -> WorkoutStrapNotice? {
            guard inputs.sourceMode == .strap,
                  TimeInterval(inputs.recordingElapsedSeconds) > strapNoticeGraceSec,
                  inputs.strapSilentFor > wristFallbackSilenceSec,
                  inputs.watchRoutedSilentFor > wristFallbackSilenceSec
            else { return nil }
            switch inputs.strapFeed {
            case .waitingForStrap: return .strapNotConnected
            case .stalled: return .strapSilent
            case .settingUp, .live: return nil
            }
        }
    }
}
