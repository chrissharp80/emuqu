import Foundation

/// Runs a cloud provider's request and closes its stream. Anthropic, Gemini
/// and the OpenAI-compatible streamer (OpenAI, Grok, DeepSeek) all build
/// their streams here, so a failure means the same thing whichever model
/// answered.
///
/// The chat layer acts only on `AIProviderError`: `.network` is
/// fallbackable, so an offline turn moves on to the next model in the
/// chain (on-device Apple included), and `.cancelled` is the user's Stop,
/// which is not shown as a failure. A raw `URLError` reaching the chat layer
/// would show the system's text, skip the fallback, and show Stop as an
/// error.
enum ProviderStream {
    typealias Continuation = AsyncThrowingStream<AIStreamEvent, Error>.Continuation

    /// A stream whose events come from `operation`. The operation runs in a
    /// task that is cancelled when the consumer stops listening. The stream
    /// finishes normally when the operation returns, or with
    /// `failure(from:)` of what it threw.
    static func make(
        _ operation: @escaping @Sendable (Continuation) async throws -> Void
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await run(operation, continuation: continuation) }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Runs `operation` and closes `continuation` exactly once.
    static func run(
        _ operation: @Sendable (Continuation) async throws -> Void,
        continuation: Continuation
    ) async {
        do {
            try await operation(continuation)
            continuation.finish()
        } catch {
            continuation.finish(throwing: failure(from: error))
        }
    }

    /// The error the chat layer receives for what a provider request threw.
    /// Task cancellation and a cancelled URL load become `.cancelled`; every
    /// other `URLError` (offline, timed out, connection lost) becomes
    /// `.network`; anything else, `AIProviderError` included, is unchanged.
    static func failure(from error: Error) -> Error {
        switch error {
        case is CancellationError:
            AIProviderError.cancelled
        case let urlError as URLError where urlError.code == .cancelled:
            AIProviderError.cancelled
        case let urlError as URLError:
            AIProviderError.network(urlError.localizedDescription)
        default:
            error
        }
    }
}
