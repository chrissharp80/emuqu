# Flo — AI Assistant Module Architecture

**Status:** authoritative spec, current as of 2026-05-08.
**Source-of-truth tree:** `Emuqu/Sources/Assistant/`
**Audience:** engineers porting this AI module into another iOS app.

This document describes the architecture of "Flo", the conversational AI assistant inside Emuqu. The goal is a **portable spec**: another team should be able to lift the module's structure into a non-fitness app with predictable changes only at the marked extension points.

Where a component is fitness-specific, this document marks it **APP-SPECIFIC** and explains how to replace it. Where a component is generic, it's marked **PORTABLE**.

> **Reading guide.** §1–§3 give you the system shape and end-to-end turn lifecycle. §4–§17 are reference material per component. §18 is the porting checklist.

---

## 1. What Flo Is

Flo is a multi-provider, multi-modal conversational AI module with these properties:

- **Six interchangeable providers** behind one protocol: Apple Intelligence (on-device, iOS 26+), Anthropic Claude, OpenAI, Google Gemini, xAI Grok, DeepSeek. Switching providers is a settings toggle; no code path knows which provider it's talking to.
- **Tool use across all six**, including Apple Intelligence (via iOS 26 `LanguageModelSession(tools:)`), unified through a single `FactRegistry` that returns typed `FactValue` envelopes.
- **Capability-aware tiered routing** — a user's complex question goes to a deep cloud model, a simple lookup stays on-device for free.
- **Structured tool catalog with availability metadata** — tools that can't return data (no archive, no permission) are stripped from the schema before the model sees them, so the model never asks for what it can't get.
- **Voice mode** — half-duplex SFSpeechRecognizer / WhisperKit STT + AVSpeechSynthesizer TTS with sentence-level streaming, hallucination guard, and pronunciation overrides.
- **Cross-turn memory** with per-user fact store and auto-extraction.
- **Cache-aware prompt composition** — Anthropic prompt cache hit ratio >80% on repeat conversations.
- **Deterministic shortcuts** — common voice utterances bypass the LLM entirely. $0 cost, <50ms latency. The "~30–50% of voice turns" rate cited in §3 below is a research-based estimate from linguistic analysis of common HRV/recovery utterance patterns; production telemetry that measures the actual bypass rate is not currently wired (only a debug log fires on hit at `AssistantViewModel.swift:428`).
- **Hallucination guard** — numeric claims in coach responses are verified against ground truth and silently corrected before TTS; prior-turn corrections feed forward into the next system prompt.
- **Per-provider PHI/PII consent gates** with versioned acknowledgement.

**Design principles:**
1. The model is one of multiple replaceable backends, not the load-bearing component.
2. Data never reaches a third party without explicit per-provider consent.
3. Every response can be audited offline (turn metadata stamped with provider, model, tier, subsystem).
4. Voice and text share the same dispatch loop and provider plumbing — voice is just `send(text:fromVoice: true)`.
5. Failure modes degrade gracefully (cache cold → cold fetch; quota exceeded → tier downgrade; provider down → fallback chain).

---

## 2. System Diagram

```
                              ┌─────────────────────┐
                              │   User input        │
                              │  (text or voice)    │
                              └──────────┬──────────┘
                                         │
                          ┌──────────────▼──────────────┐
                          │  VoiceConversationController│   (voice only)
                          │   STT → text + fromVoice    │
                          └──────────────┬──────────────┘
                                         │
                          ┌──────────────▼──────────────┐
                          │   AssistantViewModel.send() │
                          │  - MedicalQueryGuard        │
                          │  - ProviderConsentTracker   │
                          │  - DeterministicIntent      │  ← bypass on hit
                          │  - dispatch() → tool loop   │
                          └──────────────┬──────────────┘
                                         │
                          ┌──────────────▼──────────────┐
                          │   SmartProviderRouter       │
                          │   .quick / .auto / .deep    │
                          │   → (provider, model)       │
                          └──────────────┬──────────────┘
                                         │
                          ┌──────────────▼──────────────┐
                          │  AssistantSystemPrompt      │
                          │  (stable | variable split)  │
                          └──────────────┬──────────────┘
                                         │
                          ┌──────────────▼──────────────┐
                          │  AIProvider.send() stream   │
                          │  → AsyncThrowingStream      │
                          │   .textDelta                │
                          │   .toolUse                  │
                          │   .usage  / .done           │
                          └──────────────┬──────────────┘
                                         │
       ┌─────────────────────────────────┼─────────────────────────────┐
       │                                 │                             │
       ▼                                 ▼                             ▼
   tool_use:                       textDelta:                    .done:
   FactRegistry.resolveTool       accumulate into ChatTurn       MetricsVerifier
   → FactValue → JSON              VoiceConv chunks → TTS         CoachVoiceGuard
   → loop next round               PhoneticOverrides applied      Auto-extract facts
                                   TTSTextNormalizer applied      Persist conversation
```

Vertical lines are method calls. The horizontal split at the bottom shows what each kind of stream event does. The `tool_use` branch loops back to the provider with updated message history.

---

## 3. Turn Lifecycle (End-to-End)

A single user turn through the system. Code references are file:line.

### 3.1 Input arrival

**Text input** (e.g. user types in chat):
```swift
viewModel.send(text: trimmed, fromVoice: false)
```

**Voice input** (`VoiceConversationController.swift:44`):
1. User taps Talk; `startListening()` configures `AVAudioEngine` + `SFSpeechRecognizer` (or `WhisperKitSTTBridge`)
2. VAD detects speech end
3. Transcript dispatched: `viewModel.send(text: transcript, fromVoice: true)`

### 3.2 `AssistantViewModel.send(text:fromVoice:)` — gating

`AssistantViewModel.swift:326`. Sequence:

1. **Empty check** — return `.rejectedEmpty` for whitespace-only input
2. **MedicalQueryGuard** (line 350) — when `FeatureFlags.medicalGuardEnabled`, regex-match against AFib/arrhythmia/symptom triggers. On match, synthesize a local refusal turn and return `.dispatched` without an LLM call. (**APP-SPECIFIC**: regexes are health-domain.)
3. **Provider availability** (line 371) — return `.rejectedNoProvider` if active provider has no key
4. **ProviderConsentTracker** (line 381) — if active provider needs consent and it's not yet given, return `.requiresConsent(providerID)`. The host view presents a consent sheet; on accept, `acknowledgeConsentAndContinue()` re-issues the send.
5. **In-flight queueing** (line 392) — if a stream is running, queue the new send (latest-wins) and return `.queued`. `finishStream()` will drain.
6. **DeterministicIntent** (line 412–431, voice-only) — pattern-match against ~12–15 high-precision intents (recovery, sleep, RHR). On a match, synthesize a local assistant turn from cached facts and return `.dispatched` with no LLM call. (**APP-SPECIFIC**: pattern set.)
7. **Append user turn** (line 433) — `turns.append(ChatTurn(role: .user, text: trimmed))` and persist.
8. **Mark voice flag** (line 436) — `nextSendIsVoice = fromVoice` so router knows to apply voice-mode bypass.
9. **Apple prewarm** (line 444–448) — fire `AppleFoundationProvider.prewarm()` if Apple is in the routing path. Idempotent, detached.
10. **Call `dispatch()`** (line 450) — actual LLM dispatch.

### 3.3 `dispatch()` — provider selection & stream setup

`AssistantViewModel.dispatch()`. Sequence:

1. **`resolveProviderForThisTurn()`** (`AssistantViewModel+Routing.swift`) — calls `SmartProviderRouter` (§9) plus the voice-mode bypass in `TurnRouter` and an action-intent override. Returns `(provider, model, tier?)`.
2. **Reserve assistant turn** (line 857) — `turns.append(ChatTurn(role: .assistant, text: ""))` stamped with `providerID`, `modelID`, `subsystem: .coach`, `routedTierRaw: tier?.rawValue`. The streaming text accumulates here.
3. **`isStreaming = true`** (line 868)
4. **Cancel prior stream** (line 871) — `streamGeneration += 1` so any in-flight tokens from the previous turn are dropped on arrival
5. **Spawn streaming `Task`** (line 877). Inside:
   - Build `FactResolverRegistry` + tool `[ToolSpec]` (line 931): `factRegistryAndTools()`. Tools are filtered down to the provider's `maxToolSchemaCount` (Grok 4.1 Fast caps at 110, `GrokProvider.swift:71`).
   - Compose system prompt (line 968): `AssistantSystemPrompt.compose(...)` — passes `userFacts`, `priorSummary`, `contextRendered` (empty for tool-mode providers; full render for Apple), `voiceMode`, `toolMode`.
   - **Token-aware truncation** (line 899): `Self.truncateForSend(turns, provider: provider.id)` — drops oldest turns until under per-provider budget; survivors stamped `(kept, dropped)`.
   - **Truncation summary** (line 904): if turns dropped, async-call provider with summarization prompt → `priorSummary` becomes new content.
   - Call `runToolUseLoop(...)` (line 977).

### 3.4 `runToolUseLoop()` — multi-round tool dispatch

`AssistantViewModel+Tools.swift:42`. Each round:

1. Call `provider.send(messages:model:contextRendered:systemPrompt:tools:toolRounds:)` — returns `AsyncThrowingStream<AIStreamEvent, Error>`.
2. For each event:
   - `.textDelta(String)` → append to assistant turn's `.text`, throttled at 33ms via `flushPendingChunks` (line 104). Voice path also pipes to `SpokenTextChunker` for sentence-aligned TTS.
   - `.toolUse(id, name, inputJSON)` → push onto `pending` queue; loop continues to next event.
   - `.usage(input, output, cached, cacheCreate)` (line 175) → log hit ratio for telemetry.
   - `.done` → exit inner loop.
3. After stream drains, if `pending.isEmpty` → exit outer loop, return.
4. Else, for each pending tool_use:
   - Build `CompactToolRouter(registry:)` (line 250)
   - Call `router.resolveTool(name: pending.name, argsJSON: pending.inputJSON)` (line 251) → `FactValue`
   - Append `ToolExchange(toolUseID, toolName, inputJSON, resultJSON)` to current round's exchange list
5. Append round to `toolRounds` and recurse provider-call-with-tool-results.
6. Hard cap of **8 tool calls per turn** (`maxToolCallsPerTurn`, `AssistantViewModel+Tools.swift:33`) so a misbehaving model can't loop us indefinitely. Once the total would exceed 8, further calls get a synthetic `{"status":"missing"}` and the model gets one closing pass before force-exit. There is no separate "rounds" cap.

### 3.5 Stream completion side-effects

`AssistantViewModel`, stream-completion side effects:

1. Clear `AppleToolDispatcher.shared.setRegistry(nil)` so a `DataPurgeService` later can wipe cleanly.
2. Run `MetricsVerifier.verify(text, against: snapshot)` over the assistant turn's full text. Discrepancies are silently corrected in the spoken text and queued via `MetricsVerifier.recordCorrections(...)` for the NEXT turn's system prompt (§13).
3. Run `CoachVoiceGuard.scrub(...)` (**APP-SPECIFIC** — health rules). Modified text replaces turn's text.
4. Persist conversation: `store.save(turns)`.
5. If `userFactsAutoExtractEnabled`, fire `runAutoFactExtraction(userText:assistantText:)` to mine new memories.
6. Drain `pendingSendOnFinish` if a queued message is waiting.
7. `isStreaming = false`.

---

## 4. AssistantViewModel — Orchestrator

**File:** `Emuqu/Sources/Assistant/ViewModel/AssistantViewModel.swift:30`
**Isolation:** `@MainActor final class`
**Singleton:** `static let shared`

### Published state (consumed by SwiftUI views)

| Property | Type | Purpose |
|----------|------|---------|
| `turns` | `[ChatTurn]` | Conversation thread (line 35) |
| `isStreaming` | `Bool` | Spinner + input disable (line 36) |
| `errorMessage` | `String?` | Surface provider errors |
| `priorSummary` | `String?` | Summary of truncation-dropped turns |
| `pendingDraft` | `String?` | Pre-fill input from dashboard shortcuts |
| `speakableTextCursor` | `[UUID: Int]` | Voice TTS safety cursor per turn |
| `pendingConsentRequest` | `(provider, text, fromVoice)?` | Consent sheet trigger |
| `routingPaused` | `Bool` | Disable Smart routing for this turn |

### Public API

```swift
@MainActor public func send(text: String, fromVoice: Bool = false) -> SendOutcome
@MainActor public func send(prefab question: PrefabQuestion)
@MainActor public func acknowledgeConsentAndContinue() -> SendOutcome
@MainActor public func cancel()
@MainActor public func clearConversation()
@MainActor public func regenerateLast()
@MainActor public func invalidateContext()
```

**`SendOutcome`** enum:
- `.dispatched` — work submitted (LLM, deterministic, or local refusal)
- `.queued` — waiting on in-flight stream
- `.rejectedEmpty` — whitespace-only
- `.rejectedNoProvider` — no API key
- `.requiresConsent(ProviderID)` — host must show sheet

### Dispatch model

`AssistantViewModel` is `@MainActor` so its streaming `Task` inherits MainActor isolation. Tool resolvers run on MainActor by construction (see §6 on `MainActor.assumeIsolated`). This is load-bearing: many resolvers read `@Published` state from MainActor singletons and would trap if dispatched off-main.

If you need to run resolvers off-main (because some are async-heavy), the surgical change is to:
1. Replace `Task { ... }` in `dispatch()` with `Task.detached { ... }`
2. Replace every `MainActor.assumeIsolated` in resolvers with `await MainActor.run`
3. Audit blocking `DispatchSemaphore.wait(timeout:)` calls in fact resolvers — these are watchdog risks even on a non-main thread (see §6 on resolver budgets).

---

## 5. AIProvider Protocol & Provider Matrix

### 5.1 The protocol

**File:** `Emuqu/Sources/Assistant/Providers/AIProvider.swift:382`

```swift
protocol AIProvider {
    var id: ProviderID { get }
    var availableModels: [ModelOption] { get }
    var requiresKey: Bool { get }
    var isAvailable: Bool { get }
    var maxToolSchemaCount: Int? { get }            // nil = unlimited

    func send(
        messages: [ChatTurn],
        model: ModelOption,
        contextRendered: String,
        systemPrompt: String,
        tools: [ToolSpec],
        toolRounds: [[ToolExchange]]
    ) -> AsyncThrowingStream<AIStreamEvent, Error>
}
```

### 5.2 `AIStreamEvent` enum (line 247)

```swift
enum AIStreamEvent {
    case textDelta(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case usage(inputTokens: Int, outputTokens: Int,
               cachedInputTokens: Int, cacheCreationInputTokens: Int)
    case done
}
```

Providers emit `.toolUse` ONCE per fully-formed tool call (they accumulate deltas internally). The dispatch loop never sees partial tool_use.

### 5.3 `ProviderID` enum (line 5)

```swift
enum ProviderID: String, Codable, CaseIterable, Identifiable {
    case apple, anthropic, openai, gemini, grok, deepseek
}
```

### 5.4 `ModelOption` (line 69)

```swift
struct ModelOption: Codable, Hashable, Identifiable {
    let providerID: ProviderID
    let apiID: String              // wire identifier ("claude-opus-4-7")
    let displayName: String        // "Opus 4.7"
    let blurb: String              // "Fast & cheap", "Best reasoning", etc.
    let contextWindow: Int         // total tokens
    let inputPricePerMTok: Decimal?
    let outputPricePerMTok: Decimal?
    let isDefault: Bool
}
```

### 5.5 Provider matrix

| Provider | File | Streaming | Tool format | Caching | Notes |
|----------|------|-----------|-------------|---------|-------|
| Apple Foundation | `AppleFoundationProvider.swift` | iOS 26 `LanguageModelSession.streamResponse` | `Tool` protocol via `AppleToolDispatcher` (§16) | n/a (on-device) | Single model `apple.foundation.on-device`; ~4K context; free, private |
| Anthropic | `AnthropicProvider.swift:5` | Messages API SSE | `content_blocks` `tool_use` | **Prompt cache** with `cache_control: ephemeral` on stable prefix | 5-min TTL; hit ratio target >0.8 |
| OpenAI | `OpenAIProvider.swift` | Completions SSE | OpenAI function calling | `prompt_tokens_details.cached_tokens` | Shares `OpenAICompatibleStreamer` |
| Gemini | `GeminiProvider.swift` | URLSession `streamGenerateContent` SSE | JSON `functionCall` parts; omits `parameters` for no-arg tools | Implicit (Google-managed) | Empty `properties` object 400s on Gemini — no-arg tools drop `parameters` |
| Grok (xAI) | `GrokProvider.swift` | OpenAI-compatible | OpenAI function calling | None | `maxToolSchemaCount = 110` (Grok 4.1 Fast hard cap) |
| DeepSeek | `DeepSeekProvider.swift` | OpenAI-compatible | OpenAI function calling | `prompt_cache_hit_tokens` | |

### 5.6 Adding a provider

To add a 7th provider:

1. Create `Providers/MyProvider.swift` conforming to `AIProvider`.
2. Add a case to `ProviderID` enum and update its `Codable` synthesis.
3. Register in `ProviderRegistry` (single static array of providers).
4. Add API-key prompt UX (`AIAssistantSettingsPage` reads `APIKeyStore`).
5. Add to `ProviderConsentTracker.consentRequiredProviders` if it sends user data off-device.
6. Update `TierProviderMapper` so `SmartProviderRouter` knows where it sits in the tier hierarchy.

Tool schema translation is the only nuanced part. Anthropic `content_blocks` ≠ OpenAI `function`. Mostly the difference is wire format; the `[ToolSpec]` we hand to providers is provider-agnostic.

---

## 6. Fact / Tool System

This is the data-access layer. Everything an LLM can read or do is a fact (read) or action (write).

### 6.1 `FactValue` — universal return type

**File:** `Emuqu/Sources/Assistant/Facts/FactValue.swift:99`

```swift
indirect enum FactValue: Equatable, Codable {
    case integer(Int)
    case double(Double)
    case string(String)
    case date(Date)
    case durationSec(Int)
    case boolean(Bool)
    case missing(reason: MissingReason, detail: String?)
    case list([FactValue])
    case record([String: FactValue])

    var toolResultJSON: String { /* ... */ }
}
```

`MissingReason` (line 17):
- `.notRecorded` — archive has no data for this query
- `.notYetComputed` — still being calculated
- `.outOfRange` — parameter outside valid range
- `.sensorDropout` — signal too noisy
- `.invalidParameter` — bad tool arg
- `.internalError` — programmer bug
- `.tooMuchData` — composite blew size cap
- `.rateLimited` — same query asked 3+ times this turn
- `.partialData` — composite child mix-success-failure

The `.missing` case carries `detail: String?` so the LLM gets a human-readable hint ("no morning HRV reading yet today"). This is the difference between the model saying "I don't know" and the model saying "you haven't taken a reading yet."

### 6.2 `FactEntry` — declaration shapes

**File:** `Emuqu/Sources/Assistant/Facts/FactCatalog.swift:64`

```swift
indirect enum FactEntry {
    case fixed(
        key: String,
        description: String,
        valueType: String,
        availability: () -> Availability,
        resolve: () -> FactValue
    )

    case parameterized(
        pattern: String,                      // e.g. "session.by_date($date)"
        paramExample: String,
        description: String,
        availability: () -> Availability,
        resolve: (_ param: String, _ tail: FactKey?) -> FactValue
    )

    case composite(
        key: String,
        description: String,
        valueType: String,
        dependencies: [String],
        availability: () -> Availability,
        resolve: (_ registry: FactResolverRegistry) -> FactValue
    )

    case action(
        key: String,
        description: String,                  // MUST start "[ACTION]"
        parameters: [ActionParam],
        availability: () -> Availability,
        execute: (_ args: [String: String]) -> FactValue
    )
}
```

`ActionParam` (line 52):
```swift
struct ActionParam {
    let name: String
    let description: String
    let required: Bool
}
```

`Availability` (line 70):
```swift
struct Availability {
    var hasData: Bool
    var validRange: ClosedRange<Date>?
    var lastUpdated: Date?
}
```

The schema-builder walks all `FactEntry`s, calls `availability()` on each, and **drops entries where `hasData == false`** before showing the model. A workout fact that requires HR data is invisible to the model when the user isn't wearing a strap. Same for a meal fact when there's no nutrition integration. The LLM literally never sees the tool, can't ask for it, can't be wrong about it.

### 6.3 `CompactToolRouter` — polymorphism layer

**File:** `Emuqu/Sources/Assistant/Facts/CompactToolRouter.swift:28`

The fact catalog has 200+ entries. Showing all of them to the model is wasteful and confusing. `CompactToolRouter.schema(...)` collapses them into ~30 polymorphic tools by namespace + intent, plus the action allowlist:

```swift
let allowedActionNames: Set<String> = [
    "routes_library_rename",
    "routes_library_save_workout",
    "routes_library_engage",
    "assistant_contacts_add",
    "assistant_contacts_remove",
    "assistant_email_compose",
    "assistant_memory_add",
    "assistant_memory_remove",
    "assistant_memory_clear",
    "web_search",
    "location_current",
    "location_current_detailed",
    "location_situation",
    "location_set_address",
    "directions_routeTo",
    "directions_clear",
]
```

Read tools (e.g. `get_today`, `get_workout_live`, `get_session`, `get_recovery`, `lookup_fact`) translate the model's polymorphic call into a specific fact key by inspecting the args. E.g. `get_recovery({"which":"trend","period":"90d"})` → `recovery.trend(90d)` is the archive-backed "am I improving over time?" tool (returns improving/stable/declining + HRV & resting-HR slope; NOT strap-gated). `lookup_fact({"key": "training.load.tsb"})` is the universal fallback — the model can always name a key directly.

`schema(...)` deduplicates by tool name (defensive against double-registration in fact catalog).

### 6.4 `FactResolverRegistry` and namespace files

**File:** `Emuqu/Sources/Assistant/Facts/AppFactResolver.swift:85`

```swift
enum AppFactResolverFactory {
    static func build(
        archive: SessionArchive,
        settings: @escaping () -> UserSettings
    ) -> FactResolverRegistry
}
```

The factory registers namespace resolvers — each is a `struct: FactNamespaceResolver` with `var entries: [FactEntry]`. Namespaces:

- `UserProfileNamespace` — age, units, max HR, etc. **PORTABLE** with edits to fields.
- `AppCapabilitiesNamespace` — feature flags. **PORTABLE**.
- `SessionNamespace` — workout sessions. **APP-SPECIFIC**.
- `WalksNamespace` — pedestrian tracking. **APP-SPECIFIC**.
- `TrainingLoadNamespace` — ATL/CTL/TSB. **APP-SPECIFIC**.
- `SleepNamespace` — overnight HRV/sleep. **APP-SPECIFIC**.
- `RecoveryNamespace`, `HRVNamespace`, `VitalsNamespace`, `ScoreNamespace`, etc. **APP-SPECIFIC**.
- `RoutesNamespace`, `LocationNamespace`, `DirectionsNamespace` — **PORTABLE** in concept, edit specific entries to your needs.
- `AssistantMemoryNamespace` — bridges to `UserFactsStore`. **PORTABLE**.
- `WebSearchNamespace` — Tavily-backed web search. **PORTABLE**.

Resolver closures can use `MainActor.assumeIsolated { ... }` to read MainActor-bound singletons synchronously. This works because the dispatch loop runs on MainActor (see §4). If you move dispatch off-main, all 60+ `MainActor.assumeIsolated` blocks must change to `await MainActor.run`.

### 6.5 Resolver wall-clock budget

**File:** `Emuqu/Sources/Assistant/Facts/FactCatalog.swift` (`FactResolveTimeout.withTimeout(seconds:)`)

The registry instruments every action call:

```swift
let startedAt = Date()
let value = execute(parsedArgs)
let elapsed = Date().timeIntervalSince(startedAt)
if elapsed > Self.defaultResolveBudgetSec {  // 2.0
    debugLog("[FactRegistry] action \(name) exceeded \(budget)s budget — took \(elapsed)s", level: .warning)
}
if elapsed > Self.watchdogWarnSec {  // 4.0
    debugLog("[FactRegistry] ⚠️ WATCHDOG-WARN action \(name) blocked for \(elapsed)s — over the 4s ceiling that risks an iOS App Watchdog kill", level: .warning)
}
```

iOS App Watchdog kills foreground apps at ~10s of unresponsive main thread. Resolvers run on MainActor; any sync `DispatchSemaphore.wait(timeout:)` that exceeds ~4s is at real risk of triggering it. The `.action(...)` resolvers in this codebase wrap async work via semaphore + `Task.detached`; timeouts are kept ≤3s for that reason.

---

## 7. AssistantSystemPrompt — Cache-aware composition

**File:** `Emuqu/Sources/Assistant/Providers/AIProvider.swift:454`

The system prompt is split into a **stable prefix** (cacheable, ~5 minute TTL on Anthropic) and a **variable suffix** (per-send). The split makes a 0% → 80%+ Anthropic prompt cache hit ratio across repeat conversations.

### 7.1 `Composed` struct (line 459)

```swift
struct Composed {
    let stable: String        // sent first, marked cache_control=ephemeral
    let variable: String      // sent after; no cache control
    var combined: String { /* ... */ }
    var combinedWithMarker: String { /* with cacheSplitMarker between */ }
    static let cacheSplitMarker = "\n\n<<<__FLOW_CACHE_SPLIT__>>>\n\n"
}
```

Anthropic's provider splits on `cacheSplitMarker` to build cache-aware blocks. Other providers strip the marker (it's invisible) and send a single combined string.

### 7.2 Stable sections (composed in order)

1. **`base` constant** (line 830) — core persona, brevity rules, refusal rules. **APP-SPECIFIC**: rewrite for your domain.
2. **Language override** (line 534) — when `forceAIEnglish` setting is on.
3. **Locale + units directive** (line 545) — uses `UnitsPreferenceStore`. **APP-SPECIFIC** (rewrite for your unit system).
4. **Disabled features summary** (line 551) — toggle-driven feature list. **APP-SPECIFIC**.
5. **Tool overlay** (line 558) — when `toolMode: true`, redefines "data comes from tools, not text dump."
6. **Non-tool overlay** (line 572) — for providers without tool support, lists capabilities the user might want and how to enable them.
7. **Voice overlay** (line 579) — "1–3 sentences, no headers, no lists" override for `voiceMode: true`.
8. **App reference** (line 586) — `AppKnowledgeBase.reference` (full) or `.referenceCompact` (small-context). **APP-SPECIFIC**: rewrite for your app's features.
9. **User facts** (line 590) — cross-session memory block from `UserFactsStore.systemPromptBlock()`.

### 7.3 Variable sections (line 599+)

1. **`nowSnapshot()`** (line 793) — current time rounded to minute. Static for ~60 s so cache survives. Without this, every send was a cache miss because `\(Date())` changes per second.
2. **`activeWorkoutMarker()`** (line 771) — minimal marker that a workout is in flight. Volatile metrics pulled via tool, not inlined. **APP-SPECIFIC**.
3. **Hallucination corrections** (line 631) — `MetricsVerifier.consumePendingCorrectionsBlock()`. Last-turn numeric fabrications surface as "DO NOT FABRICATE" warning to next turn (§13).
4. **Prior summary** (line 634) — truncation-dropped turns rolled into one paragraph.
5. **Rendered context** (line 637) — `compactRender()` data dump for non-tool-using providers (currently just Apple). Tool-using providers get an empty string; they pull data via tools instead.

### 7.4 Cache hit math

For Anthropic with `cache_control: ephemeral`:
- Turn 1: cold cache, full prompt billed, `cache_creation_input_tokens` records the size.
- Turns 2+ within 5 min: stable prefix hits cache → `cached_input_tokens` near full size of stable; `input_tokens` is just the variable suffix + new user message.
- Hit ratio target >0.8. The variable-suffix order matters: anything that can stay stable (workout marker IF static) is in stable; per-second-volatile fields (like `\(Date())`) are in variable.

`LLMCacheTelemetry.shared.record(...)` (line 177 of `+Tools.swift`) tracks ratio across providers.

---

## 8. SmartProviderRouter — Tiered routing

**File:** `Emuqu/Sources/Assistant/Facts/SmartProviderRouter.swift:26`

### 8.1 Tier model

```swift
enum Tier: Int, Comparable { case quick = 1, auto = 2, deep = 3 }  // Comparable is load-bearing — stickiness uses > comparisons
```

- **`.quick`** — on-device (Apple Intelligence). Free, fast, private. Suitable for lookups, summaries, short acks.
- **`.auto`** — cheap cloud (Haiku 4.5 / Flash-Lite class). General coaching at modest depth.
- **`.deep`** — strongest cloud (Sonnet 4.6 / GPT-5.4 Pro / Gemini 3.1 Pro / Grok 4). Multi-week analysis, real reasoning.

### 8.2 `RoutingMode` (UserSettings flag)

- **`.quick`** — pin tier 1.
- **`.auto`** — session-sticky routing. Tier picked at session start; sticks unless topic-shift + high confidence demands change.
- **`.deep`** — pin tier 3.
- **`.manual`** — every turn goes to whichever provider+model the user picked in the model picker. Escape hatch.

### 8.3 Classification

`SmartProviderRouter.classify(message: String) -> (Tier, confidence)`:

1. **NLContextualEmbedding** if available (single-digit ms on Apple Neural Engine). Embed message; cosine-distance to tier centroids.
2. **Fallback** to `NLEmbedding` (slower).
3. **Final fallback** to keyword heuristic (always available).

Returns top tier + confidence margin vs. runner-up.

### 8.4 Session stickiness

`route(message:in: RoutingSessionState) -> Tier`:

- First 3 turns: classification result is final (settling window).
- Subsequent turns: previous tier sticks **unless**:
  - Topic-shift detected (cosine distance against rolling summary embedding > 0.4) AND confidence margin > threshold, OR
  - Capability flags (see below) demand higher tier.

### 8.5 Capability flags

`CapabilityClassifier` looks at the message for four axes:

- `requires_tools` — message asks for an action (email, contacts, directions)
- `requires_web` — message implies current-events lookup
- `requires_depth` — multi-week analysis, complex coaching
- `medical_speculation` — symptom-style query (also caught by MedicalQueryGuard)

Mapping: 0 flags → `.quick`; 1 flag → `.auto`; 2+ → `.deep`.

### 8.6 Voice-mode bypass

**File:** `AssistantViewModel+Routing.swift` (`resolveProviderForThisTurn`)

Voice utterances are typically ≤12 words. The classifier votes `.quick` even on conceptually deep questions. To prevent every voice question becoming an Apple-only short answer, the bypass:

- If user's selected manual provider is non-Apple AND it's available, **route to user's pick** rather than tier-mapping.
- If user's pick is Apple, fall through to normal tier mapping (which will pick the first available cloud as fallback).

### 8.7 Action-intent override

**File:** `AssistantViewModel+Routing.swift`

If the message requires tools (email / contacts / directions) AND the routed provider can't call tools (Apple in older iOS, or any provider with empty tool catalog), escalate to the first tool-capable cloud. The chat bubble shows the override reason ("Switched to Anthropic — your message needs the email tool, which isn't available on Apple Intelligence").

### 8.8 Adversarial spend cap

**File:** `AssistantViewModel+Routing.swift`

`SmartProviderRouter.recordTier3UsageAndCheck()` enforces a daily limit on `.deep` tier (50 turns). Past the cap, deep requests downgrade to `.auto` for the rest of the day. Resets at midnight local time.

### 8.9 Apple guardrail auto-escalation

**File:** `AssistantViewModel.swift`

When Apple's safety filter refuses a query, the dispatch loop automatically retries on the next-up tier provider in routing modes other than `.manual`. The user never sees the refusal; they just see the cloud answer. Logged as "Auto-escalated past Apple guardrail to next-tier provider."

---

## 9. Voice Subsystem

### 9.1 `VoiceConversationController`

**File:** `Emuqu/Sources/Assistant/VoiceConversationController.swift:44`
**Isolation:** `@MainActor final class : NSObject, ObservableObject`

States: `.idle → .listening → .speaking → .listening` (cycle).

```
                  startListening()
   .idle ──────────────────────────────► .listening
                                              │
                  finalizeUserTurn()           │ (VAD silence trigger, manual stop, max-turn timeout)
                                              ▼
                                           dispatch
                                              │
                                              ▼
              ◄───────────────────  .speaking (TTS + stream)
                  finishSpeaking()                │
                                                  │ (audible end OR user interrupts)
                                                  ▼
                                              .listening
```

Audio path:
1. `AVAudioEngine` input tap → 4800-frame buffers (line 1189 logs `tap tick #N`).
2. Each buffer: VAD (energy + zero-crossing rate).
3. State machine: 1.0s of speech then 1.2s of silence → finalize.
4. Recognizer: `SFSpeechRecognizer` (default) or `WhisperKitSTTBridge` (settings toggle).
5. Final transcript → `AssistantViewModel.send(text: transcript, fromVoice: true)`.

Half-duplex: while `.speaking`, the recognizer task stays alive but the mic buffers are dropped. This catches user "barge-in" (talking over the AI) on the next listening cycle.

### 9.2 STT abstraction

**File:** `Emuqu/Sources/Assistant/Chat/STTProvider.swift`

Two providers:
- **Apple** (`SFSpeechRecognizer`) — built in, 0 cost, on-device. Default.
- **WhisperKit** (`WhisperKitSTTBridge.swift`) — open-source CoreML port of OpenAI Whisper. Better in wind/footfall/noise. ~100-400 MB model download on first enable.

Selection: `UserSettings.preferredSTTProvider` (`.apple` | `.whisperKit`). Switches at next listening start.

### 9.3 TTS pipeline

**File:** `Emuqu/Sources/Assistant/VoiceConversationController+Audio.swift:683`

```swift
func speak(_ text: String) {
    let guarded = applyHallucinationGuard(to: text)
    let speakable = (firstChunk ? "\(preamble) \(guarded)" : guarded)
    let attributed = TTSTextNormalizer.normalize(speakable)
    let utterance = AVSpeechUtterance(attributedString: attributed)
    utterance.voice = bestVoice
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.96
    synthesizer.speak(utterance)
}
```

Sequence:
1. **Hallucination guard** rewrites wrong numeric claims and records them for the next system prompt (§13).
2. **First-chunk preamble** ("Flo here, Sonnet." — subsystem identity + model tag, joined with a comma) — identifies who's speaking on session start. (Mid-workout voice coach uses "Coach here." instead.)
3. **`TTSTextNormalizer`** (§10) preprocesses for AVSpeech.
4. Utterance enqueued.

### 9.4 `SpokenTextChunker`

Buffers streaming tokens until sentence boundaries (`. ! ? \n`), then emits one utterance. Without this, AVSpeech queues tiny utterances per token with awkward pauses.

---

## 10. TTS Text Normalization

### 10.1 `TTSTextNormalizer`

**File:** `Emuqu/Sources/Assistant/TTSTextNormalizer.swift`

Composed pipeline, runs BEFORE `PhoneticOverrides`:

1. **Domain abbreviations** — `BPM`, `HRV`, `VO2`, `Z1–Z5`, `α1`, `TSB`/`ATL`/`CTL`, etc. **APP-SPECIFIC** (rewrite for your domain's vocabulary).
2. **Pace strings** — `"8:45/mi"` → `"eight forty-five per mile"`. Matches `(\d+):(\d{2})(\s|/)(mi|km|...)`. Bare `8:45` without unit suffix is left intact (could be a clock).
3. **Years** — `"2026"` → `"twenty twenty-six"`, `"1990"` → `"nineteen ninety"`. Lookbehind/ahead reject digits, `.`, `,`, `:`, `$` so prices, decimals, and grouped digits stay intact.
4. Hands result to `PhoneticOverrides.speechAttributedString(...)`.

### 10.2 `PhoneticOverrides`

**File:** `Emuqu/Sources/Assistant/PhoneticOverrides.swift`

Three layers:

1. **AI-authored markup** — `[[live|laɪv]]` syntax. The model can wrap any word with an IPA hint. Stripped from display, becomes `accessibilitySpeechIPANotation` on the spoken text.
2. **Domain rules** — `"live HR"`, `"live workout"`, `"your live..."` → respells "live" to "lyve" (so AVSpeech says /laɪv/ not /lɪv/) AND attaches IPA hint as belt-and-suspenders. Respellings must be the same UTF-16 length so NSRange tracking stays valid.
3. **ZIP code spell-out** — `"Lebanon, TN 37090"` → `"Lebanon, TN 3 7 0 9 0"`. Triggers on explicit "ZIP"/"postal code" labels OR on "<state> <5 digits>" pattern. ZIP+4 becomes "3 7 0 9 0 dash 1 2 3 4".

Output: `NSAttributedString` with `.accessibilitySpeechIPANotation` attributes on hint ranges. AVSpeech voices that honor IPA use it; voices that don't (Alex, Siri-tier, some compact voices) get the respelling instead.

---

## 11. MetricsVerifier — Hallucination Guard

**File:** `Emuqu/Sources/Assistant/MetricsVerifier.swift:24`

### 11.1 Forward correction

```swift
static func verify(_ text: String, against snapshot: WorkoutAIContext?) -> [Discrepancy]
```

Regex-matches numeric claims (HR, power, α1, etc.) against `WorkoutAIContext`. `Discrepancy` carries `metric`, `claimed`, `actual`, `range: Range<String.Index>`. Used in `applyHallucinationGuard(to:)` to rewrite the spoken text back-to-front so earlier ranges remain valid.

**APP-SPECIFIC**: the metric set is fitness-specific. Extend or replace the regex set for your domain.

### 11.2 Backward correction (cross-turn feedback)

```swift
static func recordCorrections(_ discrepancies: [Discrepancy])
static func consumePendingCorrectionsBlock() -> String?
```

After every guard fire, corrections enqueue into a process-local NSLock-guarded buffer (capped at 4). `AssistantSystemPrompt.composeSplit(...)` consumes the buffer on the NEXT turn's variable section and injects:

```
# Last turn correction — DO NOT FABRICATE
Your previous response contained numbers that contradicted live data...
• You said HR=72 — actual was 91.
```

The buffer self-clears on consume so a single fabrication produces ONE reminder, not perpetual scolding.

---

## 12. Conversation Persistence & Truncation

### 12.1 `ChatTurn`

**File:** `Emuqu/Sources/Assistant/Providers/AIProvider.swift:154`

```swift
struct ChatTurn: Codable, Identifiable, Hashable {
    let id: UUID
    let role: Role                        // .user, .assistant
    var text: String
    let createdAt: Date
    var providerID: ProviderID?
    var modelID: String?
    let subsystem: AssistantSubsystem?    // .coach, .voiceConversation, .workoutVoiceCoach, .coachReport
    let routedTierRaw: Int?               // 1=Quick, 2=Auto, 3=Deep
}
```

### 12.2 `ConversationStore`

**File:** `Emuqu/Sources/Assistant/Chat/ConversationStore.swift:15`

JSON file in App Group container. `NSFileProtectionComplete` (unreadable while device locked). Atomic-write on background queue; sync read at ViewModel init (~10–50 KB, sub-ms).

```swift
public func load() -> [ChatTurn]
public func save(_ turns: [ChatTurn])
public func clear()
```

### 12.3 Token-aware truncation

**File:** `Emuqu/Sources/Assistant/ViewModel/AssistantViewModel+Tools.swift:666`

Per-provider budgets:

| Provider | Budget tokens |
|----------|---------------|
| Apple | 1,200 |
| DeepSeek | 60,000 |
| Anthropic / OpenAI / Gemini / Grok | 80,000 |

Token estimate is `text.count / 4` — heuristic, not for billing.

Algorithm: walk newest → oldest, accumulate, return `(kept, dropped)`. Always keep newest user turn.

### 12.4 Summarization on truncation

When turns are dropped, `updateSummaryWith(droppedTurns:provider:model:contextRendered:)` (line 588) calls the active provider with:

> "Write a single concise paragraph (≤120 words) capturing what the user shared, what they asked about, and what the assistant advised. DROP stale live telemetry (HR values, pace, GPS, weather, grade %). PRESERVE persistent content (bugs, features, preferences, medical context, training goals, race dates, user-stated reminders)."

The summary becomes `priorSummary` and injects into next turn's variable system prompt section. 5-second timeout; failure doesn't block the user's message.

---

## 13. Safety Gates

### 13.1 `MedicalQueryGuard`

**File:** `Emuqu/Sources/Assistant/MedicalQueryGuard.swift`
**Gating flag:** `FeatureFlags.medicalGuardEnabled` (default ON, can be toggled per build).

Local refusal layer for AFib / arrhythmia / symptom queries. Pattern-matches the user's text BEFORE any LLM call. On match:

```swift
case .refuse(let reply):
    // synthesize a local assistant turn with deflection copy
    // no LLM call, no PHI leaves device
```

**APP-SPECIFIC** — the regexes are fitness/health-domain. For a non-medical app, either delete the file OR rewrite the regex set for your guardrails (e.g. legal advice refusal, financial-advice refusal).

### 13.2 `ProviderConsentTracker`

**File:** `Emuqu/Sources/Assistant/ProviderConsentTracker.swift:24`

Per-provider PHI/PII consent gate. Apple Intelligence is exempt (on-device). Each cloud provider (Anthropic, OpenAI, Gemini, Grok, DeepSeek) requires explicit first-time acknowledgement before its first message is sent.

Storage: `UserDefaults` keyed by `"assistant.consent.v1.<provider>"`. Schema-versioned so new disclosure language invalidates old consent.

### 13.3 `CoachVoiceGuard`

**File:** `Emuqu/Sources/Assistant/CoachVoiceGuard.swift`

Final-pass scrubber after stream completes. Catches forbidden phrases before user sees/hears (medical advice, danger-zone framings, speculative diagnoses). Returns `(scrubbed: String, didIntercept: Bool, triggers: [InterceptTrigger])` for audit trail.

**APP-SPECIFIC** — rules tuned to health/recovery domain.

### 13.4 Information Access Principle (system prompt)

**File:** `Emuqu/Sources/Assistant/Providers/AIProvider.swift` `base` constant

The base prompt encodes a "MEDICAL BOUNDARY" section structured around an "Information Access Principle":
- Rule A: personal diagnosis = no
- Rules B–F: factual discussion of symptoms, AFib, medications, physiology, etc. = yes (you're an adult, you have access to information)
- Rule G: tone — frustration ≠ abuse, don't bail just because the user is intense

This was a deliberate authorial choice — the user wanted the app to surface truth, not gate-keep "go talk to your doctor" on every health question. **APP-SPECIFIC**: rewrite for your domain.

---

## 14. UserFactsStore — Cross-session memory

**File:** `Emuqu/Sources/Assistant/Chat/UserFactsStore.swift:14`

```swift
struct Fact: Codable {
    let id: UUID
    let text: String
    let createdAt: Date
}
```

Storage: `{AppGroup}/Assistant/user_facts.json`.

API:
- `add(_ text: String)` — append, deduped case-insensitively.
- `remove(id:)`
- `clear()`
- `systemPromptBlock() -> String` — renders all facts as "About this user (cross-session memory)" block; injected in the stable system prompt section.

### 14.1 Auto-extraction

**File:** `Emuqu/Sources/Assistant/ViewModel/AssistantViewModel+Context.swift` (`runAutoFactExtraction`)

When `userFactsAutoExtractEnabled` is on, after every assistant turn completes, the cheapest available provider is asked:

> "Extract any new persistent facts about the user from this exchange. Return JSON: `{"facts": ["fact 1", "fact 2"]}`. Drop questions, app-state observations, and known repeats."

Filter:
- Drops questions and app-state observations
- Skips known repeats (case-insensitive substring match against existing facts)
- Caps at 3 new facts per exchange

Telemetry: each extraction logged as `[Assistant] auto-fact-extract added=<n>`.

### 14.2 AI-controlled memory actions

The fact catalog exposes:
- `assistant.memory.add(text)` — model can save a memory
- `assistant.memory.remove(id)` — model can delete a memory
- `assistant.memory.clear` — model can wipe all memories

These ride on the standard tool-use pipeline. The model uses these when the user says "remember that..." or "forget about...".

---

## 15. DeterministicIntent — LLM bypass

**File:** `Emuqu/Sources/Assistant/Facts/DeterministicIntent.swift:31`

Voice-only path. Research analysis suggests ~30–50% of voice utterances are repeats of a small set of factual lookups ("recovery score?", "RHR?", "how did I sleep?") — this is an *estimate* from linguistic patterns, not a measured production rate. No telemetry counter currently surfaces the actual bypass percentage (only a debug log fires per hit). LLM calls cost ~$0.005 each + 200ms latency. A regex match + fact lookup costs $0 and runs <50ms.

```swift
struct Pattern {
    let id: String
    let triggers: [String]               // regex patterns (compiled at init)
    let handler: @MainActor (_ utterance: String, _ context: MatchContext) -> String?
}

struct MatchContext {
    let now: Date
    let archive: SessionArchive
    let userSettings: UserSettings
}

static func tryMatch(_ utterance: String, in context: MatchContext) -> String?
```

Acceptance gate: confidence ≥ 0.85 AND matched fact non-nil. Below gate → falls through to LLM. Target: 95% precision. Enforced by `DeterministicIntentTests` against a 200-utterance labeled set.

Voice-only by design — text chat goes through the full LLM path because typed messages tend to be multi-part questions that the deterministic path would over-truncate.

**APP-SPECIFIC**: the 12–15 patterns assume recovery/HRV/sleep domain. Rewrite for your app's most common voice questions.

---

## 16. AppleToolDispatcher — iOS 26 Tool adapter

**File:** `Emuqu/Sources/Assistant/Providers/AppleToolDispatcher.swift` (adapter in `AppleFoundationToolAdapter.swift`; used via `AppleToolDispatcher.shared`)

Apple Intelligence's iOS 26 `LanguageModelSession(tools:)` expects `Tool` protocol conformers. The dispatcher adapts our `[ToolSpec]` to that:

```swift
final class AppleToolDispatcher {
    static let shared = AppleToolDispatcher()
    func setRegistry(_ registry: FactResolverRegistry?)   // nil clears
    // internal: builds Tool conformers wrapping registry.resolveTool(...)
}
```

`AssistantViewModel.dispatch()` calls `setRegistry(factRegistry)` before the Apple stream and `setRegistry(nil)` on stream completion. Without the cleanup, `DataPurgeService` later can't fully wipe registry-cached state.

**PORTABLE** — same adapter shape would work for any other on-device tool runtime. Replace the `Tool` protocol with whatever your runtime expects.

---

## 17. Action Bridges (Email, Contacts, Web Search)

### 17.1 Email

**File:** `Emuqu/Sources/Assistant/Chat/AssistantEmailBridge.swift`
**Action:** `assistant.email.compose(to, cc, subject, body, category)`

The action stages a draft (subject + body + recipients). Bridge presents `MFMailComposeViewController` for user review; the app NEVER sends mail directly. `category` ("recovery" / "training") selects which set of default recipients to apply.

**PORTABLE**.

### 17.2 Contacts

**Actions:** `assistant.contacts.add`, `.remove`, `.list`. Stores a small per-app contact book that the email action's name resolution uses.

**PORTABLE**.

### 17.3 Web search

**Action:** `web.search(query)` — Tavily API (1000 free searches/month). Used for current-events lookups beyond the model's training cutoff.

**PORTABLE** (but you supply your own Tavily key or replace with your search backend).

---

## 18. Porting Checklist

When extracting Flo into a non-fitness app, the changes cluster into three buckets:

### 18.1 KEEP AS-IS (portable)

- `AssistantViewModel` core dispatch loop and state
- `AIProvider` protocol + all 6 cloud provider implementations
- `FactCatalog` shapes (`.fixed`, `.parameterized`, `.composite`, `.action`)
- `FactValue` / `MissingReason` envelopes
- `CompactToolRouter` polymorphism layer
- `AssistantSystemPrompt` cache-aware composition machinery
- `SmartProviderRouter` (replace classifier patterns; keep tier model)
- `ConversationStore` JSON persistence
- `VoiceConversationController` STT/TTS plumbing (replace `WorkoutVoiceCoach` integration)
- `ProviderConsentTracker`
- `UserFactsStore` cross-session memory + auto-extraction
- `AppleToolDispatcher` iOS 26 Tool adapter
- `MetricsVerifier` cross-turn correction buffer (replace metric regexes)
- `PhoneticOverrides` IPA hints + AI-authored markup
- `TTSTextNormalizer` pipeline structure
- `DeterministicIntent` matching machinery
- Email / contacts action bridges

### 18.2 REWRITE (app-specific)

- **`base` system prompt** — `AIProvider+SystemPrompt.swift`. Persona, brevity rules, refusal rules.
- **`AppKnowledgeBase.reference`** — your app's feature manual.
- **`disabledFeaturesSummary()`** — `AIProvider+SystemPrompt.swift`. Your app's feature flags.
- **`localeAndUnitsDirective()`** — `AIProvider+SystemPrompt.swift`. Your unit system.
- **Fact namespace files** — `AppFactResolver+*.swift`. Replace fitness namespaces (Session, TrainingLoad, Sleep, Walks, Recovery, HRV, Vitals, Score) with your domain.
- **`CompactToolRouter` read tools** — line 99+. Rebuild for your data model.
- **`DeterministicIntent` patterns** — line 63+. Replace recovery/HRV patterns with your app's high-frequency voice intents.
- **`MetricsVerifier` regex set** — `MetricsVerifier.swift:51`. Replace HR/power/α1 with your metrics.
- **`MedicalQueryGuard`** — `MedicalQueryGuard.swift`. Either delete or rewrite for your domain's guardrails.
- **`CoachVoiceGuard` triggers** — health-domain rules. Replace with your app's rules.
- **`TTSTextNormalizer.domainAbbreviations`** — fitness vocab. Replace with your domain's abbreviations.
- **`PhoneticOverrides.domainRules`** — "live HR/data/pace" patterns. Replace with your domain's homographs.
- **`activeWorkoutMarker()`** — `AIProvider+SystemPrompt.swift`. Remove or replace with your app's active-session concept.
- **`WorkoutAIContext`** — replace with your app's live-session snapshot, or remove if not applicable.
- **Routing namespaces priority** — `AssistantViewModel.swift:174`. Replace fitness namespace ordering with yours.

### 18.3 DELETE (fitness-specific consumers)

- `WorkoutVoiceCoach.swift` — mid-workout voice alerts
- `TurnAlertEngine.swift`, `TurnMarkerEngine.swift` — navigation alerts (delete if no nav)
- `SavedRouteStepBuilder.swift`, `RoadAwarenessEngine.swift`, `RoadGraphService.swift`, `OSMNominatimService.swift`, `RoadGeocodingService.swift` — location/navigation infrastructure (delete if no nav)
- `JourneyIntelligenceService.swift`, `RecurrenceClassifier.swift` — walk-pattern classification (delete)
- `SurroundingsPOIService.swift` — nearby POIs (delete)
- `ActiveRouteSession.swift`, `DirectionsService.swift` — turn-by-turn (delete if no nav)

### 18.4 Estimation

For a moderately-sized non-fitness app:

- **Keep** ~80% of the code by line count (provider plumbing, dispatch, persistence, voice, prompt cache machinery).
- **Rewrite** ~15% (system prompt, namespace facts, deterministic patterns, metric verifier, voice domain rules).
- **Delete** ~5% (fitness-specific subsystem files).

The keep-as-is portion is the hard part to get right; rewriting your domain layer is straightforward once you understand what's invariant (the shapes) vs. what's domain (the contents).

---

## 19. Build Dependencies

Module imports (from the Assistant tree):

- **Foundation, SwiftUI, Combine, AVFoundation, CoreLocation** — Apple stdlib
- **NaturalLanguage** — `NLContextualEmbedding` for SmartProviderRouter
- **WhisperKit** (SPM) — optional STT provider
- **No third-party LLM SDKs** — every cloud provider (Anthropic, OpenAI, Gemini, Grok, DeepSeek) is a direct URLSession + JSON/SSE streamer. The only built-in LLM runtime is:
  - **Apple FoundationModels** — built into the iOS 26 SDK (on-device).

API keys are stored via `APIKeyStore` (Keychain) — the host app provides settings UI for the user to paste keys; nothing is bundled.

---

## 20. Testing

The module has 59 deterministic tests across 4 suites:

- **`PhoneticOverridesTests`** (16) — IPA hints, ZIP expansion, "live" homograph
- **`TTSTextNormalizerTests`** (22) — abbreviations, pace strings, year expansion, end-to-end pipeline
- **`HallucinationFeedbackTests`** (5) — corrections buffer accumulation, capping, consume-clears-buffer
- **`RouteNavigationEnginesTests`** (16) — fitness-app-specific (turn detection, alert state machines, route-history baseline)

Run via:
```bash
xcodebuild test -project Emuqu.xcodeproj \
  -scheme Emuqu \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:EmuquTests/PhoneticOverridesTests \
  -only-testing:EmuquTests/TTSTextNormalizerTests \
  -only-testing:EmuquTests/HallucinationFeedbackTests
```

When porting:
- Keep `PhoneticOverridesTests`, `TTSTextNormalizerTests`, `HallucinationFeedbackTests` as templates (replace fitness-specific assertions with your domain's).
- Add a `DeterministicIntentTests` for your app's intent patterns (target 95% precision).
- Add a per-namespace test file for each fact namespace.

---

## 21. Known Gotchas

These are non-obvious behaviors that bit during development; documenting so you don't re-discover them:

1. **MainActor.assumeIsolated traps off-main.** All 60+ resolvers use this pattern. If you change `dispatch()` to `Task.detached`, every resolver crashes. Surgery is documented in §4.

2. **`AVAudioConverterInputBlock` is `@Sendable` but executes synchronously.** Capturing non-Sendable PCM buffers into the closure looks unsafe but isn't. `@preconcurrency import AVFoundation` silences the warning.

3. **`URLRequest.timeoutInterval` is the IDLE timeout, not total wall-clock.** For hard cut-offs use `URLSessionConfiguration.timeoutIntervalForResource`. Both are belt-and-suspenders since URLSession doesn't always honor either on degraded connectivity — wrap in `Task.withTimeout` for guaranteed cut-off.

4. **Anthropic 400 "Tool names must be unique"** — fact catalog can double-register a tool name. `CompactToolRouter.schema(...)` deduplicates defensively (line 62).

5. **Apple silently swaps Siri voices to a fallback.** Ava/Aaron/newer Siri voices that the user picks may be replaced at speak time without warning. IPA hints work on some fallbacks, not others. Plan for graceful degradation.

6. **`AVSpeechSynthesizer` has no public lexicon API.** No PLS, no custom dictionary upload. Per-utterance `.accessibilitySpeechIPANotation` and SSML `<phoneme>` (iOS 16+) are the only mechanisms.

7. **`NumberFormatter(.spellOut)` reads `2026` as "two thousand twenty-six"**, not "twenty twenty-six". Years need special handling (see `TTSTextNormalizer.expandYears`).

8. **iOS App Watchdog kills foreground apps at ~10s of unresponsive main thread.** Resolvers run on MainActor. Sync `DispatchSemaphore.wait(timeout:)` over 4s is at real risk. The `[FactRegistry] ⚠️ WATCHDOG-WARN` log line surfaces this.

9. **Anthropic prompt cache has a 5-minute TTL.** Cache misses cost ~5× a hit. Don't put per-second-volatile content (current time, live HR) in the stable prefix.

10. **Provider streams emit `.toolUse` once per fully-formed call, not delta-by-delta.** Internal accumulation happens inside provider files. Don't try to handle partial tool_use in `runToolUseLoop`.

---

## 22. Telemetry

Built-in observability:

- **`[Assistant] usage <provider>: input=N output=M cached=X cacheCreate=Y hit_ratio=Z.ZZ`** — per-stream token usage, cache hit ratio.
- **`[FactRegistry] action <name> exceeded 2.0s budget — took N s`** — slow tool warning.
- **`[FactRegistry] ⚠️ WATCHDOG-WARN action <name> blocked for N s — over the 4s ceiling`** — App Watchdog risk.
- **`[GeocodingLatency] ...`** — geocoder pipeline timings (fitness-specific consumer).
- **`[VoiceConv] recognition error: <domain>:<code>`** — STT errors, demoted to `.info` for benign 1110 silence-detected.
- **`[Hallucination guard] HR=claimed:72 actual:91 Δ19.0`** — guard fires.
- **`[SmartRouter] tier=<tier> → <provider>:<model>`** — routing decisions.
- **`[Assistant] medical-query guard fired — refusing locally`** — local refusal.

All routed through `debugLog(...)` (`Emuqu/Sources/Utilities/DebugLog.swift`). The user-facing "Recent Problems" section in Settings → Troubleshooting shows `.warning` and `.error` levels only.

---

## Appendix A — File Tree

```
Sources/Assistant/
├── ViewModel/
│   ├── AssistantViewModel.swift         (the orchestrator)
│   └── AssistantViewModel+Tools.swift   (tool-use loop)
├── Providers/
│   ├── AIProvider.swift                  (protocol + AssistantSystemPrompt)
│   ├── AppleFoundationProvider.swift
│   ├── AnthropicProvider.swift
│   ├── OpenAIProvider.swift
│   ├── GeminiProvider.swift
│   ├── GrokProvider.swift
│   ├── DeepSeekProvider.swift
│   ├── OpenAICompatibleStreamer.swift    (shared OpenAI-style SSE streamer)
│   ├── AppleToolDispatcher.swift         (iOS 26 Tool adapter)
│   ├── AppleFoundationToolAdapter.swift
│   └── ProviderRegistry.swift
├── Facts/
│   ├── FactCatalog.swift                 (FactEntry, FactValue, ToolSpec)
│   ├── FactValue.swift                   (universal return envelope)
│   ├── CompactToolRouter.swift           (polymorphism layer)
│   ├── AppFactResolver.swift             (factory)
│   ├── AppFactResolver+Live.swift        (live HRV facts)
│   ├── AppFactResolver+Workout.swift     (workout context facts)
│   ├── AppFactResolver+Settings.swift    (location, directions, web search, etc.)
│   ├── AppFactResolver+Sleep.swift       (sleep facts)
│   ├── DeterministicIntent.swift         (LLM bypass)
│   ├── CapabilityClassifier.swift        (depth classifier)
│   ├── TierProviderMapper.swift          (tier → provider/model)
│   ├── AppleContextCompactor.swift       (Apple rendered-context builder)
│   ├── PrefetchService.swift             (typed read-through cache — infra only; NOT yet wired to any fetch site)
│   ├── ToolRetriever.swift               (tool subset selection)
│   ├── LLMCacheTelemetry.swift           (cache-hit metrics)
│   ├── LLMRequestAudit.swift             (request audit log)
│   ├── FactKey.swift                     (fact key parsing)
│   └── SmartProviderRouter.swift         (tiered routing)
├── Chat/
│   ├── ConversationStore.swift           (persistence)
│   ├── UserFactsStore.swift              (memory)
│   ├── AssistantEmailBridge.swift        (mail compose)
│   ├── STTProvider.swift                 (STT abstraction)
│   └── WhisperKitSTTBridge.swift         (open-source STT)
├── VoiceConversationController.swift
├── VoiceConversationController+Audio.swift
├── PhoneticOverrides.swift               (TTS pronunciation)
├── TTSTextNormalizer.swift               (TTS preprocessing)
├── MetricsVerifier.swift                 (hallucination guard)
├── MedicalQueryGuard.swift
├── CoachVoiceGuard.swift
├── ProviderConsentTracker.swift
├── WorkoutAIContext.swift                (live-session snapshot — APP-SPECIFIC)
├── WorkoutVoiceCoach.swift               (mid-session alerts — APP-SPECIFIC)
├── TurnAlertEngine.swift                 (nav alerts — APP-SPECIFIC)
└── TurnMarkerEngine.swift                (nav splits — APP-SPECIFIC)
```

---

**End of spec. ~6800 words. Last verified 2026-05-08.**

For questions or corrections, open an issue against this file. The map of file:line references was produced by an exhaustive search agent on 2026-05-08; line numbers may drift as the codebase evolves but the architectural shape should remain stable.
