import SwiftUI
import UIKit

// Share plumbing for the recap card, shared by the Dashboard chip and the
// Recovery-score detail screen. Both need the same three steps — name the
// PNG, walk to the topmost presenter, present the activity sheet — and
// separate copies drift.

/// Share filename. Sharing a `UIImage` directly makes iOS
/// auto-name the attachment "Image" or "IMG_XXXX.png", which looks awful when
/// posted to Instagram/Strava. Write the PNG to a temp file with a meaningful
/// name first, then share the URL — receivers (Photos, Files, Mail, Strava) all
/// use the file's base name as the attachment label.
///
/// Falls back to the raw image if the temp-file write fails (sandboxed-disk-full
/// edge case): the filename goes generic but the share doesn't fail outright.
func recapActivityItem(image: UIImage, score: Int, date: Date) -> Any {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    let stem = "flow-recovery-\(df.string(from: date))-score-\(score)"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(stem).png")
    guard let pngData = image.pngData(), attempt("share.png.write", { try pngData.write(to: url) }) != nil else {
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

@MainActor
func presentShareSheet(activityItem: Any, from presenter: UIViewController) {
    let activityVC = UIActivityViewController(activityItems: [activityItem], applicationActivities: nil)
    // iPad popover anchor — without this, presenting on iPad crashes.
    if let popover = activityVC.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
    }
    presenter.present(activityVC, animated: true)
}
