import Foundation
#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Apple Intelligence `Tool` protocol adapter.
///
/// Without it, `AppleFoundationProvider.send(...)` would have to discard
/// its `[ToolSpec]` array and Apple Intelligence would have zero tool
/// support — it could only answer from the static context block. Asking
/// "email me today's recovery report" routed to Apple → Apple says
/// "I don't have email" → the user sees a denial of a feature the
/// app actually has.
///
/// What this file does. Provides an Apple `Tool` protocol adapter
/// that wraps a `ToolSpec` + handler pair into something
/// `LanguageModelSession(tools:)` accepts. The wrapper takes a
/// single `String` argument (the JSON-encoded args object the model
/// would have sent over the wire to a cloud provider), hands it to
/// the existing tool handler, and returns the resolved value as a
/// string the model can read back.
///
/// **Why a single-string Generable.** Apple's `@Generable` macro
/// generates a tool-args schema at compile time from a Swift struct.
/// To get type-safe per-tool argument structs we'd need ~25
/// `@Generable struct Arguments { … }` declarations, one per tool —
/// substantial code with a maintenance burden every time a tool's
/// schema changes. The single-string adapter trades that off: Apple's
/// model has to emit valid JSON for the args (which it does
/// reliably on tool calls per WWDC25 session 248), we parse it
/// inside the handler. Slightly weaker than full type-safety, but
/// one adapter for the entire catalog and zero ongoing maintenance.
///
/// **Activation status.** Wired behind `#if canImport(FoundationModels)`
/// + `#available(iOS 26, *)` — same gate as the existing
/// `AppleFoundationProvider`. On older iOS the symbol simply doesn't
/// exist; the provider falls through to its toolless code
/// path. The adapter is live — `AppleFoundationProvider` maps the
/// passed `[ToolSpec]` into `AppleToolAdapter`s and threads them into
/// `LanguageModelSession(tools:)` via its session cache. An empty tool
/// array still yields toolless mode (existing behaviour preserved).
#if canImport(FoundationModels)
    @available(iOS 26, *)
    struct AppleToolAdapter: Tool {
        /// The wrapped tool's name. Forwarded to Apple's `Tool` protocol.
        let name: String

        /// The wrapped tool's description (the prompt the model sees
        /// when deciding whether to call the tool).
        let description: String

        /// The handler that resolves the tool. Takes the model's
        /// JSON args string, returns a string the model will read
        /// back. Implementation lives in `AppFactResolver` (for fact
        /// catalog lookups) or `CompactToolRouter` (for actions).
        let handler: @Sendable (String) async throws -> String

        /// Arguments struct exposed to Apple's generation pipeline.
        /// Single field — the JSON-encoded args the model produces.
        @Generable
        struct Arguments {
            /// JSON object with the tool's input args (e.g.
            /// `{"date":"yyyy-mm-dd","metric":"rmssd"}`). The model
            /// generates this string conforming to the tool's
            /// declared schema, which we expose via the `description`
            /// field along with example shapes.
            @Guide(description: "JSON object with the tool's arguments. Must be valid JSON matching the tool's documented schema.")
            let argumentsJSON: String
        }

        /// Apple invokes this when the model calls the tool.
        /// `Output = String` because `String` conforms to
        /// `PromptRepresentable`, satisfying the protocol without
        /// a separate `ToolOutput` wrapper.
        ///
        /// `Transcript.ToolOutput` (an inner type with id /
        /// toolName / segments) is used elsewhere in the
        /// FoundationModels API; the `Tool` protocol's `Output`
        /// associated type is wider — anything conforming to
        /// `PromptRepresentable` works, and `String` is the
        /// simplest valid choice.
        func call(arguments: Arguments) async throws -> String {
            try await handler(arguments.argumentsJSON)
        }
    }

    /// Build an array of Apple-compatible tools from the cross-provider
    /// `[ToolSpec]` catalog + per-tool handler map. Returns nil when
    /// FoundationModels isn't available (iOS < 26) so the caller can
    /// fall through to the existing toolless code path.
    @available(iOS 26, *)
    enum AppleToolCatalog {
        /// Convert a `ToolSpec` + handler into an Apple `Tool` instance.
        /// The handler signature matches what `OpenAICompatibleStreamer`,
        /// `AnthropicProvider`, and `GeminiProvider` already invoke
        /// — JSON-string in, string out — so wiring is one line per
        /// tool at the registration site (no per-tool arg-struct
        /// definitions required).
        static func wrap(
            _ spec: ToolSpec,
            handler: @escaping @Sendable (String) async throws -> String
        ) -> any Tool {
            AppleToolAdapter(
                name: spec.name,
                description: enrichedDescription(for: spec),
                handler: handler
            )
        }

        /// Estimated tokens one tool adds to the session: its name and
        /// enriched description, plus a little framing overhead. Counted
        /// against Apple's 4K window alongside the instructions.
        static func estimatedTokens(for spec: ToolSpec) -> Int {
            AppleContextCompactor.estimateTokens(spec.name + enrichedDescription(for: spec)) + 10
        }

        /// Augments the tool's natural-language description with a
        /// compact form of the input schema so the model knows what
        /// JSON shape to emit. Apple's `Tool` protocol doesn't have
        /// a separate schema field — the Generable wrapper only
        /// describes the wrapper's own struct (one `String`). So
        /// the per-tool schema must be conveyed in the description.
        private static func enrichedDescription(for spec: ToolSpec) -> String {
            guard !spec.inputSchema.properties.isEmpty else {
                return spec.description + "\n\nThis tool takes no arguments — pass `{}` as argumentsJSON."
            }
            // Render the schema as a compact JSON example.
            var fields: [String] = []
            for (key, prop) in spec.inputSchema.properties.sorted(by: { $0.key < $1.key }) {
                let optional = !spec.inputSchema.required.contains(key)
                let suffix = optional ? " (optional)" : ""
                fields.append("\"\(key)\": <\(prop.type)\(suffix) — \(prop.description)>")
            }
            let schemaHint = "{\n  " + fields.joined(separator: ",\n  ") + "\n}"
            return spec.description + "\n\nargumentsJSON shape:\n\(schemaHint)"
        }
    }
#endif
