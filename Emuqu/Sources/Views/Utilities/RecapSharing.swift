import SwiftUI
import UIKit

// Share plumbing for the recap card, shared by the Dashboard chip and the
// Recovery-score detail screen. Both need the same three steps — name the
// PNG, walk to the topmost presenter, present the activity sheet — and
// separate copies drift. Export files shared once (`FileShareButton`) are
// presented the same way (`presentFileShareSheet`).

/// Share filename. Sharing a `UIImage` directly makes iOS
/// auto-name the attachment "Image" or "IMG_XXXX.png", which looks awful when
/// posted to Instagram/Strava. Write the PNG to a temp file with a meaningful
/// name first, then share the URL — receivers (Photos, Files, Mail, Strava) all
/// use the file's base name as the attachment label.
///
/// The PNG carries the user's score, so it is written to `recapShareDirectory`
/// and `presentShareSheet` deletes it when the sheet closes, rather than
/// leaving it in tmp until iOS purges it.
///
/// Falls back to the raw image if the temp-file write fails (sandboxed-disk-full
/// edge case): the filename goes generic but the share doesn't fail outright.
func recapActivityItem(image: UIImage, score: Int, date: Date) -> Any {
    // Machine format: POSIX locale and Gregorian calendar, so the name reads
    // 2026-… on every device calendar.
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.calendar = Calendar(identifier: .gregorian)
    df.dateFormat = "yyyy-MM-dd"
    let stem = "emuqu-\(df.string(from: date))-score-\(score)"
    let url = recapShareDirectory.appendingPathComponent("\(stem).png")
    guard let pngData = image.pngData(),
          attempt("share.png.dir", { try FileManager.default.createDirectory(at: recapShareDirectory, withIntermediateDirectories: true) }) != nil,
          attempt("share.png.write", { try pngData.write(to: url) }) != nil else {
        return image
    }
    return url
}

/// Present from the TOPMOST view controller, not root. Otherwise the user hits
/// "Attempt to present UIActivityViewController on UIHostingController which is
/// already presenting PresentationHostingController" — root was already showing
/// a SwiftUI sheet (mail composer / PDF preview / etc.) and iOS rejects
/// double-presentation. Walk the chain.
@MainActor
func topmostPresenter() -> UIViewController? {
    guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
          let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
          ?? scene.windows.first?.rootViewController
    else { return nil }
    var presenter: UIViewController = root
    while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
        presenter = presented
    }
    return presenter
}

/// The temporary folder recap PNGs are shared from. Only files in it are
/// deleted after sharing; any other URL (a PDF the preview still shows) is
/// left alone.
private let recapShareDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("RecapShare", isDirectory: true)

/// The item's file URL when it is a recap PNG written by `recapActivityItem`.
private func recapShareFile(_ activityItem: Any) -> URL? {
    guard let url = activityItem as? URL, url.isFileURL else { return nil }
    let folder = url.deletingLastPathComponent().standardizedFileURL
    return folder == recapShareDirectory.standardizedFileURL ? url : nil
}

/// A share-sheet completion that runs `shareSheetClosed`.
private func closingHandler(
    removing file: URL?, onClosed: (@MainActor @Sendable () -> Void)?
) -> UIActivityViewController.CompletionWithItemsHandler {
    { _, _, _, _ in shareSheetClosed(removing: file, onClosed: onClosed) }
}

/// The share sheet closed: deletes `file`, when given, logging a failed
/// delete, then runs `onClosed` (UIKit calls the completion on the main
/// thread).
private func shareSheetClosed(removing file: URL?, onClosed: (@MainActor @Sendable () -> Void)?) {
    if let file {
        _ = attempt("share.file.remove") { try FileManager.default.removeItem(at: file) }
    }
    guard let onClosed else { return }
    MainActor.assumeIsolated { onClosed() }
}

/// Shares `activityItem` from `presenter`. A recap PNG is deleted once the
/// sheet closes, whether the user shared it or cancelled.
@MainActor
func presentShareSheet(activityItem: Any, from presenter: UIViewController) {
    let activityVC = UIActivityViewController(activityItems: [activityItem], applicationActivities: nil)
    activityVC.completionWithItemsHandler = recapShareFile(activityItem).map { closingHandler(removing: $0, onClosed: nil) }
    presentActivitySheet(activityVC, from: presenter)
}

/// Shares `file`, written for this one share, from `presenter`, and deletes
/// it once the sheet closes, whether the user shared it or cancelled; then
/// `onClosed` runs. With a `title` the sheet's header shows it and the
/// `iconName` symbol (`ShareFileItem`); without one it shows the file's name.
@MainActor
func presentFileShareSheet(
    _ file: URL, title: String?, iconName: String? = nil, from presenter: UIViewController,
    onClosed: (@MainActor @Sendable () -> Void)? = nil
) {
    let item: Any = title.map { ShareFileItem(file: file, title: $0, iconName: iconName) } ?? file
    let activityVC = UIActivityViewController(activityItems: [item], applicationActivities: nil)
    activityVC.completionWithItemsHandler = closingHandler(removing: file, onClosed: onClosed)
    presentActivitySheet(activityVC, from: presenter)
}

/// Presents `activityVC` from `presenter`, anchored for iPad.
@MainActor
private func presentActivitySheet(_ activityVC: UIActivityViewController, from presenter: UIViewController) {
    // iPad popover anchor — without this, presenting on iPad crashes.
    if let popover = activityVC.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
    }
    presenter.present(activityVC, animated: true)
}
