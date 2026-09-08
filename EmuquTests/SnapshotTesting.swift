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

    /// Fraction of *drawn* pixels allowed to exceed `channelTolerance` before
    /// a snapshot is considered changed.
    ///
    /// Measured against drawn pixels, not the whole canvas. A card occupies
    /// ~1% of a 402x874 frame, so a whole-canvas tolerance of even 0.2% would
    /// absorb a change to a fifth of the card and report it as unchanged — a
    /// gate loose enough to miss what it exists to catch.
    static let drawnFractionTolerance = 0.02
}

// MARK: - Rendering

extension SnapshotTesting {
    /// Render a view to raw RGBA bytes at a fixed size and scale.
    ///
    /// `ImageRenderer`, not `UIHostingController.layer.render(in:)`. The first
    /// version of this harness used the hosting-view layer and produced five
    /// references that were a single flat colour — SwiftUI does not draw
    /// through that path without a live window, so every "passing" snapshot
    /// would have been a blank rectangle compared against a blank rectangle.
    /// `isBlank` below exists so that cannot recur silently.
    @MainActor
    static func render(
        _ view: some View,
        size: CGSize = defaultSize
    ) -> (pixels: [UInt8], width: Int, height: Int)? {
        let renderer = ImageRenderer(
            content: view
                .frame(width: size.width, height: size.height)
                .background(Color(.systemBackground))
        )
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        guard let cg = renderer.cgImage else { return nil }

        let width = cg.width
        let height = cg.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let drew: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: info
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        return (pixels, width, height)
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
        guard let shot = SnapshotTesting.render(view, size: size) else {
            XCTFail("snapshot '\(name)': view failed to render", file: file, line: line)
            return
        }
        // A uniform image is a harness or fixture failure, never a valid
        // reference. Caught here so it can never be recorded and then pass
        // forever against itself.
        guard !SnapshotTesting.isBlank(shot.pixels) else {
            XCTFail(
                "snapshot '\(name)': rendered a single flat colour — the view drew "
                + "nothing. Check the fixture supplies the data the view needs, and "
                + "that the view has a non-zero layout at \(Int(size.width))x"
                + "\(Int(size.height)).",
                file: file, line: line
            )
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
        guard let diff = SnapshotTesting.compare(refPixels, shot.pixels) else {
            XCTFail("snapshot '\(name)': buffers not comparable", file: file, line: line)
            return
        }
        if diff.fraction > SnapshotTesting.drawnFractionTolerance {
            let pct = String(format: "%.2f%%", diff.fraction * 100)
            XCTFail(
                "snapshot '\(name)': \(diff.changedPixels) pixels changed, "
                + "\(pct) of the \(diff.drawnPixels) this view draws (tolerance "
                + "\(SnapshotTesting.drawnFractionTolerance * 100)%). If the change "
                + "is intended, re-record with SNAPSHOT_RECORD=1 and commit the "
                + "new reference.",
                file: file, line: line
            )
        }
    }
}
