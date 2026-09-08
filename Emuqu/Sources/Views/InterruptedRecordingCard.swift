import SwiftUI

/// The Fitness-home card that tells the user a recording died and that the
/// hour is recoverable.
///
/// This exists because the rebuild worked and nobody was ever shown it. When a
/// workout recording crashes, `WorkoutRecoveryService` archives what it has —
/// for a crash in the first seconds that is a one-second stub — and says
/// nothing. `HealthWorkoutImporter` can rebuild that hour from Apple Health's
/// passive record, but the only way in was the Fitness tab's overflow menu,
/// under a title ("Import from Apple Health") that reads like a Strava feature
/// rather than the answer to "where is my walk". A user who loses a walk does
/// not go looking in an ellipsis menu; they look at the tab where their
/// workouts are, see the one-second ghost, and conclude the app lost it.
///
/// So the app says it first, on the surface the user is already on. The card
/// opens the same sheet and runs the same rebuild — this adds a way in, not a
/// second implementation.
///
/// Its own type rather than another computed property on `FitnessTabView`
/// because that type is measured whole by `check_aggregate_type_size.sh` and
/// this is a self-contained readout: it takes a stub and a tap handler, and
/// stores nothing.
struct InterruptedRecordingCard: View {
    let stub: HealthWorkoutImporter.InterruptedSession
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) { label }
            .buttonStyle(.plain)
            .accessibilityIdentifier("fitness.interruptedRecordingCard")
    }

    private var label: some View {
        HStack(spacing: 12) {
            icon
            text
            Spacer()
            Image(systemName: "chevron.right")
                .accessibilityHidden(true)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textTertiary)
        }
        .padding(12)
        .background(AppTheme.cardBackground)
        .cornerRadius(12)
    }

    /// Orange, not red. The hour is retrievable — this is an action the user
    /// can take, not a failure they have to absorb.
    private var icon: some View {
        Image(systemName: "arrow.clockwise.heart")
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.orange))
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "Rebuild an interrupted recording", bundle: LanguageManager.appBundle))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(3)
        }
    }

    /// Names the workout the user is missing, so the card is about THEIR walk
    /// rather than a generic condition.
    private var subtitle: String {
        let when = stub.startDate.formatted(date: .abbreviated, time: .shortened)
        return String(
            localized: "Your \(stub.sport.displayName) on \(when) captured almost nothing. Apple Health still has the steps, heart rate and distance from that hour.",
            bundle: LanguageManager.appBundle
        )
    }
}
