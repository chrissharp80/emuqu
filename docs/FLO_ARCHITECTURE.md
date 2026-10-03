# Flo — AI Assistant Architecture

**Source tree:** `Emuqu/Sources/Assistant/`

How Flo, the assistant inside Emuqu, is built: the turn lifecycle, providers, the fact/tool layer, routing, voice, and the safety gates. Citations are file + symbol; line numbers are left out because they drift.

---

## 1. What Flo Is

- **Six providers behind one protocol:** Apple Intelligence (on-device), Anthropic, OpenAI, Google Gemini, xAI Grok, DeepSeek.
- **Tool use through one registry.** Every read or write the model can do is a `FactEntry` in a `FactResolverRegistry`, returned as a typed `FactValue`. Cloud providers emit tool calls in the stream; Apple Intelligence gets the same registry through `AppleToolDispatcher` and `LanguageModelSession(tools:)`.
- **Tiered routing.** `SmartProviderRouter` picks on-device, cheap cloud or strongest cloud per conversation.
- **Voice mode.** `SFSpeechRecognizer` or WhisperKit for speech-to-text, `AVSpeechSynthesizer` for speech, with sentence-level chunking and pronunciation fixes.
- **Cross-session memory** in `UserFactsStore`, with optional auto-extraction.
- **Cache-aware system prompt.** A stable prefix and a per-send suffix, so Anthropic's prompt cache can hit.
- **Deterministic shortcuts.** A small set of voice questions is answered from local data with no model call.
- **Hallucination guard.** Numbers in replies are checked against live data and app state, corrected, and fed back to the next turn.
- **Per-provider consent.** No data goes to a cloud provider until the user has accepted that provider's disclosure.

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
                          │  - DeterministicIntent      │  ← no model call on hit
                          │  - dispatch()               │
                          └──────────────┬──────────────┘
                                         │
                          ┌──────────────▼──────────────┐
                          │   TurnRouter / SmartProvider│
                          │   Router: quick/auto/deep   │
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
                          │   .textDelta  .toolUse      │
                          │   .usage      .done         │
                          └──────────────┬──────────────┘
                                         │
       ┌─────────────────────────────────┼─────────────────────────────┐
       ▼                                 ▼                             ▼
   .toolUse:                       .textDelta:                    after the stream:
   CompactToolRouter.resolveTool   accumulate into ChatTurn       app-state number check
   → FactValue JSON                voice: chunk → speak()         CoachVoiceGuard scrub
   → next round                                                   optional fact extraction
```

---

## 3. Turn Lifecycle

### 3.1 Input

Text: `AssistantViewModel.send(text:fromVoice: false)`. Voice: `VoiceConversationController` finalizes a transcript and calls the same method with `fromVoice: true`.

### 3.2 `AssistantViewModel.send(text:fromVoice:)` — gating

In order:

1. Whitespace-only input → `.rejectedEmpty`.
2. Flo switched off, or its notice not accepted (`refusedWhileFloIsOff`) → `.rejectedNoProvider`.
3. `medicalGuardRefused` — when the `medicalGuardEnabled` feature flag is on (default), or always for self-harm, `MedicalQueryGuard.evaluate` can return `.refuse(reply:)`. The exchange is appended locally with `localOnly: true` and no provider is called.
4. Active provider has no key → `.rejectedNoProvider`.
5. `ProviderConsentTracker.requiresConsent` → `.requiresConsent(provider)`. The view shows the consent sheet; `acknowledgeConsentAndContinue()` re-sends.
6. A stream already running → `queueBehindStream` stores the message in `pendingSendOnFinish` (latest wins) → `.queued`.
7. Voice only: `servedDeterministically` → `DeterministicIntent.tryMatch` (§15). A hit appends a local exchange.
8. `dispatchToProvider` appends the user turn, sets `nextSendIsVoice`, prewarms Apple's model when Apple may be routed to, and calls `dispatch()`.

### 3.3 `dispatch()` — `AssistantViewModel+Routing.swift`

`dispatch()` lives on `AssistantTurnRouter` (the view-model forwards to it).

1. `routeTurnAndLogOverride()` → provider, model, tier, voice flag. Routing is in §8.
2. Re-checks key and consent for the routed provider.
3. `reserveAssistantPlaceholderTurn` appends an empty assistant turn stamped with provider, model and tier.
4. Bumps `streamGeneration`, cancels the previous `streamTask`, starts a new `Task` running `runDispatchedTurn`.

`runDispatchedTurn`:

1. `refreshPreFlightMetrics()`.
2. `assembleContextAndTools` — Apple gets a `compactRender()` data block; other providers get none and use tools. `truncateForSend` trims history to the provider budget (§12); newly dropped turns are summarized. `factRegistryAndTools()` builds the registry and tool list, `ToolRetriever.retrieve` keeps the most relevant tools for this message (BM25, `targetK: 40`), and `trimTools` applies `maxToolSchemaCount`.
3. `composeSystemPromptForTurn` → `AssistantSystemPrompt.compose(...)` (§7).
4. `runStreamWithErrorPolicy` runs the tool loop. Cancellation is swallowed; an Apple guardrail refusal goes to `escalateOnAppleRefusal`; a fallbackable provider error (auth, rate limit, network, model unavailable) walks `orderedFallbackProviders`.
5. Drops the assistant turn if it ended empty, then `finishStream(generation:)`.
6. If this is still the current generation: clears the Apple dispatcher's registry and runs `applyPostStreamEffects` (`CoachVoiceGuard` scrub, then background fact extraction when `UserFactsStore.autoExtractEnabled`).

### 3.4 `runToolUseLoop` — `AssistantViewModel+Tools.swift`

Each round calls `provider.send(messages:model:contextRendered:systemPrompt:tools:toolRounds:)` and consumes the stream:

- `.textDelta` → appended to the assistant turn, published on a 33 ms throttle.
- `.toolUse` → queued for resolution.
- `.usage` → logged with the cache hit ratio.
- `.done` → round ends.

With no tool calls the loop ends. Otherwise each call goes through `CompactToolRouter(registry:).resolveTool(name:argsJSON:)`, the results become a `ToolExchange` round, and the provider is called again. `maxToolCallsPerTurn` is 8; calls past that get a synthetic missing result and the model gets one closing pass. At the end of each round, `verifyAppStateNumbers` checks training-load and overnight numbers in the reply (§11).

---

## 4. AssistantViewModel

**File:** `Emuqu/Sources/Assistant/ViewModel/AssistantViewModel.swift` — `@Observable @MainActor final class`, `static let shared`.

Main state: `turns`, `isStreaming`, `errorMessage`, `priorSummary`, `pendingDraft`, `speakableTextCursor`, `pendingConsentRequest`.

Main API: `send(text:fromVoice:)`, `send(prefab:)`, `acknowledgeConsentAndContinue()`, `cancelPendingConsent()`, `cancel()`, `clearConversation()`, `regenerateLast()`, `invalidateContext()`.

`SendOutcome`: `.dispatched`, `.queued`, `.rejectedEmpty`, `.rejectedNoProvider`, `.requiresConsent(ProviderID)`.

Routing and streaming stages live on `AssistantTurnRouter` and `AssistantToolRunner` (the `+Routing`, `+Tools` and `+*Forwarding` files) so the view-model type stays under the type-size budget.

The streaming task is created from MainActor code, so resolvers run on the main actor. Fact bodies declare either `.sync` (in-memory reads) or `.awaitable` (network, HealthKit, geocoding), and awaitable ones suspend the actor instead of blocking it (§6.5).

---

## 5. Providers

### 5.1 Protocol — `Emuqu/Sources/Assistant/Providers/AIProvider.swift`

```swift
protocol AIProvider {
    var id: ProviderID { get }
    var availableModels: [ModelOption] { get }
    var requiresKey: Bool { get }
    var isAvailable: Bool { get }
    var maxToolSchemaCount: Int? { get }   // default nil = no cap

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

An extension adds a four-argument `send` with no tools, used by the summarizer and fact extractor.

`AIStreamEvent`: `.textDelta(String)`, `.toolUse(id:name:inputJSON:)`, `.usage(inputTokens:outputTokens:cachedInputTokens:cacheCreationInputTokens:)`, `.done`. Providers accumulate tool-call deltas and emit `.toolUse` once per complete call.

`ProviderID`: `apple`, `anthropic`, `openai`, `gemini`, `grok`, `deepseek`.

`ModelOption`: `providerID`, `apiID`, `displayName`, `blurb`, `contextWindow`, `inputPricePerMTok`, `outputPricePerMTok`, `isDefault`.

### 5.2 Provider matrix

| Provider | File | Transport | Notes |
|----------|------|-----------|-------|
| Apple | `AppleFoundationProvider.swift` | FoundationModels `LanguageModelSession` | Model `apple.foundation.on-device`, 4096-token context. Tools via `AppleToolDispatcher` (§16). |
| Anthropic | `AnthropicProvider.swift`, `AnthropicProvider+Request.swift` | Messages API, SSE | Prompt cache: `cache_control` `ephemeral` with `ttl: "1h"` and the `extended-cache-ttl-2025-04-11` beta header. |
| OpenAI | `OpenAIProvider.swift` | `OpenAICompatibleStreamer` | Reports `prompt_tokens_details.cached_tokens`. |
| Gemini | `GeminiProvider.swift` | streaming `generateContent`, SSE | Own request builder. |
| Grok | `GrokProvider.swift` | `OpenAICompatibleStreamer` | `maxToolSchemaCount` is 110. |
| DeepSeek | `DeepSeekProvider.swift` | `OpenAICompatibleStreamer` | Reports `prompt_cache_hit_tokens`. |

`ProviderRegistry` holds the providers and the user's selection. Keys are in the Keychain via `Emuqu/Sources/Assistant/Keys/APIKeyStore.swift`; nothing is bundled.

---

## 6. Fact / Tool System

Everything the model can read or do is a fact (read) or an action (write).

### 6.1 `FactValue` — `Emuqu/Sources/Assistant/Facts/FactValue.swift`

```swift
enum FactValue {
    case integer(Int), double(Double), string(String), date(Date)
    case durationSec(Int), boolean(Bool)
    case missing(reason: MissingReason, detail: String? = nil)
    case list([FactValue])
    case record([String: FactValue])
}
```

`MissingReason`: `notRecorded`, `notYetComputed`, `outOfRange`, `sensorDropout`, `invalidParameter`, `internalError`, `tooMuchData`, `rateLimited`, `partialData`. The `detail` string lets the model say "you haven't taken a reading yet" instead of "I don't know".

`Availability` (`hasData`, `validRange`, `lastUpdated`) is a cheap, no-I/O check. Entries with `hasData == false` are left out of the schema, so the model never sees a tool that can't return data.

### 6.2 `FactEntry` — `Emuqu/Sources/Assistant/Facts/FactCatalog.swift`

- `.fixed(key:description:valueType:availability:body:)` — one key, one value. `body` is a `FactResolveBody`: `.sync` or `.awaitable`.
- `.parameterized(pattern:paramExample:description:availability:resolve:)` — e.g. `session.by_date($date)`; the resolver gets the parameter and any key tail.
- `.composite(key:description:valueType:dependencies:availability:resolve:)` — aggregates atomic facts through the registry; partial failure reports `.partialData`.
- `.action(key:description:parameters:availability:body:)` — a side effect. The description must start with `[ACTION]`; `parameters` is `[ActionParam]` (`name`, `description`, `required`).

### 6.3 `CompactToolRouter` — `Emuqu/Sources/Assistant/Facts/CompactToolRouter.swift`

The catalog has hundreds of entries. `CompactToolRouter.schema(registry:)` shows the model 21 polymorphic read tools (`get_today`, `get_session`, `get_recovery`, `get_hrv`, `get_sleep`, `get_workout`, `get_workout_live`, `get_training_load`, `lookup_fact`, and others) plus the actions named in `allowedActionNames`: route-library rename/save/engage, contacts add/remove, email compose, memory add/remove/clear, `web_search`, location and directions actions.

A read tool maps its arguments to a fact key; for example `get_recovery` with `which: "trend"` resolves `recovery.trend`. `lookup_fact` takes a key directly. Read results pass through the registry's rate limit, size cap and time budget (`gatedReadResult`). `schema` dedupes by name, because Anthropic rejects duplicate tool names with a 400. `capabilityIndex()` renders a one-line-per-tool list for the cached system prompt.

### 6.4 Registry and namespaces

`AppFactResolverFactory.build(archive:settings:)` in `Emuqu/Sources/Assistant/Facts/AppFactResolver.swift` returns a `FactResolverRegistry` (`Emuqu/Sources/Assistant/Facts/FactResolverRegistry.swift`) with every namespace registered. Each namespace is a `struct` conforming to `FactNamespaceResolver` (`namespace`, `entries`), spread across the `AppFactResolver+*.swift` files: `UserProfileNamespace`, `AppCapabilitiesNamespace`, `SessionNamespace`, `WalksNamespace`, `TrainingLoadNamespace`, `SleepNamespace`, `HRVNamespace`, `VitalsNamespace`, `RecoveryNamespace`, `WorkoutNamespace`, `WorkoutLiveNamespace`, `RoutesLibraryNamespace`, `AssistantMemoryNamespace`, `WebSearchNamespace`, `CompositesNamespace` and others.

`FactCatalogValidationTests` checks the catalog's shape.

### 6.5 Resolver time budget — `FactResolverRegistry`

Resolvers run on the main actor, and iOS kills a foreground app whose main thread is unresponsive for about 10 s. The registry times every call:

- Over `defaultResolveBudgetSec` (2 s): a warning; a read result is replaced with `.missing(.internalError)`.
- Over `watchdogWarnSec` (4 s) on an action: a `WATCHDOG-WARN` warning.

Awaitable resolvers bound their own waits with `FactResolveTimeout.withTimeout(seconds:_:)`.

---

## 7. AssistantSystemPrompt — Cache-aware composition

**Files:** `Emuqu/Sources/Assistant/Providers/AIProvider+SystemPrompt.swift` (composition), `Emuqu/Sources/Assistant/Providers/AIProvider+SystemPromptText.swift` (`base` and the overlays).

`composeSplit(...)` returns `Composed` with a `stable` and a `variable` half. `compose(...)` returns `combinedWithMarker`: the two halves joined by `Composed.cacheSplitMarker`. Anthropic splits on the marker and caches the stable block; the other providers strip it.

### 7.1 Stable sections (`stableSections`)

1. `base` — persona, brevity, the medical boundary (§13.4).
2. Language override when `forceAIEnglish` is on.
3. `localeAndUnitsDirective` and `disabledFeaturesSummary`.
4. Tool mode: `toolOverlay` plus `CompactToolRouter.capabilityIndex()`. Without tools: `nonToolModeOverlay`.
5. `voiceOverlay` on voice turns.
6. `AppKnowledgeBase.reference` or `.referenceCompact`.
7. User memory from `UserFactsStore.systemPromptBlock()`.

### 7.2 Variable sections (`variableSections`)

1. `nowSnapshot()` — the current time. It used to sit in the stable half and caused a cache miss on every send.
2. Training-load numbers matching the dashboard.
3. `activeWorkoutMarker()` when a workout is running (no live numbers; those come from tools).
4. `MetricsVerifier.consumePendingCorrectionsBlock()` (§11).
5. The summary of dropped turns.
6. The rendered data block (Apple only).

---

## 8. Routing — `TurnRouter` and `SmartProviderRouter`

**Files:** `Emuqu/Sources/Assistant/ViewModel/TurnRouter.swift` (pure decision, tested by `TurnRouterTests`), `Emuqu/Sources/Assistant/ViewModel/AssistantViewModel+Routing.swift` (`resolveProviderForThisTurn` gathers inputs), `Emuqu/Sources/Assistant/Facts/SmartProviderRouter.swift`, `Emuqu/Sources/Assistant/Facts/CapabilityClassifier.swift`, `Emuqu/Sources/Assistant/Facts/TierProviderMapper.swift`.

### 8.1 Tiers and modes

`SmartProviderRouter.Tier`: `.quick` (1, on-device), `.auto` (2, cheap cloud), `.deep` (3, strongest cloud). `TierProviderMapper` maps each tier to whatever the user has configured; with only Apple available every tier is Apple.

`RoutingMode` (in `UserSettings`): `.quick` and `.deep` pin a tier, `.auto` classifies, `.manual` always uses the picker selection.

### 8.2 Classification and stickiness (`.auto`)

`classify` uses `NLContextualEmbedding` against prototype phrases, falling back to `NLEmbedding`, then to keywords. `CapabilityClassifier` sets four flags (needs tools, needs web, needs historical depth, needs speculation): none → `.quick`, one → `.auto`, two or more → `.deep`.

`route(message:in:)` keeps the session's tier unless:
- the topic shifted (cosine distance above 0.4 against the summary embedding),
- the proposal is higher (upgrades always allowed),
- the conversation is within its first 3 turns, or
- the proposal is `.quick` with no capability flags.

### 8.3 Overrides

- **Voice bypass:** voice turns skip tier classification. They go to the user's selected provider if it isn't Apple; if Apple is selected, to the first available consented cloud provider, else Apple.
- **Action intent:** if the message needs a tool and the tier's provider can't call action tools (`providerSupportsTools` is false for Apple), the turn goes to the first available consented cloud provider.
- **Daily Tier 3 cap:** `recordTier3UsageAndCheck()` allows 50 deep turns per day, then downgrades to `.auto`.
- **Apple guardrail:** if Apple's safety filter refuses, `escalateOnAppleRefusal` re-sends the turn to the deep-tier mapping under the full system prompt. When that mapping is Apple (Apple is the selected provider, or no cloud provider is available), nothing is retried and the refusal stands.

---

## 9. Voice

### 9.1 `VoiceConversationController`

**Files:** `VoiceConversationController.swift` and its `+Audio`, `+Control`, `+Pipeline`, `+Speech` extensions, plus `VoiceAudioPipeline.swift`, `VoiceTurnPolicy.swift`, `VoiceEchoHeuristics.swift`.

`@Observable @MainActor final class`. States: `.idle`, `.starting`, `.listening`, `.thinking`, `.speaking`, `.triggerSpeaking`. `forceFinalizeTurn()` is the push-to-talk commit for noisy conditions.

### 9.2 Speech-to-text — `Emuqu/Sources/Assistant/Chat/STTProvider.swift`

`STTProviderKind`: `.apple` (`SFSpeechRecognizer`) or `.whisperKit` (`Emuqu/Sources/Assistant/Chat/WhisperKitSTTBridge.swift`), chosen by `UserSettings.preferredSTTProvider`.

### 9.3 Speech — `VoiceConversationController+Speech.swift`

`speak(_:voice:)` runs each chunk through, in order: the coach-voice perimeter scrub, `applyHallucinationGuard` (§11), the first-chunk preamble ("Flo here." plus the model name), then `TTSTextNormalizer.normalize`, and speaks it at 0.96 × the default rate with no pre/post delay. `SpokenTextChunker` buffers streamed tokens into sentences first.

---

## 10. Speech Text Normalization

### 10.1 `TTSTextNormalizer.swift`

`normalize(_:english:)` runs, for English voices only: `expandDomainAbbreviations` (BPM, HRV, zones…), `expandPaceStrings` (`8:45/mi` → "eight forty-five per mile"; a bare `8:45` is left alone), `expandYears` (`2026` → "twenty twenty-six"). It then hands the text to `PhoneticOverrides.speechAttributedString`.

### 10.2 `PhoneticOverrides.swift`

`resolve(_:)` runs three passes:

1. `expandZipCodes` — a five-digit ZIP becomes spaced digits when it follows "zip", "zip code" or "postal code", or follows an uppercase two-letter state code: `"Springfield, ST 00000"` → `"Springfield, ST 0 0 0 0 0"`. A ZIP+4 suffix becomes "dash" plus spaced digits.
2. `stripAuthoredMarkup` — the model can write `[[word|IPA]]`; the markup is removed from the text and the IPA attached as `accessibilitySpeechIPANotation`.
3. `domainRules` — homographs such as "live HR" get a same-length respelling ("lyve") plus an IPA hint. A domain hit inside an authored range is skipped.

---

## 11. MetricsVerifier — Hallucination Guard

**File:** `MetricsVerifier.swift`

- `verify(_:against: WorkoutAIContext?)` checks live-workout numbers (HR, power, α1…) in spoken text. `applyHallucinationGuard` replaces wrong values back to front.
- `verifyAppStateClaims(_:)` checks training-load and overnight numbers in the finished reply, normalizing spelled-out numbers first, and returns corrected text.
- `recordCorrections(_:)` stores discrepancies in a lock-guarded buffer capped at 4. `consumePendingCorrectionsBlock()` empties it into the next turn's variable prompt section under "# Last turn correction — DO NOT FABRICATE", so one fabrication produces one reminder.

---

## 12. Conversation Persistence and Truncation

### 12.1 `ChatTurn` — `Emuqu/Sources/Assistant/Providers/AIProvider.swift`

`id`, `role`, `text`, `createdAt`, `providerID`, `modelID`, `subsystem` (`AssistantSubsystem`: `.coach`, `.workoutVoiceCoach`, `.voiceConversation`, `.coachReport`), `routedTierRaw`, `localOnly`. Local-only turns (guard refusals) never leave the device.

### 12.2 `ConversationStore` — `Emuqu/Sources/Assistant/Chat/ConversationStore.swift`

`Assistant/conversation.json` in the App Group container (falling back to Documents), written atomically with `.completeFileProtection`. API: `load()`, `loadAsync()`, `save(_:)`, `clear()`.

### 12.3 Truncation — `Emuqu/Sources/Assistant/ViewModel/AssistantViewModel+Context.swift`

`conversationTokenBudget(for:)`: Apple 1,200; DeepSeek 60,000; Anthropic, OpenAI, Gemini, Grok 80,000. Tokens are estimated as characters / 4. `truncateForSend` drops oldest turns first, withholds local-only turns, always keeps the newest turn, and returns `(kept, dropped)`.

`updateSummaryWith(droppedTurns:provider:model:contextRendered:)` asks the provider for a paragraph of at most 120 words that keeps lasting context and drops stale live telemetry. It becomes `priorSummary`. It gives up after 5 s without blocking the turn.

---

## 13. Safety Gates

### 13.1 `MedicalQueryGuard.swift`

Runs before any model call. `evaluate(_:)` returns `.refuse(reply:)` for diagnosis-style and symptom queries; the refusal is a local turn and nothing leaves the device. Gated by the `medicalGuardEnabled` feature flag (on by default); the self-harm crisis reply is not gated. Tested by `MedicalQueryGuardTests`.

### 13.2 `ProviderConsentTracker.swift`

Apple is exempt. Each cloud provider needs a one-time acknowledgement, stored in `UserDefaults` under `assistant.consent.v<consentSchemaVersion>.<provider>`. Raising the schema version re-asks everyone. Fact extraction checks consent again before sending.

### 13.3 `CoachVoiceGuard.swift`

`scrub(_:)` replaces prohibited phrasing (diagnoses, danger-zone framings) and returns the scrubbed text, `didIntercept` and the triggers. It runs on each streamed sentence, on each spoken utterance, and once more on the finished message. Interceptions are logged by rule name only. Tested by `CoachVoiceGuardTests`.

### 13.4 Prompt-level boundary

`base` in `AIProvider+SystemPromptText.swift` opens with an information-access principle: answer general health and physiology questions factually rather than deflecting to "ask your doctor". A narrow MEDICAL BOUNDARY follows: no personal diagnosis, a fixed reply that points to a clinician or emergency services for red-flag symptoms, and a crisis-line reply for self-harm. The local guard in §13.1 still applies if the prompt is ignored.

---

## 14. UserFactsStore — Cross-session memory

**File:** `Emuqu/Sources/Assistant/Chat/UserFactsStore.swift`

`Assistant/user_facts.json` in the App Group container. API: `add(_:)` (deduped after normalizing case), `remove(_:)`, `clear()`, `systemPromptBlock()`.

### 14.1 Auto-extraction

When `autoExtractEnabled` is on, `runAutoFactExtraction(userText:assistantText:)` (`AssistantViewModel+Context.swift`) runs in the background after a turn. It prefers Apple, otherwise uses the active provider, and skips if that provider lacks consent. It asks for new persistent facts as `{"facts": [...]}`, gives up after 8 s, and stores only candidates that pass `factPassesAutoExtractFilter`.

### 14.2 Model-driven memory

The `AssistantMemoryNamespace` actions `assistant.memory.add`, `.remove` and `.clear` let the model save or forget a memory when the user asks.

---

## 15. DeterministicIntent — No-model answers

**File:** `Emuqu/Sources/Assistant/Facts/DeterministicIntent.swift`

Voice only. A hand-written list of narrow regex patterns (recovery score, resting HR, HRV, last night's sleep, last workout, and similar). `tryMatch(_:in:)` takes the first matching pattern; its handler reads local data and returns a sentence, or nil to fall through to the model. There is no confidence score; precision comes from keeping patterns narrow. `DeterministicIntentTests` asserts both expected matches and utterances that must not match (medical, advice, tool, web).

There is no production counter for how often this path fires; each hit only writes a debug log line.

---

## 16. AppleToolDispatcher

**Files:** `Emuqu/Sources/Assistant/Providers/AppleToolDispatcher.swift`, `Emuqu/Sources/Assistant/Providers/AppleFoundationToolAdapter.swift`

Adapts `[ToolSpec]` to FoundationModels `Tool` conformers that call back into the registry. Reached through `AppDependencies.current.providers.appleToolDispatcher`. `assembleContextAndTools` calls `setRegistry(factRegistry)` for Apple turns, and `runDispatchedTurn` calls `setRegistry(nil)` afterwards, so the dispatcher doesn't keep the registry alive past the turn (which would get in the way of `DataPurgeService`).

---

## 17. Action Bridges

- **Email** — `Emuqu/Sources/Assistant/Chat/AssistantEmailBridge.swift`, action `assistant.email.compose` (`subject`, `body`, optional `category`, `to`, `cc`). Stages a draft for `MFMailComposeViewController`; the user sends it, the app never does. `category` (`training` or `recovery`) picks default recipients.
- **Contacts** — `assistant.contacts.add` / `.remove`, plus a list read: a small address book used to resolve names in email.
- **Web search** — `web.search`, Tavily-backed, needs the user's own Tavily key and the web-search setting. Anthropic can instead use its server-side web search tool.

---

## 18. Tests

Suites covering this module include `PhoneticOverridesTests`, `TTSTextNormalizerTests`, `HallucinationFeedbackTests`, `DeterministicIntentTests`, `TurnRouterTests`, `MedicalQueryGuardTests`, `CoachVoiceGuardTests` and `FactCatalogValidationTests`, all in `EmuquTests/`.

---

## 19. Known Gotchas

1. **`MainActor.assumeIsolated` traps off the main actor.** Many sync resolvers use it. Moving the tool loop off-main breaks them.
2. **`AVAudioConverterInputBlock` is `@Sendable` but runs synchronously.** `WhisperKitSTTBridge` uses `@preconcurrency import AVFoundation` for this.
3. **Anthropic rejects duplicate tool names** with a 400; `CompactToolRouter.schema` dedupes.
4. **Apple can swap the selected voice for a fallback** at speak time, and not every voice honors IPA attributes. Respellings cover voices that don't.
5. **`AVSpeechSynthesizer` has no lexicon API.** Per-utterance IPA attributes are the only lever.
6. **`NumberFormatter(.spellOut)` reads `2026` as "two thousand twenty-six".** `TTSTextNormalizer.expandYears` handles years.
7. **The main-thread watchdog.** Keep resolver waits short; `WATCHDOG-WARN` in the log means one went over 4 s.
8. **Prompt cache.** Anything that changes per send (time, live HR) must stay in the variable half, or every send is a cache miss.
9. **Tool calls arrive whole.** Providers assemble `.toolUse` internally; `runToolUseLoop` never sees partial calls.

---

## 20. Telemetry

All through `debugLog(...)` (`Emuqu/Sources/Utilities/DebugLog.swift`). Settings → Troubleshooting shows warnings and errors under Recent Problems.

- `[Assistant] usage <provider>: input=… output=… cached=… cacheCreate=… hit_ratio=…`
- `[FactRegistry] action <name> exceeded 2.0s budget …` and `… WATCHDOG-WARN …`
- `[SmartRouter] tier=… → <provider>:<model>`, `[SmartRouter] voice-mode bypass …`, `[SmartRouter] action intent …`
- `[Hallucination guard] …`
- `[Assistant] medical-query guard fired …`
- `[Assistant] deterministic-intent hit …`
- `[VoiceConv] recognition error: <domain>:<code> …` — logged at info for the benign 1110 "no speech" code.
