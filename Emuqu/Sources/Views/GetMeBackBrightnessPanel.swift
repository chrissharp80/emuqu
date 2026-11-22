import SwiftUI

/// Get Me Back's screen-brightness panel: a caption, a slider between a dim
/// and a bright sun, and a note that the change reverts on leaving.
/// `brightness` is the override `GetMeBackView` owns; setting it is what
/// changes the screen.
struct GetMeBackBrightnessPanel: View {
    @Binding var brightness: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Screen brightness", bundle: LanguageManager.appBundle))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)
            sliderRow
            Text(String(localized: "Defaults to your system brightness. Drag down to save battery; reverts when you leave this screen.", bundle: LanguageManager.appBundle))
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(12)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var sliderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.min")
                .foregroundStyle(AppTheme.textSecondary)
            Slider(value: $brightness, in: 0.05 ... 1.0)
            Image(systemName: "sun.max.fill")
                .foregroundStyle(AppTheme.textSecondary)
        }
    }
}
