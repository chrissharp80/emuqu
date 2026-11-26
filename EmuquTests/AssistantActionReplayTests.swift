//
//  AssistantActionReplayTests.swift
//  EmuquTests
//
//  A turn that changed something is not replayed on another model, the same
//  email is staged once per turn, and the chat's archive observer goes with it.
//

@testable import Emuqu
import os
import XCTest

// MARK: - Actions are not replayed

/// A turn that changed something is not started over on another model, and
/// the same email draft is not staged twice in one turn.
@MainActor
final class ActionReplayTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActionReplayTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // swallow-ok: the folder is temporary and may never have been created.
            }
        }
        return directory
    }

    private func makeViewModel() -> AssistantViewModel {
        let directory = temporaryDirectory()
        return AssistantViewModel(
            services: ChatServices(.current),
            store: ConversationStore(fileURL: directory.appendingPathComponent("conversation.json")),
            factsStore: UserFactsStore(fileURL: directory.appendingPathComponent("user_facts.json"))
        )
    }

    /// A fallback that staged an email and then finished with no text ends
    /// the chain: the next fallback, which starts the turn over, never runs,
    /// and the reply says what happened instead of vanishing.
    func testAFallbackThatRanAnActionAndWroteNoReplyEndsTheChain() async {
        let viewModel = makeViewModel()
        let reply = ChatTurn(role: .assistant, text: "")
        viewModel.turns = [ChatTurn(role: .user, text: "Email me today's recovery report"), reply]
        let composes = ToolRunCounter()
        let registry = FactResolverRegistry()
        registry.register(CountingEmailNamespace(counter: composes))
        let compose: AIStreamEvent = .toolUse(id: "1", name: "assistant_email_compose", inputJSON: "{}")
        let first = ScriptedRoundsProvider(id: .apple, rounds: [[compose, .done], [.done]], requests: RequestCounter())
        let next = ScriptedRoundsProvider(id: .apple, rounds: [[compose, .done], [.textDelta("Done."), .done]], requests: RequestCounter())

        let ending = await viewModel.tools.tryFallbacks(
            [(first, AppleFoundationProvider.model), (next, AppleFoundationProvider.model)], outbound: viewModel.turns,
            tools: viewModel.factRegistryAndTools().1, factRegistry: registry, turnID: reply.id, voiceMode: false
        )

        XCTAssertEqual(next.requests.count, 0, "the turn was started over after it ran an action")
        XCTAssertEqual(composes.runs, 1, "the action ran twice")
        XCTAssertNotEqual(ending, .failed)
        XCTAssertFalse(viewModel.turns.last?.text.isEmpty ?? true, "the reply does not say what happened")
    }

    /// The same draft asked for twice in one turn opens one composer.
    func testTheSameDraftIsStagedOnceInATurn() async throws {
        let directory = temporaryDirectory()
        let viewModel = makeViewModel()
        viewModel.turns = [ChatTurn(role: .user, text: "Email me today's recovery report")]
        let dependencies = AppDependencies()
        dependencies.overrides.assistantViewModel = viewModel
        let installed = AppDependencies.install(dependencies)
        defer { installed.end() }
        let bridge = FactServices(.current).assistantEmailBridge
        bridge.clear()
        defer { bridge.clear() }
        let router = CompactToolRouter(registry: AppFactResolverFactory.build(
            archive: SessionArchive(directory: directory), settings: { UserSettings() }, services: FactServices(.current)
        ))
        let args = #"{"subject":"Recovery \#(UUID().uuidString)","body":"HRV 52 ms","to":"me@example.com","user_quote":"Email me today's recovery report"}"#

        let first = await router.resolveTool(name: "assistant_email_compose", argsJSON: args)
        let staged = try XCTUnwrap(bridge.pendingDraft)
        let second = await router.resolveTool(name: "assistant_email_compose", argsJSON: args)

        guard case let .record(firstRecord) = first, case .string("staged") = firstRecord["status"] else { return XCTFail("not staged: \(first)") }
        guard case let .record(secondRecord) = second, case .string("already_staged") = secondRecord["status"] else {
            return XCTFail("staged again: \(second)")
        }
        XCTAssertEqual(bridge.pendingDraft?.id, staged.id, "a second composer was raised for the same draft")

        bridge.beginTurn()
        let nextTurn = await router.resolveTool(name: "assistant_email_compose", argsJSON: args)
        guard case let .record(nextRecord) = nextTurn, case .string("staged") = nextRecord["status"] else {
            return XCTFail("a new turn could not stage the email again: \(nextTurn)")
        }
        XCTAssertNotEqual(bridge.pendingDraft?.id, staged.id)
    }
}

// MARK: - View model lifetime

@MainActor
final class AssistantViewModelLifetimeTests: XCTestCase {
    /// The archive observer invalidates the cached fact registry while the
    /// view model lives, and is removed from the notification center with it.
    func testTheArchiveObserverIsRemovedWithTheViewModel() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssistantViewModelLifetimeTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // swallow-ok: the folder is temporary and may never have been created.
            }
        }
        let center = RemovalCountingCenter()
        var viewModel: AssistantViewModel? = AssistantViewModel(
            services: ChatServices(.current),
            store: ConversationStore(fileURL: directory.appendingPathComponent("conversation.json")),
            factsStore: UserFactsStore(fileURL: directory.appendingPathComponent("user_facts.json")),
            notificationCenter: center
        )
        _ = viewModel?.factRegistryAndTools()
        center.post(name: .flowRecoveryArchiveChanged, object: nil)
        let deadline = Date().addingTimeInterval(5)
        while viewModel?.cachedFactRegistry != nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(viewModel?.cachedFactRegistry, "an archive change did not reach the view model")

        viewModel = nil

        XCTAssertEqual(center.removals, 1, "the archive observer outlived the view model")
    }
}

/// A notification center that counts `removeObserver` calls. Swift requires
/// a subclass to restate `NotificationCenter`'s own `@unchecked Sendable`;
/// the only state added is the lock-held count.
private final class RemovalCountingCenter: NotificationCenter, @unchecked Sendable {
    private let removed = OSAllocatedUnfairLock(initialState: 0)
    var removals: Int { removed.withLock { $0 } }

    override func removeObserver(_ observer: Any) {
        removed.withLock { $0 += 1 }
        super.removeObserver(observer)
    }
}

/// `assistant_email_compose`, counting its runs instead of staging a draft.
private struct CountingEmailNamespace: FactNamespaceResolver {
    let counter: ToolRunCounter
    var namespace: String { "assistant" }

    var entries: [FactEntry] {
        let counter = counter
        return [.actionAsync(key: "assistant.email.compose", description: "test", parameters: []) { _ in counter.run() }]
    }
}
