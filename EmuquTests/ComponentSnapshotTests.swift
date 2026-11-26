@testable import Emuqu
import SwiftUI
import XCTest

/// Snapshot coverage for self-contained view components.
///
/// These take plain values rather than environment objects, which makes them
/// cheap to pin and means a change to any of them is caught by a test rather
/// than by someone opening the screen.
///
/// Several are states a user only reaches when something has gone wrong — a
/// device with unrecovered data on it, a fetch that is retrying. Those are
/// exactly the screens least likely to be checked by hand and most costly to
/// render broken, because the user is already in trouble when they see them.
@MainActor
final class ComponentSnapshotTests: XCTestCase {
    // MARK: - Feeling badges

    func testMorningFeelingBadgeRenders() {
        assertSnapshot(of: MorningFeelingBadge(feeling: 4), named: "badge-morning-feeling")
    }

    func testWorkoutFeelingBadgeWithNoteRenders() {
        assertSnapshot(
            of: WorkoutFeelingBadge(feeling: 3, note: "Legs heavy on the climb"),
            named: "badge-workout-feeling"
        )
    }

    func testWorkoutFeelingBadgeWithoutNoteRenders() {
        assertSnapshot(
            of: WorkoutFeelingBadge(feeling: 5, note: nil),
            named: "badge-workout-feeling-no-note"
        )
    }

    // MARK: - Device recovery
    //
    // The user sees these after a session that did not come back cleanly.

    func testRecoverableDataCardRenders() {
        assertSnapshot(
            of: RecoverableDataCard(
                deviceName: "Polar H10 9BC21F2A",
                onRecover: {},
                onDiscard: {}
            ),
            named: "card-recoverable-data"
        )
    }

    func testFetchProgressCardMidDownloadRenders() {
        assertSnapshot(
            of: FetchProgressCard(
                progress: PolarManager.FetchProgress(
                    stage: .fetchingData, progress: 0.45,
                    attempt: 1, maxAttempts: 3,
                    statusMessage: "Downloading from device..."
                ),
                deviceName: "Polar H10 9BC21F2A",
                onCancel: {}
            ),
            named: "card-fetch-progress"
        )
    }

    /// The retry state renders a different message — "(attempt 2/3)" — and is
    /// the one a user hits when their strap is misbehaving.
    func testFetchProgressCardRetryingRenders() {
        assertSnapshot(
            of: FetchProgressCard(
                progress: PolarManager.FetchProgress(
                    stage: .retrying, progress: 0.2,
                    attempt: 2, maxAttempts: 3,
                    statusMessage: "Retrying..."
                ),
                deviceName: "Polar H10 9BC21F2A",
                onCancel: {}
            ),
            named: "card-fetch-progress-retry"
        )
    }

    // Not snapshot-tested: the Training Load screen. The layout includes system navigation
    // chrome (large titles, sheet bars, the tab bar) that settles at different
    // offsets with timing, the content is static or covered by the component
    // snapshots, and the behaviour is covered by unit and UI tests.
}

/// The harness itself: a UIKit-backed view renders as itself, and the
/// placeholder `ImageRenderer` draws for such a view is recognised and refused.
@MainActor
final class SnapshotHarnessTests: XCTestCase {
    /// Scroll content in a navigation stack: the shape most screens have, and
    /// one `ImageRenderer` cannot draw.
    private var uikitBacked: some View {
        NavigationStack {
            ScrollView {
                Text(verbatim: "Snapshot harness").font(.largeTitle)
                Color.blue.frame(height: 120)
            }
            .navigationTitle(Text(verbatim: "Harness"))
        }
    }

    func testAUIKitBackedViewRendersAsItselfNotThePlaceholder() throws {
        let shot = try XCTUnwrap(SnapshotTesting.render(uikitBacked))
        XCTAssertFalse(SnapshotTesting.isBlank(shot.pixels), "the view drew nothing")
        XCTAssertFalse(
            SnapshotTesting.isUnsupportedPlaceholder(shot.pixels, width: shot.width),
            "the harness drew the unsupported-content placeholder instead of the view"
        )
    }

    func testImageRenderersPlaceholderIsRecognised() throws {
        let renderer = ImageRenderer(content: uikitBacked.frame(width: 402, height: 874))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let shot = try XCTUnwrap(SnapshotTesting.rgba(image))
        XCTAssertFalse(SnapshotTesting.isBlank(shot.pixels), "the placeholder is not one colour, so isBlank alone passes it")
        XCTAssertTrue(
            SnapshotTesting.isUnsupportedPlaceholder(shot.pixels, width: shot.width),
            "ImageRenderer's placeholder for a navigation stack was not recognised"
        )
    }

    /// The placeholder in place of one small subview (a spinner in a card)
    /// is caught too, not only one covering the whole capture.
    func testASubviewSizedPlaceholderIsRecognised() throws {
        let card = HStack {
            Text(verbatim: "Downloading")
            Spacer()
            ProgressView()
        }
        .padding()
        let renderer = ImageRenderer(content: card.frame(width: 402, height: 200))
        renderer.scale = 1
        let shot = try XCTUnwrap(SnapshotTesting.rgba(XCTUnwrap(renderer.cgImage)))
        XCTAssertTrue(
            SnapshotTesting.isUnsupportedPlaceholder(shot.pixels, width: shot.width),
            "ImageRenderer's placeholder for a spinner was not recognised"
        )
    }

    /// A screen with a yellow badge and red text is not the placeholder.
    func testARealScreenWithYellowAndRedIsNotThePlaceholder() throws {
        let view = VStack(spacing: 24) {
            Capsule().fill(Color(.systemYellow)).frame(width: 160, height: 40)
            Text(verbatim: "Low recovery").font(.title).foregroundStyle(Color(.systemRed))
            Capsule().fill(Color(.systemYellow)).frame(width: 80, height: 40)
        }
        let shot = try XCTUnwrap(SnapshotTesting.render(view))
        XCTAssertFalse(SnapshotTesting.isUnsupportedPlaceholder(shot.pixels, width: shot.width))
    }
}
