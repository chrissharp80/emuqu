import LinkPresentation
import SwiftUI
import UIKit

/// A share button whose file is written only when it is tapped and deleted
/// once the share sheet closes, whether the user shared it or cancelled
/// (`presentFileShareSheet`). Not a `ShareLink`: a `ShareLink` reports no
/// completion, so the health data in a file it hands over would stay in
/// `tmp/Exports` until the next export or launch. The launch
/// sweep (`ExportFile.removeLeftovers`) still removes a file whose sheet the
/// app was closed under.
///
/// The sheet is presented straight from the topmost view controller, as the
/// recap card's is, not from a SwiftUI `.sheet`. The button is disabled
/// while the file is being written; a file that cannot be written raises
/// "Export failed" instead of a tap that does nothing.
struct FileShareButton<Label: View>: View {
    /// The sheet's header (`ShareFileItem`); nil shows the file's name.
    let title: String?
    /// SF Symbol shown beside `title`.
    let iconName: String?
    /// Writes the file. A `@Sendable` closure, so it runs off the main actor.
    let makeFile: @Sendable () async throws -> URL
    let label: Label
    @State private var preparing = false
    @State private var failed = false

    init(
        title: String?,
        iconName: String? = nil,
        makeFile: @escaping @Sendable () async throws -> URL,
        @ViewBuilder label: () -> Label
    ) {
        self.title = title
        self.iconName = iconName
        self.makeFile = makeFile
        self.label = label()
    }

    var body: some View {
        Button {
            Task { await share() }
        } label: {
            label
        }
        .disabled(preparing)
        .alert(String(localized: "Export failed", bundle: LanguageManager.appBundle), isPresented: $failed) {
            Button(String(localized: "OK", bundle: LanguageManager.appBundle), role: .cancel) {}
        }
    }

    /// Write the file, then present the sheet that deletes it. With nothing
    /// to present from, the file is deleted at once.
    private func share() async {
        guard !preparing else { return }
        preparing = true
        defer { preparing = false }
        let file: URL
        do {
            file = try await makeFile()
        } catch {
            debugLog("[FileShareButton] The file to share could not be written: \(error.localizedDescription)", level: .warning)
            failed = true
            return
        }
        guard let presenter = topmostPresenter() else {
            _ = attempt("FileShareButton.removeUnshared") { try FileManager.default.removeItem(at: file) }
            return
        }
        presentFileShareSheet(file, title: title, iconName: iconName, from: presenter)
    }
}

/// A file shared under a title and icon. The sheet's header shows them (what
/// a `ShareLink`'s `SharePreview` showed), and every destination receives the
/// file itself, so apps that open its type (Strava, Garmin Connect,
/// TrainingPeaks for GPX and TCX) are offered as before.
final class ShareFileItem: NSObject, UIActivityItemSource {
    private let file: URL
    private let title: String
    private let iconName: String?

    init(file: URL, title: String, iconName: String?) {
        self.file = file
        self.title = title
        self.iconName = iconName
        super.init()
    }

    func activityViewControllerPlaceholderItem(_: UIActivityViewController) -> Any {
        file
    }

    func activityViewController(_: UIActivityViewController, itemForActivityType _: UIActivity.ActivityType?) -> Any? {
        file
    }

    func activityViewControllerLinkMetadata(_: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        if let iconName, let icon = UIImage(systemName: iconName) {
            metadata.iconProvider = NSItemProvider(object: icon)
        }
        return metadata
    }
}
