import SwiftUI

/// Rebuild an activity from Apple Health for a time the user names, with
/// nothing left in the archive to start from.
///
/// The rest of the import sheet can only offer what it can find: an `HKWorkout`
/// Health already holds, or an archived stub a crashed recording left behind.
/// Neither exists for the case this section is for — the app died in the first
/// seconds of a workout, so it never wrote a workout to Health, and the
/// one-second session it left behind was deleted, because a one-second session
/// is junk and deleting junk is the obvious thing to do.
///
/// Health still has that hour: steps, heart rate, distance, exercise minutes.
/// All the rebuild ever needed from the archive was a start time and a sport,
/// and the user knows both.
struct RebuildFromHealthSection: View {
    let onRebuild: (Date, Sport) -> Void
    let isBusy: Bool

    /// Defaults to this morning rather than now: the activity being rebuilt has
    /// already happened, and a start time in the future finds nothing.
    @State private var start: Date = Calendar.current.date(
        bySettingHour: 7, minute: 0, second: 0, of: Date()
    ) ?? Date()
    @State private var sport: Sport = .walk

    var body: some View {
        Section { fields } header: { header } footer: { footer }
    }

    private var header: some View {
        Text(String(localized: "Rebuild from a time you remember", bundle: LanguageManager.appBundle))
    }

    private var footer: some View {
        Text(String(
            localized: "Pick when the activity started. Emuqu reads Apple Health forward from there, works out when you stopped moving, and rebuilds the workout from the steps, heart rate and distance it finds.",
            bundle: LanguageManager.appBundle
        ))
    }

    @ViewBuilder
    private var fields: some View {
        DatePicker(
            String(localized: "Started", bundle: LanguageManager.appBundle),
            selection: $start,
            in: ...Date(),
            displayedComponents: [.date, .hourAndMinute]
        )
        sportPicker
        rebuildButton
    }

    /// Only the sports Apple Health keeps a passive record for. Offering one it
    /// does not — a row, an air bike — would produce a workout with no distance
    /// and no pace, which is worse than not offering it.
    private var sportPicker: some View {
        Picker(String(localized: "Activity", bundle: LanguageManager.appBundle), selection: $sport) {
            ForEach([Sport.walk, .hike, .run, .trailRun, .treadmill, .bike, .indoorBike], id: \.self) {
                Text($0.displayName).tag($0)
            }
        }
    }

    @ViewBuilder
    private var rebuildButton: some View {
        if isBusy {
            HStack { Spacer(); ProgressView(); Spacer() }
        } else {
            Button(String(localized: "Rebuild from Apple Health", bundle: LanguageManager.appBundle)) {
                onRebuild(start, sport)
            }
        }
    }
}
