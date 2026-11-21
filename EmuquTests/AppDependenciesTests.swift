@testable import Emuqu
import XCTest

/// The composition root's test seam and the dependency sets it hands out.
///
/// `AppDependencies.current` has no setter: a test puts a container in force
/// only through `install(_:)`, and the scope it returns puts the previous one
/// back. The launch work and the data purge take resolvers from the root
/// (`launchServices`, `purgeStores`), which must reach a substitute set on
/// the container's `overrides`.
@MainActor
final class AppDependenciesTests: XCTestCase {
    func testAnInstalledContainerIsInForceUntilItsScopeEnds() {
        let box = RecorderBox()
        let dependencies = AppDependencies()
        dependencies.overrides.recorderBox = box

        let installed = AppDependencies.install(dependencies)
        XCTAssertTrue(AppDependencies.current.app.recorderBox === box, "The installed container is not in force")
        installed.end()

        XCTAssertFalse(AppDependencies.current.app.recorderBox === box, "Ending the scope left the container in force")
    }

    /// Ending an inner scope restores the outer container, not the live one.
    func testScopesRestoreTheContainerThatWasInForceBeforeThem() {
        let outerBox = RecorderBox()
        let outer = AppDependencies()
        outer.overrides.recorderBox = outerBox
        let outerScope = AppDependencies.install(outer)
        defer { outerScope.end() }

        let inner = AppDependencies()
        inner.overrides.recorderBox = RecorderBox()
        AppDependencies.install(inner).end()

        XCTAssertTrue(AppDependencies.current.app.recorderBox === outerBox, "The inner scope did not restore the outer container")
    }

    func testLaunchServicesResolveTheContainersSubstitutes() {
        let box = RecorderBox()
        let dependencies = AppDependencies()
        dependencies.overrides.recorderBox = box

        XCTAssertTrue(dependencies.launchServices.recorderBox() === box)
    }

    func testPurgeStoresResolveTheContainersSubstitutes() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDependenciesTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                // swallow-ok: the folder is temporary and may never have been created.
            }
        }
        let facts = UserFactsStore(fileURL: root.appendingPathComponent("user_facts.json"))
        let trails = BreadcrumbStore(fileURL: root.appendingPathComponent("Breadcrumbs/active.json"))
        let dependencies = AppDependencies()
        dependencies.overrides.userFactsStore = facts
        dependencies.overrides.breadcrumbStore = trails

        let stores = dependencies.purgeStores
        XCTAssertTrue(stores.assistant.userFactsStore() === facts)
        XCTAssertTrue(stores.location.breadcrumbStore() === trails)
    }
}
