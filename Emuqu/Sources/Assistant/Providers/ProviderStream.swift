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

// MARK: - Opening a stream

extension ProviderHTTP {
    /// The streaming POST every cloud provider sends: JSON in, server-sent
    /// events out, with `headers` adding the vendor's key and version
    /// fields. The body is encoded with `.sortedKeys`: the vendors' prompt
    /// caches match on byte-identical prefixes, and a dictionary's order is
    /// not stable in Swift. Throws what encoding the body throws.
    static func streamRequest(
        url: URL,
        body: some Encodable,
        headers: [String: String]
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)
        return request
    }

    /// Sends `request` on `streamSession` and returns the reply's lines once
    /// the status is 2xx. A non-2xx reply throws `failure` of its status and
    /// the first 4 KB of its body (`errorBody`). A cancelled task throws
    /// `CancellationError` before the status is read.
    ///
    /// Consent and the provider's switch are read from `services` right
    /// before the connection opens, so they hold for every request and not
    /// only for the turn that started them: a summary, a tool round or a
    /// coach line sent after the user withdrew consent or switched the
    /// provider off throws `.consentWithdrawn` and sends nothing.
    ///
    /// The body goes to the prompt audit just before the connection opens,
    /// so the audit shows what was sent, byte for byte.
    static func openStream(
        _ request: URLRequest,
        provider: ProviderID,
        services: AIProviderServices,
        failure: (_ status: Int, _ body: Data) -> AIProviderError
    ) async throws -> AsyncLineSequence<URLSession.AsyncBytes> {
        try await requireConsent(for: provider, services: services)
        if let body = request.httpBody { ProviderRequestAudit.sentBodySink?(body) }
        let (bytes, response) = try await connect(request, provider: provider)
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            let body = try await errorBody(bytes)
            throw failure(http.statusCode, body)
        }
        return bytes.lines
    }

    /// Throws `.consentWithdrawn` when `provider` has no data-sharing
    /// consent now or is switched off.
    static func requireConsent(for provider: ProviderID, services: AIProviderServices) async throws {
        let allowed = await MainActor.run { services.maySend(to: provider) }
        guard !allowed else { return }
        debugLog("[AIStreamer] \(provider.rawValue) request not sent — no data-sharing consent, or switched off", level: .warning)
        throw AIProviderError.consentWithdrawn(provider)
    }

    /// Opens the connection on the dedicated session, so a cellular blip
    /// during a walk waits for connectivity instead of failing at once. A
    /// connect failure is logged with its `URLError` code before it is
    /// rethrown: timed out, cancelled, not connected and connection lost
    /// each have a different fix, and the code tells them apart.
    private static func connect(
        _ request: URLRequest,
        provider: ProviderID
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do {
            return try await streamSession.bytes(for: request)
        } catch let urlError as URLError {
            let detail = "code=\(urlError.code.rawValue) (\(urlError.localizedDescription))"
            debugLog("[AIStreamer] \(provider.rawValue) connect failed: \(detail)", level: .warning)
            throw urlError
        }
    }
}

// MARK: - Reply pieces every provider shares

extension ProviderHTTP {
    /// The error a provider endpoint that does not parse reports.
    static let badEndpoint = AIProviderError.invalidResponse("bad endpoint")

    /// The error a tool call whose arguments are not a whole JSON object
    /// ends the round with: they were cut or garbled, and running the tool on
    /// them would run it with default scope.
    static func incompleteArguments(toolName: String) -> AIProviderError {
        .invalidResponse("tool call \(toolName) arrived with incomplete arguments")
    }

    /// Yields one `.usage` event when at least one counter is non-zero, and
    /// nothing for an all-zero report.
    static func yieldUsage(
        input: Int,
        output: Int,
        cached: Int,
        cacheCreation: Int = 0,
        to continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation
    ) {
        guard input > 0 || output > 0 || cached > 0 || cacheCreation > 0 else { return }
        continuation.yield(.usage(
            inputTokens: input, outputTokens: output,
            cachedInputTokens: cached, cacheCreationInputTokens: cacheCreation
        ))
    }
}

// MARK: - Server-sent events

/// One server-sent event: its `data:` payload, trimmed, and the name the
/// `event:` line before it gave the event (nil when it had none).
struct SSEEvent: Equatable, Sendable {
    let name: String?
    let data: String
}

/// The events in a reply's lines, for every cloud provider. An event's
/// payload is its `data:` lines joined by newlines, so one JSON value written
/// across several lines arrives whole. It is complete once it holds a whole
/// JSON value (or `[DONE]`), at a blank line, or when the lines end: the line
/// reader in use may drop the blank lines, so the payload itself has to say
/// where it ends. A payload that never becomes whole is passed on as it is
/// at those points, or once it holds `maxPendingLines` lines, and the provider
/// reports it malformed. An `event:` line names the
/// events after it until a blank line; comments (`:` keep-alives) and other
/// lines are skipped. The task's cancellation is checked after every line
/// read, so Stop ends the read at the next line.
struct SSEEvents<Lines: AsyncSequence>: AsyncSequence where Lines.Element == String {
    typealias Element = SSEEvent

    let lines: Lines

    init(_ lines: Lines) {
        self.lines = lines
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(lines: lines.makeAsyncIterator())
    }

    struct Iterator: AsyncIteratorProtocol {
        var lines: Lines.AsyncIterator
        var eventName: String?
        /// The data lines of the event being read, not yet a whole value.
        var pending: [String] = []
        /// Lines a payload may hold before it is passed on unfinished, so a
        /// broken stream cannot grow it without bound.
        static var maxPendingLines: Int { 256 }

        /// The next event, nil when the lines end. Throws what reading a
        /// line throws, or `CancellationError` once the task is cancelled.
        mutating func next() async throws -> SSEEvent? {
            while let line = try await lines.next() {
                try Task.checkCancellation()
                if let completed = event(from: line) { return completed }
            }
            return takePending()
        }

        /// The event `line` completes, if any, keeping the current event
        /// name up to date: a blank line ends the event and clears it, an
        /// `event:` line sets it.
        private mutating func event(from line: String) -> SSEEvent? {
            if line.isEmpty {
                defer { eventName = nil }
                return takePending()
            }
            if line.hasPrefix("event:") {
                eventName = Self.value(of: line, after: "event:")
                return nil
            }
            guard line.hasPrefix("data:") else { return nil }
            let payload = Self.value(of: line, after: "data:")
            return payload.isEmpty ? nil : event(adding: payload)
        }

        /// Adds one data line's payload to the event being read.
        private mutating func event(adding payload: String) -> SSEEvent? {
            pending.append(payload)
            let whole = Self.isWhole(pending.joined(separator: "\n"))
            return whole || pending.count >= Self.maxPendingLines ? takePending() : nil
        }

        /// The event being read, as it stands; nil when there is none.
        private mutating func takePending() -> SSEEvent? {
            guard !pending.isEmpty else { return nil }
            defer { pending.removeAll() }
            return SSEEvent(name: eventName, data: pending.joined(separator: "\n"))
        }

        /// Whether `payload` is a complete event: the `[DONE]` sentinel or one
        /// whole JSON value.
        private static func isWhole(_ payload: String) -> Bool {
            guard payload != "[DONE]" else { return true }
            do {
                _ = try JSONSerialization.jsonObject(with: Data(payload.utf8), options: .fragmentsAllowed)
                return true
            } catch {
                // swallow-ok: not a whole value yet is the answer, not a failure; the provider decodes the event itself.
                return false
            }
        }

        /// The text after a field's `prefix`, trimmed of spaces and tabs.
        private static func value(of line: String, after prefix: String) -> String {
            line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
    }
}
