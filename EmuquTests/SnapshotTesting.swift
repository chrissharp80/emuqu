@testable import Emuqu
import SwiftUI
import UIKit
import XCTest

/// A self-contained snapshot harness for the SwiftUI layer.
///
/// Why this exists. The view layer is ~70,000 lines at 3.82% line
/// coverage, because a `some View` body is opaque and cannot be asserted on
/// directly. That hole is not academic: a view can be restructured with
/// nothing standing behind it but a hand-driven simulator session.
///
/// Written in-repo rather than adding `swift-snapshot-testing`. This app ships
/// a no-phone-home gate, a privacy manifest, an SBOM and a hand-maintained
/// attribution list; a test-only dependency would churn all of them, and the
/// mechanism below — render deterministically, compare to a committed
/// reference — is small enough to own.
///
/// What it catches: a view that renders differently than it used to. That is
/// exactly the regression class an extraction or a refactor risks, and exactly
/// what unit tests cannot see.
///
/// Recording: set `SNAPSHOT_RECORD=1` in the environment to (re)write
/// references instead of asserting. A recorded test always fails, so a
/// recording run can never be mistaken for a passing one.
enum SnapshotTesting {
    /// Fixed device geometry so a reference is reproducible across machines.
    /// iPhone 17 points, matching the CI simulator.
    static let defaultSize = CGSize(width: 402, height: 874)

    /// Rendering at 1x keeps references small and diffable; a scale change
    /// would invalidate every reference at once, so it is pinned here.
    static let scale: CGFloat = 1

    /// Per-pixel channel tolerance. Text antialiasing differs by a hair
    /// between OS point releases; an exact-match assert would make this
    /// harness flaky, and a flaky gate is one people disable.
    static let channelTolerance = 8

    /// Pixels allowed to exceed `channelTolerance` before a snapshot is
    /// considered changed: a fixed count, whatever the view's size.
    ///
    /// A share of the drawn pixels (2 % was used) scaled the allowance with
    /// the view: a full screen drawing 50,000 pixels let about 1,000 change,
    /// more than a recovery score going from "72" to "27" or a reworded line
    /// changes at 1x, so value and copy regressions on large screens passed;
    /// a small badge drawing 437 was allowed 8, few enough to fail on a stray
    /// pixel. In the committed references one character of text is 30 to 50
    /// pixels past the channel tolerance (measured on `badge-morning-feeling`
    /// and `chip-hrv`), so 24 lets through a few stray pixels and no changed
    /// glyph. Antialiasing that moves by a hair stays inside
    /// `channelTolerance` and is not counted at all.
    static let maxChangedPixels = 24

    /// The time zone every reference was recorded in. A view that shows a
    /// clock time or an hour axis (the sleep hypnogram) would otherwise
    /// render the fixture's instants in the host's zone, so a reference
    /// recorded in Chicago would fail on a UTC runner.
    static let timeZone = TimeZone(identifier: "America/Chicago") ?? .gmt
}

// MARK: - Rendering

extension SnapshotTesting {
    /// Render a view to raw RGBA bytes at a fixed size and scale, in light
    /// mode with the en_US locale and in `timeZone`, whatever the host is set
    /// to: references are recorded that way. The process default zone is
    /// switched for the render too (and restored after it), because views
    /// format times through `Calendar.current` and `DateFormatter`, which
    /// read it rather than the SwiftUI environment.
    ///
    /// The view is drawn the way the app draws it: hosted in a
    /// `UIHostingController` that is the root of a real `UIWindow` of exactly
    /// `size`, laid out, and captured with `drawHierarchy(in:afterScreenUpdates:)`.
    /// `ImageRenderer` is not used: it draws a yellow field with a red
    /// prohibition sign in place of anything UIKit-backed (`NavigationStack`,
    /// `ScrollView`, `List`, `Map`, some charts), so a screen built from those
    /// renders as that sign and its test compares the sign with itself. A
    /// hosting view's layer rendered without a window draws a flat colour.
    /// `isBlank` and `isUnsupportedPlaceholder` below refuse both captures.
    @MainActor
    static func render(
        _ view: some View,
        size: CGSize = defaultSize
    ) -> (pixels: [UInt8], width: Int, height: Int)? {
        let hostTimeZone = NSTimeZone.default
        NSTimeZone.default = timeZone
        defer { NSTimeZone.default = hostTimeZone }
        // UIKit animations stay off from building the window to the capture,
        // so views UIKit sets up are placed at once; animations added to
        // layers directly are removed before each capture (`finishAnimations`).
        let animated = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        let isolated = isolatedDependencies()
        let installed = AppDependencies.install(isolated.dependencies)
        let window = SnapshotWindow(size: size)
        let previousKey = window.windowScene?.keyWindow
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKey()
            installed.end()
            isolated.discard()
            UIView.setAnimationsEnabled(animated)
        }
        let pinnedView = pinned(view, size: size).environment(\.dependencies, isolated.dependencies)
        window.rootViewController = UIHostingController(rootView: pinnedView)
        window.makeKeyAndVisible()
        guard let image = settle(window) else { return nil }
        return rgba(image)
    }

    /// A container over empty stores of the render's own (settings on
    /// fresh-install defaults, an empty archive, baseline and training-load
    /// cache in a temporary folder), put in force and in the environment for the render. A view
    /// rendered in a window runs its `onAppear` and `task` and reads the
    /// archive and settings it finds; without this it would draw whatever the
    /// simulator running the tests holds, which differs by machine and run.
    @MainActor
    static func isolatedDependencies() -> (dependencies: AppDependencies, discard: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Snapshot-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsManager(settingsURL: directory.appendingPathComponent("user_settings.json"))
        let dependencies = AppDependencies()
        dependencies.overrides.settingsManager = settings
        dependencies.overrides.baselineTracker = BaselineTracker(baselineFile: directory.appendingPathComponent("HRVBaseline.json"))
        dependencies.overrides.archiveSignal = ArchiveSignal()
        // Apple Intelligence as ready: the coach otherwise shows whatever the
        // host's model is doing (ready, downloading, off), which changes
        // between runs on the same machine. Set before the registry is built,
        // which reads it once.
        dependencies.overrides.appleIntelligenceStatus = .available
        dependencies.overrides.providerRegistry = ProviderRegistry(services: ProviderRegistryServices(dependencies))
        let archive = SessionArchive(directory: directory)
        dependencies.overrides.sessionArchive = archive
        dependencies.overrides.trainingMetricsCache = TrainingMetricsCache(
            archive: { archive }, settings: { settings.settings },
            persistenceURL: directory.appendingPathComponent("TrainingMetricsCache.json")
        )
        return (dependencies, {
            _ = settings.flushPendingWritesSynchronously()
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // swallow-ok: the folder is temporary and may never have been created.
            }
        })
    }

    /// The view at `size` with every environment value a render depends on
    /// fixed, so the host's settings never reach a reference. Reduce Motion
    /// is on: the app's views then skip their reveal, digit-roll and
    /// breathing animations and draw their final state, which is the state a
    /// reference should hold (the setter is the underscored one; the public
    /// property is read-only).
    private static func pinned(_ view: some View, size: CGSize) -> some View {
        view
            .frame(width: size.width, height: size.height)
            .background(Color(.systemBackground))
            .environment(\.colorScheme, .light)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.timeZone, timeZone)
            .environment(\.layoutDirection, .leftToRight)
            .dynamicTypeSize(.large)
            .environment(\._accessibilityReduceMotion, true)
    }

    /// How long the run loop turns before the first capture, so `onAppear`,
    /// `task`, a `NavigationStack`'s hosted root and the reveals a screen
    /// schedules on appear (the dashboard's is 0.6 s) have all run.
    static let settleInterval: TimeInterval = 1.0

    /// After `settleInterval` the window is captured every `stableInterval`
    /// until two captures in a row match, and at most `settleChecks` times:
    /// the capture kept is a frame that has stopped changing.
    static let stableInterval: TimeInterval = 0.25
    static let settleChecks = 8

    @MainActor
    private static func settle(_ window: UIWindow) -> CGImage? {
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settleInterval))
        var previous = restingCapture(window)
        for _ in 0 ..< settleChecks {
            RunLoop.main.run(until: Date().addingTimeInterval(stableInterval))
            let next = restingCapture(window)
            if let next, let previous, sameBytes(next, previous) { return next }
            previous = next
        }
        return previous
    }

    /// The window as a screen opens: every vertically scrolling view at its
    /// top, and the layout that follows from that done, then captured.
    ///
    /// A large navigation title sets the scroll view's top inset once the bar
    /// has measured itself, and whether that lands before or after the scroll
    /// view first places its content depends on how busy the host is; a late
    /// inset leaves the content a few points scrolled, with the title part
    /// collapsed. Putting each scroll view back at its top before every
    /// capture makes the picture the same however the layout passes fell.
    @MainActor
    private static func restingCapture(_ window: UIWindow) -> CGImage? {
        scrollToTop(window)
        window.layoutIfNeeded()
        finishAnimations(window.layer)
        return capture(window)
    }

    /// Removes every Core Animation animation in the window, so each layer is
    /// drawn at its own final value. UIKit and SwiftUI add some animations
    /// directly to layers, outside `UIView.setAnimationsEnabled` (the tab
    /// bar's selection highlight fading in, a `ProgressView` spinner turning);
    /// captured mid-flight, those differ from run to run with the host's load.
    @MainActor
    private static func finishAnimations(_ layer: CALayer) {
        layer.removeAllAnimations()
        layer.sublayers?.forEach(finishAnimations)
    }

    /// Scroll views that scroll sideways (a strip wider than its frame) keep
    /// their position: only the vertical offset is reset.
    @MainActor
    private static func scrollToTop(_ view: UIView) {
        if let scroll = view as? UIScrollView, scroll.contentSize.width <= scroll.bounds.width + 0.5 {
            let top = CGPoint(x: scroll.contentOffset.x, y: -scroll.adjustedContentInset.top)
            if scroll.contentOffset != top { scroll.setContentOffset(top, animated: false) }
        }
        view.subviews.forEach(scrollToTop)
    }

    private static func sameBytes(_ lhs: CGImage, _ rhs: CGImage) -> Bool {
        guard let left = lhs.dataProvider?.data, let right = rhs.dataProvider?.data else { return false }
        return (left as Data) == (right as Data)
    }

    /// The window's on-screen contents at `scale`, in the sRGB range.
    @MainActor
    private static func capture(_ window: UIWindow) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        var drew = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            drew = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return drew ? image.cgImage : nil
    }

    /// `image` as premultiplied sRGB RGBA bytes, row by row from the top.
    static func rgba(_ image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let drew: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drew ? (pixels, width, height) : nil
    }

    /// True when every pixel is the same colour.
    ///
    /// A uniform capture means the view did not draw — a broken harness, a view
    /// that needs data it was not given, or a layout that collapsed to zero.
    /// Recording one as a reference creates a test that can never fail, so this
    /// is checked before a reference is ever written.
    static func isBlank(_ pixels: [UInt8]) -> Bool {
        guard pixels.count >= 8 else { return true }
        let r = pixels[0], g = pixels[1], b = pixels[2], a = pixels[3]
        var i = 4
        while i < pixels.count {
            if pixels[i] != r || pixels[i + 1] != g
                || pixels[i + 2] != b || pixels[i + 3] != a { return false }
            i += 4
        }
        return true
    }
}

/// The window a snapshot is drawn in: `size` points, light, left to right,
/// at `SnapshotTesting.scale`, with no safe area. Without the override the
/// insets would be the simulator's notch and home indicator, which differ by
/// device, so a reference would hold whichever device recorded it.
@MainActor
final class SnapshotWindow: UIWindow {
    override var safeAreaInsets: UIEdgeInsets { .zero }

    init(size: CGSize) {
        let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first
        if let scene {
            super.init(windowScene: scene)
        } else {
            super.init(frame: .zero)
        }
        frame = CGRect(origin: .zero, size: size)
        overrideUserInterfaceStyle = .light
        traitOverrides.userInterfaceStyle = .light
        traitOverrides.layoutDirection = .leftToRight
        traitOverrides.displayScale = SnapshotTesting.scale
        traitOverrides.preferredContentSizeCategory = .large
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

// MARK: - The unsupported-content placeholder

extension SnapshotTesting {
    /// The two colours of the placeholder `ImageRenderer` draws for content
    /// it cannot render: a systemYellow field and a systemRed prohibition sign.
    static let placeholderYellow: (UInt8, UInt8, UInt8) = (255, 204, 0)
    static let placeholderRed: (UInt8, UInt8, UInt8) = (255, 56, 60)

    /// True when the capture holds that placeholder, whole or in place of a
    /// subview as small as a spinner: some connected run of placeholder
    /// yellow encloses a rectangle of at least 100 pixels whose four corners
    /// are that yellow and which is at least 40 % yellow, 8 % red and 65 %
    /// the two together (the rest is the sign's antialiased edge). A real
    /// screen's yellow is a rounded badge or a chart line, never a square
    /// field with a red sign inside it.
    static func isUnsupportedPlaceholder(_ pixels: [UInt8], width: Int) -> Bool {
        guard width > 0, pixels.count >= width * 4 else { return false }
        return PlaceholderScan(pixels, width: width).containsPlaceholder()
    }

    /// Whether the pixel at byte offset `i` is `colour` within `channelTolerance`.
    static func matches(_ colour: (UInt8, UInt8, UInt8), _ pixels: [UInt8], at i: Int) -> Bool {
        abs(Int(pixels[i]) - Int(colour.0)) <= channelTolerance
            && abs(Int(pixels[i + 1]) - Int(colour.1)) <= channelTolerance
            && abs(Int(pixels[i + 2]) - Int(colour.2)) <= channelTolerance
    }
}

/// The search behind `SnapshotTesting.isUnsupportedPlaceholder`: each
/// connected region of placeholder yellow, and the rectangle around it.
struct PlaceholderScan {
    /// A pixel rectangle, inclusive at both ends.
    struct Box {
        var minX: Int, minY: Int, maxX: Int, maxY: Int
        var area: Int { (maxX - minX + 1) * (maxY - minY + 1) }

        mutating func include(_ x: Int, _ y: Int) {
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }

    let width: Int
    private let yellow: [Bool]
    private let red: [Bool]

    init(_ pixels: [UInt8], width: Int) {
        self.width = width
        yellow = Self.mask(pixels, SnapshotTesting.placeholderYellow)
        red = Self.mask(pixels, SnapshotTesting.placeholderRed)
    }

    private static func mask(_ pixels: [UInt8], _ colour: (UInt8, UInt8, UInt8)) -> [Bool] {
        stride(from: 0, to: pixels.count - 3, by: 4).map { SnapshotTesting.matches(colour, pixels, at: $0) }
    }

    func containsPlaceholder() -> Bool {
        var seen = [Bool](repeating: false, count: yellow.count)
        for start in yellow.indices where yellow[start] && !seen[start] {
            if looksLikePlaceholder(region(from: start, seen: &seen)) { return true }
        }
        return false
    }

    /// The rectangle around the yellow region `start` belongs to, marking
    /// each of its pixels seen.
    private func region(from start: Int, seen: inout [Bool]) -> Box {
        var box = Box(minX: start % width, minY: start / width, maxX: start % width, maxY: start / width)
        var stack = [start]
        seen[start] = true
        while let p = stack.popLast() {
            box.include(p % width, p / width)
            for q in neighbours(of: p) where yellow[q] && !seen[q] {
                seen[q] = true
                stack.append(q)
            }
        }
        return box
    }

    private func neighbours(of p: Int) -> [Int] {
        let x = p % width
        return [x > 0 ? p - 1 : -1, x < width - 1 ? p + 1 : -1, p - width, p + width]
            .filter { $0 >= 0 && $0 < yellow.count }
    }

    private func looksLikePlaceholder(_ box: Box) -> Bool {
        let area = box.area
        let corners = [(box.minX, box.minY), (box.maxX, box.minY), (box.minX, box.maxY), (box.maxX, box.maxY)]
        guard area >= 100, corners.allSatisfy({ yellow[$0.1 * width + $0.0] }) else { return false }
        var yellowCount = 0, redCount = 0
        for y in box.minY ... box.maxY {
            let row = y * width
            yellowCount += yellow[(row + box.minX) ... (row + box.maxX)].filter { $0 }.count
            redCount += red[(row + box.minX) ... (row + box.maxX)].filter { $0 }.count
        }
        return yellowCount * 10 >= area * 4 && redCount * 100 >= area * 8 && (yellowCount + redCount) * 100 >= area * 65
    }
}

extension SnapshotTesting {
    /// Why a capture can never be a reference, or nil when it can.
    ///
    /// A uniform image is a harness or fixture failure, and the
    /// unsupported-content placeholder is a renderer failure; neither is the
    /// view. Refused before recording or comparing, so neither can be
    /// recorded and then pass forever against itself.
    static func refusal(of pixels: [UInt8], width: Int, size: CGSize) -> String? {
        if isBlank(pixels) {
            return "rendered a single flat colour: the view drew nothing. Check the fixture "
                + "supplies the data the view needs, and that the view has a non-zero layout at "
                + "\(Int(size.width))x\(Int(size.height))."
        }
        if isUnsupportedPlaceholder(pixels, width: width) {
            return "rendered the unsupported-content placeholder (a yellow field with a red "
                + "prohibition sign) instead of the view."
        }
        return nil
    }
}

// MARK: - Comparison

extension SnapshotTesting {
    struct Difference {
        let changedPixels: Int
        let drawnPixels: Int
        let totalPixels: Int
        /// Changed pixels as a share of the pixels the reference actually
        /// draws, so the threshold means the same thing on a small card as on
        /// a full screen.
        var fraction: Double {
            drawnPixels == 0 ? 0 : Double(changedPixels) / Double(drawnPixels)
        }
    }

    /// Count pixels in `reference` that differ from its most common colour —
    /// i.e. everything that is not flat background.
    static func drawnCount(_ pixels: [UInt8]) -> Int {
        var counts: [UInt32: Int] = [:]
        var i = 0
        while i < pixels.count {
            let key = UInt32(pixels[i]) << 24 | UInt32(pixels[i + 1]) << 16
                | UInt32(pixels[i + 2]) << 8 | UInt32(pixels[i + 3])
            counts[key, default: 0] += 1
            i += 4
        }
        let total = pixels.count / 4
        let background = counts.values.max() ?? total
        return total - background
    }

    /// Compare two RGBA buffers channel-by-channel.
    ///
    /// Returns nil when the buffers are not the same shape — a size change is
    /// always a real difference, never something tolerance should absorb.
    static func compare(_ lhs: [UInt8], _ rhs: [UInt8]) -> Difference? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var changed = 0
        var i = 0
        while i < lhs.count {
            let dr = abs(Int(lhs[i]) - Int(rhs[i]))
            let dg = abs(Int(lhs[i + 1]) - Int(rhs[i + 1]))
            let db = abs(Int(lhs[i + 2]) - Int(rhs[i + 2]))
            let da = abs(Int(lhs[i + 3]) - Int(rhs[i + 3]))
            if max(max(dr, dg), max(db, da)) > channelTolerance { changed += 1 }
            i += 4
        }
        return Difference(
            changedPixels: changed,
            drawnPixels: drawnCount(lhs),
            totalPixels: lhs.count / 4
        )
    }
}

// MARK: - Renders kept for inspection

extension SnapshotTesting {
    /// Where a render that did not match, or was recorded, is written as a
    /// reference file would hold it: the `SNAPSHOT_RENDER_DIR` directory, when
    /// the run sets one. CI sets it (as `TEST_RUNNER_SNAPSHOT_RENDER_DIR`) and
    /// uploads the folder, so the render of a failed snapshot can be looked at,
    /// and once checked against the intended change, committed as its new
    /// reference. Without the variable nothing is written.
    static var renderDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["SNAPSHOT_RENDER_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Write `bytes` (a reference file's contents) to `renderDirectory` as
    /// `<name>.raw`. A failed write is reported in the log and changes no
    /// result: the snapshot has already failed for its own reason.
    static func keepRender(_ bytes: Data, named name: String) {
        guard let dir = renderDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try bytes.write(to: dir.appendingPathComponent("\(name).raw"))
        } catch {
            print("snapshot '\(name)': could not keep the render in \(dir.path): \(error)")
        }
    }
}

// MARK: - The assertion

extension XCTestCase {
    /// Assert a view renders the same as its committed reference.
    ///
    /// References live in `EmuquTests/__Snapshots__/<name>.raw` (raw RGBA plus
    /// a small header). Raw rather than PNG so the comparison is over exactly
    /// the bytes rendered, with no encoder version in the path.
    @MainActor
    func assertSnapshot(
        of view: some View,
        named name: String,
        size: CGSize = SnapshotTesting.defaultSize,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Copy comes from `LanguageManager.appBundle`, which the SwiftUI
        // environment does not reach; references hold the English copy.
        pinEnglishLanguage()
        guard let shot = SnapshotTesting.render(view, size: size) else {
            XCTFail("snapshot '\(name)': view failed to render", file: file, line: line)
            return
        }
        if let refusal = SnapshotTesting.refusal(of: shot.pixels, width: shot.width, size: size) {
            XCTFail("snapshot '\(name)': \(refusal)", file: file, line: line)
            return
        }

        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__")
        let ref = dir.appendingPathComponent("\(name).raw")

        // Stored gzipped: a raw 402x874 frame is 1.4 MB, and a repo does not
        // need that per snapshot. Only the decompressed bytes are ever
        // compared, so a compressor difference between OS versions cannot
        // change a result.
        guard let squeezed = try? (Data(shot.pixels) as NSData)
            .compressed(using: .zlib) else {
            XCTFail("snapshot '\(name)': could not compress render",
                    file: file, line: line)
            return
        }
        var header = Data("\(shot.width)x\(shot.height)\n".utf8)
        header.append(squeezed as Data)

        let recording = ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] == "1"

        guard !recording, FileManager.default.fileExists(atPath: ref.path) else {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
            do {
                try header.write(to: ref)
            } catch {
                XCTFail("snapshot '\(name)': could not write reference: \(error)",
                        file: file, line: line)
                return
            }
            SnapshotTesting.keepRender(header, named: name)
            // Recording is never a pass. A run that wrote its own expectations
            // has verified nothing, and must not report success.
            XCTFail(
                "snapshot '\(name)': reference recorded at \(ref.lastPathComponent). "
                + "Inspect it, commit it, and re-run without SNAPSHOT_RECORD.",
                file: file, line: line
            )
            return
        }

        guard let stored = try? Data(contentsOf: ref) else {
            XCTFail("snapshot '\(name)': reference unreadable", file: file, line: line)
            return
        }
        guard let nl = stored.firstIndex(of: 0x0A) else {
            XCTFail("snapshot '\(name)': reference malformed", file: file, line: line)
            return
        }
        let dims = String(data: stored[..<nl], encoding: .utf8) ?? ""
        let expectedDims = "\(shot.width)x\(shot.height)"
        guard dims == expectedDims else {
            SnapshotTesting.keepRender(header, named: name)
            XCTFail(
                "snapshot '\(name)': size changed — reference is \(dims), "
                + "rendered \(expectedDims)",
                file: file, line: line
            )
            return
        }

        let body = stored[stored.index(after: nl)...]
        guard let raw = try? (Data(body) as NSData).decompressed(using: .zlib) else {
            XCTFail("snapshot '\(name)': reference could not be decompressed",
                    file: file, line: line)
            return
        }
        let refPixels = [UInt8](raw as Data)
        guard !SnapshotTesting.isUnsupportedPlaceholder(refPixels, width: shot.width) else {
            XCTFail(
                "snapshot '\(name)': the committed reference is the unsupported-content "
                + "placeholder, not a render of the view. Re-record it with SNAPSHOT_RECORD=1.",
                file: file, line: line
            )
            return
        }
        guard let diff = SnapshotTesting.compare(refPixels, shot.pixels) else {
            XCTFail("snapshot '\(name)': buffers not comparable", file: file, line: line)
            return
        }
        if diff.changedPixels > SnapshotTesting.maxChangedPixels {
            SnapshotTesting.keepRender(header, named: name)
            let pct = String(format: "%.2f%%", diff.fraction * 100)
            XCTFail(
                "snapshot '\(name)': \(diff.changedPixels) pixels changed, "
                + "\(pct) of the \(diff.drawnPixels) this view draws (tolerance "
                + "\(SnapshotTesting.maxChangedPixels) pixels). If the change "
                + "is intended, re-record with SNAPSHOT_RECORD=1 and commit the "
                + "new reference.",
                file: file, line: line
            )
        }
    }
}
