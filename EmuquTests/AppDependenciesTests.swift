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
        let box = RecorderBox(services: WorkoutServices(.current))
        let dependencies = AppDependencies()
        dependencies.overrides.recorderBox = box

        let installed = AppDependencies.install(dependencies)
        XCTAssertTrue(AppDependencies.current.app.recorderBox === box, "The installed container is not in force")
        installed.end()

        XCTAssertFalse(AppDependencies.current.app.recorderBox === box, "Ending the scope left the container in force")
    }

    /// Ending an inner scope restores the outer container, not the live one.
    func testScopesRestoreTheContainerThatWasInForceBeforeThem() {
        let outerBox = RecorderBox(services: WorkoutServices(.current))
        let outer = AppDependencies()
        outer.overrides.recorderBox = outerBox
        let outerScope = AppDependencies.install(outer)
        defer { outerScope.end() }

        let inner = AppDependencies()
        inner.overrides.recorderBox = RecorderBox(services: WorkoutServices(.current))
        AppDependencies.install(inner).end()

        XCTAssertTrue(AppDependencies.current.app.recorderBox === outerBox, "The inner scope did not restore the outer container")
    }

    /// The app's sync manager is built over the app's archive; a container
    /// that substitutes the archive gets one built over that archive, the
    /// same one on every read, with its bookkeeping beside that archive.
    func testTheCloudManagerActsOnTheArchiveTheContainerSubstitutes() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = SessionArchive(directory: directory)
        let dependencies = AppDependencies()
        dependencies.overrides.sessionArchive = archive

        let manager = dependencies.storage.cloudKitSyncManager
        XCTAssertTrue(manager.archive === archive, "the cloud manager acts on the app's archive, not the container's")
        XCTAssertTrue(dependencies.storage.cloudKitSyncManager === manager, "each read built another manager")
        XCTAssertTrue(dependencies.storage.sessionDeletion.cloudKit.archive === archive, "a deletion acts on two archives")
    }

    /// A container that substitutes the archive and the settings hands out
    /// a context source over that archive and those settings, the same one
    /// on every read and the one the chat it serves reads, so the assistant's
    /// nested services come from the same container as its direct ones.
    func testTheContextSourceReadsTheArchiveAndSettingsTheContainerSubstitutes() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archive = SessionArchive(directory: directory)
        let settings = SettingsManager(settingsURL: directory.appendingPathComponent("user_settings.json"))
        addTeardownBlock { @MainActor in
            _ = settings.flushPendingWritesSynchronously()
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // swallow-ok: the folder is temporary and may never have been created.
            }
        }
        let dependencies = AppDependencies()
        dependencies.overrides.sessionArchive = archive
        dependencies.overrides.settingsManager = settings

        let source = dependencies.assistant.assistantContextSource
        XCTAssertTrue(source.services.sessionArchive === archive, "the context source reads the app's archive, not the container's")
        XCTAssertTrue(source.services.settingsManager === settings, "the context source reads the app's settings, not the container's")
        XCTAssertTrue(dependencies.assistant.assistantContextSource === source, "each read built another source")
        XCTAssertTrue(ChatServices(dependencies).assistantContextSource === source, "the chat reads another container's source")
    }

    func testLaunchServicesResolveTheContainersSubstitutes() {
        let box = RecorderBox(services: WorkoutServices(.current))
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
