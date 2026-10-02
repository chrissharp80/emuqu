import PhotosUI
import SwiftUI

/// Build plan §4.6 M3.1 — avatar (tap to change). Round circular thumbnail
/// at the top of Profile settings. Tap opens iOS's native PhotosPicker;
/// the chosen image is downscaled to ~256×256 and JPEG-compressed before
/// it lands in `UserSettings.avatarImageData` (so the settings document
/// doesn't bloat).
struct AvatarPickerView: View {
    var settingsManager: SettingsManager = AppDependencies.current.app.settingsManager
    var size: CGFloat = 88

    @State private var pickerItem: PhotosPickerItem?
    @State private var processing = false
    @State private var lastError: String?

    var body: some View {
        // The picker's label closure is `@Sendable`, so read the observable
        // settings here on the main actor and hand the label plain values.
        let imageData = settingsManager.settings.avatarImageData
        let size = size
        let processing = processing
        return VStack(spacing: 8) {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                AvatarCircleLabel(imageData: imageData, size: size, processing: processing)
            }
            .buttonStyle(.plain)
            Text(verbatim: settingsManager.settings.avatarImageData == nil ? "Tap to add photo" : "Tap to change")
                .scaledFont(size: 11)
                .foregroundStyle(AppTheme.textTertiary)
            errorText
        }
        .onChange(of: pickerItem) { _, newItem in
            pick(newItem)
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if let lastError {
            Text(verbatim: lastError)
                .scaledFont(size: 11)
                .foregroundStyle(AppTheme.wongCaution)
        }
    }

    private func pick(_ newItem: PhotosPickerItem?) {
        guard let newItem else { return }
        processing = true
        Task {
            await loadAndStoreImage(from: newItem)
            processing = false
        }
    }

    private func loadAndStoreImage(from item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let raw = UIImage(data: data) else {
                lastError = "Couldn't read that image."
                return
            }
            guard let jpeg = await compressedAvatar(raw) else {
                lastError = "Couldn't compress that image."
                return
            }
            await MainActor.run {
                settingsManager.settings.avatarImageData = jpeg
                lastError = nil
            }
        } catch {
            await MainActor.run { lastError = "Photo load failed." }
        }
    }

    /// Downscale to 256×256 (aspect-fit), JPEG-encode at 0.7 quality. Net
    /// payload is typically 15–60 KB.
    private func compressedAvatar(_ raw: UIImage) async -> Data? {
        let target = CGSize(width: 256, height: 256)
        let scaled = await Task.detached { downscale(raw, to: target) }.value
        return scaled.jpegData(compressionQuality: 0.7)
    }
}

private func downscale(_ image: UIImage, to size: CGSize) -> UIImage {
    let scale = max(size.width / image.size.width, size.height / image.size.height)
    let scaled = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let origin = CGPoint(x: (size.width - scaled.width) / 2, y: (size.height - scaled.height) / 2)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { _ in
        image.draw(in: CGRect(origin: origin, size: scaled))
    }
}

/// The picker's label, built from plain values so the label closure captures
/// nothing that is tied to the main actor.
private struct AvatarCircleLabel: View {
    let imageData: Data?
    let size: CGFloat
    let processing: Bool

    var body: some View {
        ZStack {
            avatarImage
            processingScrim
        }
        .overlay(
            Circle().strokeBorder(AppTheme.primary.opacity(0.3), lineWidth: 1)
        )
        .accessibilityLabel(String(localized: "Profile photo", bundle: LanguageManager.appBundle))
        .accessibilityHint(String(localized: "Tap to change your profile photo", bundle: LanguageManager.appBundle))
    }

    @ViewBuilder
    private var avatarImage: some View {
        if let data = imageData,
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(AppTheme.primary.opacity(0.18))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(AppTheme.primary)
                )
        }
    }

    @ViewBuilder
    private var processingScrim: some View {
        if processing {
            Circle()
                .fill(.black.opacity(0.4))
                .frame(width: size, height: size)
            ProgressView().tint(.white)
        }
    }
}
