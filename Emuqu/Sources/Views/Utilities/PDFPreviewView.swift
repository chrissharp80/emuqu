import QuickLook
import SwiftUI
import UIKit

/// QLPreviewController wrapper for PDF preview with share option
struct PDFPreviewView: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let previewController = QLPreviewController()
        previewController.dataSource = context.coordinator
        previewController.delegate = context.coordinator
        previewController.navigationItem.leftBarButtonItem = barButton(
            .done, action: #selector(Coordinator.doneAction), coordinator: context.coordinator
        )
        previewController.navigationItem.rightBarButtonItem = barButton(
            .action, action: #selector(Coordinator.shareAction), coordinator: context.coordinator
        )
        return UINavigationController(rootViewController: previewController)
    }

    /// Done dismisses; the action button opens the share sheet.
    private func barButton(_ item: UIBarButtonItem.SystemItem, action: Selector, coordinator: Coordinator) -> UIBarButtonItem {
        UIBarButtonItem(barButtonSystemItem: item, target: coordinator, action: action)
    }

    func updateUIViewController(_: UINavigationController, context _: Context) {}

    // `@preconcurrency`: QuickLook calls these on the main thread but the
    // protocols are not annotated, so the conformance is declared as such.
    @MainActor
    class Coordinator: NSObject, QLPreviewControllerDataSource, @preconcurrency QLPreviewControllerDelegate {
        let parent: PDFPreviewView

        init(parent: PDFPreviewView) {
            self.parent = parent
        }

        // MARK: - QLPreviewControllerDataSource

        func numberOfPreviewItems(in _: QLPreviewController) -> Int {
            1
        }

        func previewController(_: QLPreviewController, previewItemAt _: Int) -> QLPreviewItem {
            parent.url as QLPreviewItem
        }

        // MARK: - QLPreviewControllerDelegate

        func previewControllerDidDismiss(_: QLPreviewController) {
            parent.dismiss()
        }

        // MARK: - Actions

        @objc func doneAction() {
            parent.dismiss()
        }

        @objc func shareAction() {
            guard let presenter = topmostPresenter() else { return }
            presentShareSheet(activityItem: parent.url, from: presenter)
        }
    }
}
