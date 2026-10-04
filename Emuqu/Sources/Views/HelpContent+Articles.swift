import SwiftUI

// Split out from HelpContent.swift to keep the
// primary file under the 1500-line tech-debt budget.

extension HelpContent {
    // MARK: AI Assistant

    @MainActor static let aiAssistant = HelpCategory(
        id: "ai-assistant",
        title: "AI Assistant",
        icon: "sparkles",
        color: AppTheme.softGold,
        articles: [
            HelpArticle(
                id: "ai-overview",
                title: "What the AI Assistant Does",
                icon: "sparkles",
                summary: "An in-app coach that fetches your data and explains it in plain English",
                sections: [
                    .text("""
                        The ✨ tab in the middle of the bottom nav is an in-app chat. Every provider — Apple Intelligence included — pulls your data on demand using tool calls (see \"How the AI Gets Your Data\") so it's answering from real, current numbers, \
                        not a stale dump. The most common voice questions skip the AI entirely and answer in ~50 ms from a hand-curated pattern catalog (zero tokens, zero cost).
                        """),
                    .heading("What it's good at"),
                    .bullets([
                        "\"Why is my recovery score what it is today?\" — explains the factor breakdown and probable causes from your real scoring rationale",
                        "\"Should I train hard today?\" — uses your ATL / CTL / TSB and recovery score",
                        "\"What changed from yesterday?\" — day-over-day delta with real numbers",
                        "\"How does this compare to my baseline?\" — z-score interpretation",
                        "\"What does my HRV tell you?\" — translates RMSSD, SDNN, LF/HF, DFA α1 into plain English"
                    ]),
                    .heading("What it won't do reliably yet"),
                    .bullets([
                        "Deep sleep-stage aggregations over many months — recovery and HRV trends over any window (a week to a full year) now work via the trend tool, but a \"my deep sleep vs six months ago\" question may still be approximate",
                        "Map / photo analysis — the app doesn't have that capability; the assistant is instructed to say so once and move on",
                        "Guaranteed consistency across turns — models still occasionally flip a number without acknowledging; call it out and it should correct"
                    ]),
                    .tip("Use the suggestion chips above the input — they're written to draw out the most useful answers from any model.")
                ]
            ),
            HelpArticle(
                id: "ai-providers",
                title: "Choosing an AI Provider",
                icon: "rectangle.stack.badge.person.crop",
                summary: "Apple Intelligence by default; Claude / ChatGPT / Gemini / Grok / DeepSeek with your own key",
                sections: [
                    .heading("Apple Intelligence (default, free)"),
                    .text("Runs on your iPhone, so your questions and health data aren't sent to an AI company. A web search or a place lookup it makes goes to that service. Apple has the full tool catalog wired in — it can answer per-workout, route, and breadcrumb questions directly."),
                    .bullets([
                        "Free, private, works offline",
                        "Requires iOS 26 + Apple-Intelligence-capable device",
                        "Tight 4K context window — long conversations get oldest turns trimmed verbatim once the transcript hits 70% of budget",
                        "Apple's safety filter may refuse some health-adjacent questions; switch to a connected model when that happens"
                    ]),
                    .heading("Connected models (BYOK — bring your own key)"),
                    .text("Paste an API key from any of these vendors in Settings → Flo. The key stays in your iOS Keychain, never syncs to iCloud, and is sent only to that provider when you actively use it."),
                    .keyValue([
                        (label: "Claude", value: "Haiku 4.5 (cheap), Sonnet 4.6 (recommended), Opus 4.7 (top reasoning)"),
                        (label: "ChatGPT", value: "GPT-5.4 nano, mini (recommended), full, Pro"),
                        (label: "Gemini", value: "3.1 Flash-Lite (cheapest), 3 Flash (recommended), 3.1 Pro"),
                        (label: "Grok", value: "4.1 Fast instant, 4.1 Fast reasoning (recommended), Grok 4"),
                        (label: "DeepSeek", value: "Chat V3.2 (recommended), Reasoner V3.2 (thinking mode)")
                    ]),
                    .note("Connected models cost real money per message. Each provider's dashboard shows your usage. Anthropic prompt caching is enabled automatically — repeat sends in a chat run at ~10% of the first-send cost."),
                    .tip("Switch models anytime in the chat picker. The conversation, your remembered facts, and your data context all carry over to the new model.")
                ]
            ),
            HelpArticle(
                id: "ai-asking-questions",
                title: "Asking Questions",
                icon: "text.bubble",
                summary: "Pre-fab chips, free typing, voice input, and the Dashboard ✨ menu",
                sections: [
                    .heading("Pre-fab questions"),
                    .text("Above the input you'll see suggestion chips — How am I doing today, Why is my score, Should I train, What changed, etc. Tap to send instantly. These work the same on every provider, including Apple Intelligence."),
                    .heading("Free typing"),
                    .text("On connected models (Claude, ChatGPT, Gemini, Grok, DeepSeek), the text field accepts any question. Apple Intelligence is best for the pre-fab questions — its safety filter restricts free-form health discussion."),
                    .heading("Voice input (two modes)"),
                    .text("""
                        Two separate mic buttons: the dictation mic next to the text field does one-shot speech-to-text (tap → speak → tap → review → send). The mic at the top-left of the chat opens a continuous, hands-free voice conversation where the \
                        AI speaks replies aloud and you can interrupt by speaking. Speech is recognized on the iPhone where your language supports it, and by Apple's speech service where it doesn't, as the privacy policy says. \
                        Only the text of what you said goes to the chat's model. See \"Voice conversation mode\" for details \
                        and limitations.
                        """),
                    .heading("Dashboard shortcuts"),
                    .text("The ✨ button at the top-right of the Dashboard has one-tap shortcuts to common questions (Why is my score, Should I train, What changed). Tapping any auto-sends and switches to the chat tab."),
                    .heading("Asking about a past session"),
                    .text("In History (Dashboard → Recent → View all), long-press any session row → \"Ask Flo about this session\". The AI will get a question pre-filled with that session's date and key metrics.")
                ]
            ),
            HelpArticle(
                id: "ai-memory",
                title: "Cross-Session Memory",
                icon: "brain",
                summary: "Things the AI remembers across conversations",
                sections: [
                    .text("The assistant maintains a list of facts about you that get injected into every conversation across all providers. This is how it stops feeling like a stranger every time you open it."),
                    .heading("Adding facts"),
                    .bullets([
                        "Manually: Settings → Flo → \"What the AI Remembers\" → type a fact (e.g., \"I'm prepping for a marathon\", \"I have a stress fracture\", \"Always answer concisely\") and tap +",
                        "From a chat: long-press any message → Remember this. The message text becomes a fact",
                        "Auto-add: toggle \"Auto-remember things\" in Settings — after every response the assistant runs a small extraction pass and adds anything new it identifies. Off by default"
                    ]),
                    .heading("Removing facts"),
                    .text("Settings → Flo → swipe a fact to delete, or tap \"Forget everything\" to wipe the list."),
                    .note("Facts are stored on this device only. They are sent to whichever AI provider you actively chat with as part of the system prompt — never to anyone else."),
                    .warning("Be thoughtful about what you add. Auto-extracted facts come from the AI's interpretation of your messages and may be wrong; review periodically.")
                ]
            ),
            HelpArticle(
                id: "ai-citations",
                title: "Tappable Date Citations",
                icon: "calendar",
                summary: "Tap a date the AI mentions to open that session",
                sections: [
                    .text("""
                        When the AI mentions a date that matches a session in your archive (\"your session on April 14\"), the date renders as a tappable link. Tap it to open a quick-view sheet showing that session's score, HRV, sleep, training, and \
                        the cached interpretation we generated for it.
                        """),
                    .text("The quick-view is read-only. To edit a session, open it from History (Dashboard → Recent → View all)."),
                    .note("Citations resolve to sessions in the last ~30 days only. Older sessions can still be discussed by the AI but won't auto-link.")
                ]
            ),
            HelpArticle(
                id: "ai-privacy",
                title: "Privacy & What's Sent",
                icon: "lock.shield",
                summary: "What leaves your device, and what stays",
                sections: [
                    .heading("Apple Intelligence"),
                    .bullets([
                        "Runs entirely on your iPhone via Apple's Foundation Models framework",
                        "No AI company involved — works offline, apart from web searches and place lookups",
                        "Voice is transcribed on the iPhone where your language supports it, otherwise by Apple's speech service"
                    ]),
                    .heading("Connected models (Claude / ChatGPT / Gemini / Grok / DeepSeek)"),
                    .bullets([
                        "When you select a connected model and send a message, your chat history, your structured recovery context, and your remembered facts are sent to that vendor",
                        "Their privacy policy applies to what they do with the data and what they return",
                        "Emuqu does not log, filter, or moderate the responses",
                        "API keys live in the iOS Keychain (encrypted, device-local) and are never synced to iCloud or sent to any other vendor"
                    ]),
                    .heading("This is informational coaching"),
                    .text("AI responses are coaching from your data, not medical advice. For health decisions, talk to a qualified clinician.")
                ]
            ),
            HelpArticle(
                id: "ai-tool-use",
                title: "How the AI Gets Your Data",
                icon: "wand.and.stars",
                summary: "On-demand tool calls instead of a big data dump per message",
                sections: [
                    .text("""
                        Every provider — Apple Intelligence included — uses a pattern called \"tool use\" (or \"function calling\"). Instead of pasting your whole recovery archive into every message — which was slow, expensive, \
                        and prone to the model summarizing the dump wrong — the system prompt lists every available lookup as a callable tool. The model calls the one it needs; the app resolves it locally on your iPhone and hands back structured JSON; \
                        the model composes the answer.
                        """),
                    .heading("Why it matters"),
                    .bullets([
                        "Faster — the outgoing prompt is tiny and byte-identical every turn, so each provider's prompt cache hits from turn 2 onward. DeepSeek in particular no longer slows down after five turns.",
                        "More accurate on specific questions — the model asks for exactly the field it needs (\"the session on April 21\") rather than approximating from a flat dump.",
                        "Bounded cost — your full archive never leaves the device. Only the specific fields the model pulls cross the wire (and on Apple Intelligence, those stay on the phone)."
                    ]),
                    .heading("The 8-call budget"),
                    .text("One question triggers up to eight tool calls. Any call past the eighth returns a synthetic \"tool budget exceeded\" result so the model composes a brief failure response instead of looping forever on a bad argument."),
                    .heading("Apple Intelligence — context window"),
                    .text("""
                        Apple's on-device model has a 4,096-token combined ceiling (system + transcript + tools + response). Once a long voice conversation reaches 70% of that, the oldest user/assistant turn-pairs get dropped verbatim — never summarized \
                        — so quoted preferences (\"call me Chris\") survive. The most recent user turn is always preserved. If a long historical analysis needs the full transcript, switch to a cloud model.
                        """),
                    .heading("Deterministic shortcut"),
                    .text("""
                        The 15 most common voice queries (\"what's my recovery score\", \"how did I sleep last night\", \"what's my RHR\", etc.) bypass the LLM entirely — they answer from your data in ~50 ms with zero tokens. Anything ambiguous, parameterized, \
                        or in the speculation/medical/web band falls through to the model.
                        """)
                ]
            ),
            HelpArticle(
                id: "ai-voice-conversation",
                title: "Voice Conversation Mode",
                icon: "waveform.circle",
                summary: "Hands-free chat with interruptions — earbuds recommended",
                sections: [
                    .text("Tap the mic button at the top-left of the Flo tab to open a continuous voice conversation. Speak your question; the assistant answers aloud through AirPods or the speaker. You can interrupt while it's talking. Tap the mic again to end."),
                    .heading("Which model is talking?"),
                    .text("""
                        Voice mode bypasses the routing classifier. It uses the cloud model you selected; while Apple Intelligence is selected, it uses the first cloud provider whose key you've added and whose data-sharing notice \
                        you've accepted, or Apple if there is none. Mirrors how ChatGPT Advanced Voice / Gemini Live / Pi.ai handle voice — one model for the whole session so the conversation doesn't drift between models mid-sentence. The earcon \
                        names the active model out loud: \"Flo here. Sonnet.\" / \"Flo here. Apple.\" / \"Flo here. Haiku.\"
                        """),
                    .warning("This is an MVP. It works well on AirPods in a quiet room. Phone speaker in wind, traffic, or a crowd will produce rough edges. When it misbehaves, tell the assistant directly — the system prompt is written to respect what you report hearing, not deny it."),
                    .heading("Interrupting the AI"),
                    .text("Four gates fire an interrupt together: the AI has been speaking for 600 ms (grace window), your mic has sustained non-silence for 300 ms, you said at least TWO recognized words since the AI started, and those words don't look like an echo of what the AI just said."),
                    .bullets([
                        "Two-word minimum is deliberate — single words like \"stop!\" used to fire on coughs, footsteps, and car horns. Say \"hey stop\" or \"wait\" plus one other word.",
                        "Sustained loud noise alone (wind, traffic, HVAC) doesn't interrupt. Only decoded speech does.",
                        "The mic toggle and the chat Stop button also both fully interrupt — they kill the LLM, stop the text-to-speech immediately, and drop any queued audio so you don't keep hearing an answer you canceled."
                    ]),
                    .heading("Send now (push-to-talk)"),
                    .text("While the controller is listening for your turn, a paper-plane button sits in the voice status pill. Tap it to force-commit whatever transcript has been captured — useful when the recognizer stalls in wind or noise and won't auto-finalize."),
                    .heading("Voice-mode brevity"),
                    .text("When you send via voice, the assistant gets an extra directive to keep replies to 1–3 sentences, no markdown, no lists. For longer structured answers, use typed input instead."),
                    .heading("System interruptions"),
                    .text("Phone call, Siri, timer alarm — any of those tear voice mode down completely. It does NOT auto-resume because your context has probably shifted. Re-tap the mic to start a fresh conversation.")
                ]
            ),
            HelpArticle(
                id: "ai-limitations",
                title: "What the AI Can't Do (Yet)",
                icon: "exclamationmark.triangle",
                summary: "Honest list of where the assistant falls short right now",
                sections: [
                    .text("This page is the truth about where the assistant is still rough. Before calling out a bug, check whether it's on this list."),
                    .heading("Trends work; deep sleep-stage history is thinner"),
                    .text("""
                        The Fact Catalog exposes sessions, walks, training load, user profile, recent sleep, AND recovery/HRV trends over any window from a week to a full year — the trend tool (\"am I improving over time?\") reads your archive, so it \
                        works with no strap on and no reading today. What's still thin is deep multi-month sleep-STAGE aggregation, so \"how's my deep sleep compared to six months ago?\" may be approximate rather than exact.
                        """),
                    .heading("Hallucinations still happen"),
                    .text("""
                        The system prompt has hard rules against inventing numbers, but models still slip occasionally. Two useful reactions: (1) ask \"where did you get that number?\" — the prompt tells the model to investigate rather than double down; \
                        (2) tap the response and Regenerate on a different model.
                        """),
                    .heading("Apple Intelligence limits"),
                    .bullets([
                        "Apple's safety filter may refuse some health-adjacent questions; switch to Claude or ChatGPT when that happens.",
                        "First call after launch is slow (model cold-start). Subsequent calls are instant.",
                        "4K context window — very long conversations get oldest turns trimmed (verbatim, never summarized) once the transcript reaches 70% of budget. The most recent user turn is always preserved.",
                        "Reasoning depth is below cloud frontier models — for that reason Auto mode sends questions that need more of it, like multi-week trend analysis (\"compare this month to last month\"), to xAI Grok or DeepSeek once you've added its key and accepted its data-sharing notice."
                    ]),
                    .heading("Voice-mode rough edges"),
                    .bullets([
                        "No hardware AEC — we use software echo rejection on the transcript. AirPods are strongly recommended; phone speaker works but TTS can occasionally leak through and cause the AI to cut itself off.",
                        "Whispers don't cross the voice-activity threshold — speak normally or use Send now.",
                        "Wind and traffic can occasionally cause the recognizer to stall. Use Send now (paper-plane icon in the voice pill) to force-commit your turn.",
                        "If the recognizer stops hearing you mid-session (1110 errors), voice auto-restarts the task after ~1.5 s. If that loop keeps happening, toggle voice off and back on."
                    ]),
                    .heading("Model-pinning status"),
                    .text("""
                        Haiku 4.5 is pinned to its dated model ID (stable prompt caching). Sonnet 4.6, Opus 4.7, and every ChatGPT / Gemini / DeepSeek / Grok model ID are still floating aliases — a provider could silently repoint them and briefly disrupt \
                        caching. Will pin once dated IDs are confirmed.
                        """)
                ]
            ),
            HelpArticle(
                id: "ai-troubleshooting",
                title: "Troubleshooting",
                icon: "wrench.and.screwdriver",
                summary: "When the AI is slow, refuses, or gives bad answers",
                sections: [
                    .heading("Apple Intelligence is slow on the first call"),
                    .text("First call after a launch loads the on-device model — typically a few seconds. Subsequent calls are instant."),
                    .heading("Apple refused to answer"),
                    .text("Apple's safety filter blocks some health-adjacent questions. Switch to a connected model in the picker — they don't have the same restriction for the user's own physiological data."),
                    .heading("The answer cited wrong numbers"),
                    .text("Long-press the response → Regenerate to try again. If it still hallucinates, switch to Claude or GPT — they're noticeably better at adhering to structured data than smaller models."),
                    .heading("The conversation got slow"),
                    .text("""
                        Long chats automatically truncate older turns and replace them with a short summary. Tap ⋯ → Clear conversation to start fresh if responses degrade. With tool use, per-turn latency stays flat — if it's slow, the network is slow \
                        or the model is reasoning on a long chain of tools.
                        """),
                    .heading("The AI won't stop talking"),
                    .text("""
                        Tap the Stop button in the chat top bar — it now kills both the LLM response AND the text-to-speech. If you're in voice conversation mode, the mic button does the same when the AI is speaking. Interrupt-by-voice requires at least \
                        two recognized words (intentional, to avoid false triggers on coughs and passing cars).
                        """),
                    .heading("Voice mode isn't interrupting on my voice"),
                    .text("""
                        Four gates have to pass at once: a 600ms grace after the AI starts, 300ms of sustained voice, ≥2 new recognized words, and those words can't look like an echo of what the AI just said. If you're on phone speaker, AEC is weaker \
                        and gate 4 sometimes blocks real interrupts. Use AirPods, or tap the mic button to force-interrupt.
                        """),
                    .heading("Voice mode finalized my turn too early / won't finalize"),
                    .text("While listening, tap the paper-plane Send now button in the voice pill to force-commit whatever transcript was captured. If it never fires and the recognizer seems stuck, end and restart voice."),
                    .heading("The AI said it doesn't have data it should have"),
                    .text("""
                        The Fact Catalog covers sessions, walks, training load, profile, recent sleep, and recovery/HRV trends over any window up to a year (\"am I improving?\" now works from your archive, no strap needed). If the AI still says \"I don't \
                        have that\" for a trend question, regenerate or switch models. Specific-session questions (\"April 21\") should work on any connected model.
                        """),
                    .heading("Costs are higher than expected"),
                    .text("Check your provider's dashboard for actual usage. With tool use the payload per message is much smaller than before, but tool results still count against your tokens. Switching models breaks prompt caching until the new model's cache warms.")
                ]
            ),
            HelpArticle(
                id: "ai-navigation",
                title: "Asking the AI to Navigate",
                icon: "location.north.line.fill",
                summary: "\"Lead me back to where I parked\" / \"navigate home\" / \"nearest hospital\"",
                sections: [
                    .text("The AI can route you to a destination using Apple Maps. It builds a walking route from your current position and answers follow-up questions (\"what's next\", \"how far now\", \"am I there yet\") against your live position with no network round-trip."),
                    .heading("What you can ask"),
                    .bullets([
                        "\"Lead me back to where I started\" — uses the breadcrumb origin (engaged Get Me Back) OR the start of any recent workout (auto-archived)",
                        "\"Navigate me home\" / \"route me back home\" — uses the home address from Settings → Biometrics",
                        "\"Where's the nearest hospital\" / \"closest medical\" — picks from MKLocalSearch",
                        "\"Find me a parking lot\" / \"where's the nearest park\"",
                        "\"Walk me to Lakeside Park trailhead\" — types the address and the AI forward-geocodes it"
                    ]),
                    .heading("During the route"),
                    .text("\"What's next?\" → upcoming turn instruction + distance. \"How far now?\" → total remaining. \"Am I there yet?\" → flips true within 25 m of destination. \"Never mind\" / \"cancel that\" → drops the route."),
                    .note("Set your home address in Settings → Biometrics → Home Address before the AI can route you home."),
                    .warning("Routing is an aid, not a substitute for proper navigation. In poor weather, dense canopy, or urban canyons GPS accuracy degrades — the AI still answers but the directions may be off by tens of meters. For real emergencies, call your local emergency number.")
                ]
            ),
            HelpArticle(
                id: "ai-where-am-i",
                title: "Asking Where You Are",
                icon: "mappin.and.ellipse",
                summary: "Instant answers to \"what street am I on\" — no 30-second wait",
                sections: [
                    .text("""
                        Ask \"where am I\", \"what street am I on\", or \"which way am I going\" — the AI answers instantly because the app keeps a resolved-address cache warm at all times. The cache holds: the current road, locality, state, country, \
                        the nearest cross street + intersection (\"Maple Ave near Oak St\"), heading (cardinal + degrees), speed, and GPS accuracy.
                        """),
                    .heading("How fresh is the answer"),
                    .text("""
                        During a workout: every 25 m of movement OR 60 s, whichever first — same throttle as the live coach context. Outside a workout: refreshed whenever the app is foregrounded. The AI's answer is at most a few minutes old; if it's \
                        older than 5 minutes the tool falls back to a fast 5-second cold fetch.
                        """),
                    .heading("If GPS can't resolve your address"),
                    .text("In deep wilderness, water, or a brand-new road the geocoder may return nothing. Tell the AI verbally: \"I'm at the corner of Elm Pkwy and Hill Rd\" — it forward-geocodes and uses your stated location for subsequent questions.")
                ]
            )
        ]
    )

    // MARK: Get Me Back (offline navigation)

    @MainActor static let getMeBack = HelpCategory(
        id: "get-me-back",
        title: "Get Me Back",
        icon: "location.north.line.fill",
        color: AppTheme.primary,
        articles: [
            HelpArticle(
                id: "gmb-overview",
                title: "What Get Me Back Does",
                icon: "mappin.circle.fill",
                summary: "Drop a pin where you start, follow the compass arrow back. Offline.",
                sections: [
                    .text("""
                        Get Me Back is an offline breadcrumb-and-arrow trail recovery tool. You engage it at the trailhead (or wherever you want to set an anchor); the app drops a pin at your first GPS fix and quietly captures additional fixes as you \
                        move. Later, if you want to come back, you tap Open and a compass arrow on the screen physically points toward the origin. Hold the phone flat, rotate your body until the arrow points up the screen, walk that direction.
                        """),
                    .heading("Where to find it"),
                    .text("Fitness tab → \"Get Me Back\" card. First-time use shows a one-time disclaimer; tap \"I understand — engage\" to drop your pin."),
                    .heading("How accurate is it"),
                    .text("Honest about it. The arrow has four states based on your GPS horizontal accuracy:"),
                    .keyValue([
                        (label: "Strong (under 10 m)", value: "Crisp arrow, full opacity. Trust the heading."),
                        (label: "OK (10-30 m)", value: "Slightly faded. Reasonable to follow."),
                        (label: "Poor (30-100 m)", value: "Visibly fuzzy + softened outline. Take the direction with a grain of salt — interpret it as \"that general way\"."),
                        (label: "Waiting (over 100 m)", value: "Arrow disappears entirely. \"Wait for a better fix\" — pointing you in a wrong direction is worse than not pointing you at all.")
                    ]),
                    .warning("""
                        This is an aid to your awareness, not a replacement for proper navigation, search-and-rescue, or local emergency services. GPS varies (canopy, canyons, weather). In a real emergency call your local emergency number, or use iOS \
                        Emergency SOS — on iPhone 14 and later, Emergency SOS via satellite works where there's no cellular signal (press and hold the side button + a volume button).
                        """)
                ]
            ),
            HelpArticle(
                id: "gmb-actions",
                title: "Buttons and Actions",
                icon: "square.grid.2x2",
                summary: "Talk to AI, SOS, Clear, brightness slider",
                sections: [
                    .heading("Talk to AI"),
                    .text("""
                        Opens voice chat with the AI. Because the AI sees the active trail, you can ask things like \"how far back is the trailhead?\", \"should I turn around now?\", \"what direction is home?\", \"I'm getting tired, where can I rest?\". \
                        Network-required — the offline arrow keeps working regardless of whether the AI is reachable.
                        """),
                    .heading("SOS"),
                    .text("Confirmation alert with two paths: Cancel, or Call emergency services (your region's emergency number, dialled directly). The alert text reminds you about iPhone-14+ Emergency SOS via satellite if you have no cellular signal."),
                    .heading("Clear"),
                    .text("Three-way alert: Keep going / End and save / Discard. \"End and save\" archives the trail (default destructive action) so you can route back to it later via the AI. \"Discard\" deletes it permanently."),
                    .heading("Brightness slider"),
                    .text("Hidden behind the sliders icon. Drag down to dim the screen and save battery in the dark; the change reverts when you leave the view so we don't permanently mess with your phone.")
                ]
            ),
            HelpArticle(
                id: "gmb-history",
                title: "Your Trail History",
                icon: "tray.full",
                summary: "Up to 50 archived trails — including every workout's start point",
                sections: [
                    .text("""
                        Every GPS-bearing workout (Walk, Run, Bike, Trail Run, etc.) automatically archives its track as a breadcrumb trail when it ends — labelled \"Run on Apr 29, 8:13 AM\" and so on. Plus any Get Me Back trails you explicitly archive \
                        via the End-and-save button. Up to 50 trails are kept, newest first.
                        """),
                    .heading("Why this matters"),
                    .text("You can ask the AI \"lead me back to where I parked for my morning run\" and it'll find the workout's origin in the archive — no need to have engaged Get Me Back beforehand. The auto-archive is the safety net for \"I forgot to drop a pin.\"")
                ]
            )
        ]
    )

    // MARK: Your Data

    @MainActor static let yourData = HelpCategory(
        id: "your-data",
        title: "Your Data",
        icon: "lock.shield.fill",
        color: AppTheme.primaryDark,
        articles: [
            HelpArticle(
                id: "data-safety",
                title: "How Your Data Is Protected",
                icon: "checkmark.shield.fill",
                summary: "Multiple layers of backup and the hybrid recording safety net",
                sections: [
                    .text("Your HRV data is protected by multiple independent safety layers. Even in the worst case — app crash + Bluetooth disconnect + phone restart — your data survives."),
                    .heading("Safety Layers"),
                    .steps([
                        "H10 Internal Recording — Data stored on the device itself. Survives everything except device battery death.",
                        "BLE Streaming Backup — Parallel real-time capture. Independent failure domain.",
                        "Incremental Raw Backup — Every 5 minutes during recording, plus immediately on Bluetooth reconnection.",
                        "Session Archive — All completed sessions stored with SHA256 integrity verification.",
                        "iCloud Sync — Automatic CloudKit sync to your private Apple ID after every save. Deletes propagate too."
                    ]),
                    .heading("Privacy"),
                    .bullets([
                        "All health data stored locally on your device",
                        "iCloud sync goes to YOUR private CloudKit container — no third-party servers",
                        "No analytics SDKs, no advertising frameworks, no tracking of any kind",
                        "Deleting the app deletes its local data, raw RR backups included — iCloud sync or an export keeps it",
                        "You can export all data anytime from Settings → iCloud & Data",
                        "Apple Health export (HRV, HR, sleep) goes only into Apple Health — written by the app, never sent anywhere else"
                    ]),
                    .note("Deleting the app removes everything stored on this device, including the raw backups. To keep your sessions across a reinstall, leave iCloud sync on or export your data from Settings → iCloud & Data first.")
                ]
            ),
            HelpArticle(
                id: "recovering-data",
                title: "Recovering Lost Data",
                icon: "arrow.counterclockwise.circle.fill",
                summary: "What to do when something goes wrong",
                sections: [
                    .text("Several recovery paths exist depending on what happened."),
                    .heading("App Was Killed During Recording"),
                    .text("Go to Settings → iCloud & Data → Recover RR from Strap. This downloads the data stored on your H10's internal memory. Verity Sense stores data too — same recovery path."),
                    .heading("Session Missing from History"),
                    .text("Go to Settings → iCloud & Data → Recover Lost Sessions. This scans the raw backup directory for sessions that have backup files but aren't in the main archive. Tap \"Recover All\" or recover individual sessions."),
                    .heading("Accidentally Deleted a Session"),
                    .text("Go to Settings → iCloud & Data → Trash. Deleted sessions are kept for 90 days and can be restored with a single tap."),
                    .heading("Device Has Stored Data"),
                    .text("When you connect a device that has unrecovered data from a previous session, an alert appears automatically: \"Data Found on [Device Name]\". Tap \"Recover Data\" to download and analyze it."),
                    .tip("If a fetch from the device fails, the data is still safe on the device. You can retry as many times as needed — the app uses a 5-attempt retry with reconnection between attempts.")
                ]
            ),
            HelpArticle(
                id: "icloud-sync",
                title: "iCloud Sync",
                icon: "icloud.fill",
                summary: "How automatic sync works across your devices",
                sections: [
                    .text("iCloud sync uses Apple's CloudKit to automatically sync your sessions to your private Apple ID. No account setup, no third-party servers — just your Apple ID."),
                    .heading("How It Works"),
                    .bullets([
                        "Sessions upload automatically after every save — overnight, quick, import, restore, reanalyze",
                        "Deletes propagate across devices — delete on one, gone on all",
                        "Full sync on app launch and foreground return",
                        "Session data is ZLIB compressed before upload (~80-90% size reduction)",
                        "Sync status visible in Settings (idle / syncing / error / last sync time)"
                    ]),
                    .heading("On by Default"),
                    .text("iCloud sync is enabled by default during onboarding. You can toggle it anytime in Settings. Disabling it stops future syncs but doesn't delete already-synced data from iCloud."),
                    .note("iCloud sync covers session data (HRV analysis, scores, metadata and the session's RR intervals), encrypted on this device before upload. Your settings are synced too, encrypted the same way. During a recording, its raw RR backup also uploads this way every 5 minutes.")
                ]
            ),
            HelpArticle(
                id: "using-tags",
                title: "Using Tags",
                icon: "tag.fill",
                summary: "Organize sessions with system and custom tags for pattern analysis",
                sections: [
                    .text("Tags help you categorize your sessions so you can spot patterns — like how alcohol affects your recovery, or whether travel throws off your HRV."),
                    .heading("14 Built-In System Tags"),
                    .bullets([
                        "Morning — Auto-added when a recording ends between 4-10 AM",
                        "Post-Exercise — Tag after training sessions",
                        "Recovery — For dedicated recovery readings",
                        "Evening — Evening wind-down readings",
                        "Pre-Sleep — Readings taken just before bed",
                        "Stressed — When you're feeling stressed",
                        "Relaxed — Calm, rested state",
                        "Alcohol — Had drinks the night before",
                        "Poor Sleep — Rough night",
                        "Travel — Jet lag, different time zones",
                        "Late Meal — Ate late the night before",
                        "Caffeine — High caffeine intake",
                        "Illness — Feeling sick",
                        "Menstrual — Menstrual cycle tracking"
                    ]),
                    .heading("Custom Tags"),
                    .text("Create your own tags in Settings → Tags. Pick a name and one of 12 colors. Custom tags appear alongside system tags in the tag picker."),
                    .heading("Using Tags Effectively"),
                    .bullets([
                        "Add tags before or after recording on the Record tab",
                        "Edit tags later by swiping right on a session in History",
                        "Filter History and Trends by tag to see patterns",
                        "In Trends, use include/exclude filtering to compare tagged vs untagged sessions",
                        "Tags also appear in the Probable Causes section of your analysis summary — the app cross-references your tags with your metrics to identify what's driving your scores"
                    ]),
                    .tip("Consistent tagging over weeks reveals powerful patterns. Tag the factors you want to understand — alcohol, travel, poor sleep — then check Trends to see their impact on your HRV.")
                ]
            ),
            HelpArticle(
                id: "import-export",
                title: "Import & Export",
                icon: "square.and.arrow.up.on.square.fill",
                summary: "Move data in and out of Emuqu",
                sections: [
                    .heading("Importing Data"),
                    .text("Go to Settings → iCloud & Data → Import RR Data to bring in data from other apps and devices."),
                    .keyValue([
                        (label: "CSV", value: "Comma-separated RR intervals — auto-detects ms vs seconds"),
                        (label: "JSON", value: "Array of RR interval values"),
                        (label: "TXT", value: "Plain text — one interval per line"),
                        (label: "Kubios", value: "Export files from Kubios HRV software"),
                        (label: "EliteHRV", value: "Summary CSV with pre-computed metrics (batch import)")
                    ]),
                    .note("Imported data requires at least 60 RR intervals in the 200-2500ms range. The app auto-detects the format and converts seconds to milliseconds if needed."),
                    .divider,
                    .heading("Exporting Data"),
                    .text("Go to Settings → iCloud & Data → Export Data."),
                    .keyValue([
                        (label: "RR Intervals (CSV)", value: "Raw beat-by-beat data with timestamps"),
                        (label: "Summary (CSV)", value: "Session date, type, score, RMSSD, tags, notes"),
                        (label: "All Sessions (JSON)", value: "Complete session data including analysis results")
                    ]),
                    .heading("PDF Reports"),
                    .text("On the morning results screen, tap \"Email Report\" and choose the sections. Emuqu builds a PDF report covering metrics, visualizations (HR chart, Poincaré plot, PSD, tachogram) and the analysis summary, and attaches it to a new email.")
                ]
            )
        ]
    )

    // MARK: Personalization

    @MainActor static let personalization = HelpCategory(
        id: "personalization",
        title: "Personalization",
        icon: "paintbrush.fill",
        color: AppTheme.primary,
        articles: [
            HelpArticle(
                id: "language-settings",
                title: "Language",
                icon: "globe",
                summary: "Switch the app to any of 17 supported languages",
                sections: [
                    .text("Emuqu supports 17 languages. You can switch at any time. Most of the app updates right away; a few labels, and the permission prompts iOS shows, change the next time you open the app."),
                    .heading("Changing Language"),
                    .steps([
                        "Go to Settings → Language.",
                        "Tap the language you want.",
                        "Most of the app switches right away. Close and reopen Emuqu to switch the rest."
                    ]),
                    .heading("Supported Languages"),
                    .bullets([
                        "English, Spanish, French, German, Italian, Dutch, Portuguese (Brazil), Russian",
                        "Japanese, Korean, Chinese (Simplified), Arabic",
                        "Danish, Norwegian Bokmål, Swedish, Finnish, Icelandic"
                    ]),
                    .heading("Translated Analysis (iOS 18+)"),
                    .text("""
                        On iOS 18 and later, dynamically generated text — your analysis summary, score breakdowns, readiness messages, and coaching tips — is translated on-device using Apple's Translation framework. No internet connection required. The \
                        first time you use a language, iOS may prompt you to download the language pack.
                        """),
                    .note("On iOS 17, static labels (buttons, tabs, headings) appear in your chosen language, but analysis summaries and coaching text remain in English.")
                ]
            ),
            HelpArticle(
                id: "color-themes",
                title: "Color Theme",
                icon: "paintpalette.fill",
                summary: "Choose from six accent color themes",
                sections: [
                    .text("Customize the look of the entire app with one of six color themes."),
                    .heading("Changing Your Theme"),
                    .steps([
                        "Go to Settings → Appearance → Color Theme.",
                        "Tap a color swatch to preview it.",
                        "The change applies everywhere — dashboard, charts, buttons, gradients, and the splash screen."
                    ]),
                    .heading("Available Themes"),
                    .keyValue([
                        (label: "Blue", value: "Default — calm and clinical"),
                        (label: "Teal", value: "Cool and fresh"),
                        (label: "Indigo", value: "Deep and focused"),
                        (label: "Purple", value: "Rich and distinctive"),
                        (label: "Rose", value: "Warm and soft"),
                        (label: "Orange", value: "Bold and energetic")
                    ]),
                    .text("Each theme has optimized light and dark mode variants with proper contrast ratios. Your choice syncs to iCloud so it follows you across devices.")
                ]
            ),
            HelpArticle(
                id: "lifetime-purchase",
                title: "Lifetime Access",
                icon: "star.fill",
                summary: "One-time purchase to unlock all features",
                sections: [
                    .text("Emuqu uses a one-time lifetime purchase — pay once, own it forever. No subscriptions, no recurring charges."),
                    .heading("What's Included"),
                    .bullets([
                        "Full access to all current and future features",
                        "Unlimited recordings and history",
                        "All analysis tiers, training load integration, and trend analysis",
                        "iCloud sync across all your devices"
                    ]),
                    .heading("Free Trial"),
                    .text("""
                        New users can try everything free for 30 days. The trial starts when you tap "Start 30-Day Free Trial" and never charges you. \
                        That is long enough to build the 14 nights the Dashboard waits for before it shows your recovery score. \
                        When it ends, the app locks until you buy the one-time unlock. Everything you recorded is kept.
                        """),
                    .heading("Restoring Your Purchase"),
                    .text("If you reinstall the app or switch devices, go to Settings and tap \"Restore Purchases\". Your purchase is tied to your Apple ID and can be restored on any device signed into the same account."),
                    .note("Your purchase is a standard App Store transaction managed entirely by Apple. Emuqu never sees your payment information.")
                ]
            )
        ]
    )

    // MARK: App Navigation

    static let appNavigation = HelpCategory(
        id: "app-navigation",
        title: "App Navigation",
        icon: "rectangle.grid.1x2.fill",
        color: AppTheme.mist,
        articles: [
            HelpArticle(
                id: "dashboard-guide",
                title: "Your Dashboard",
                icon: "heart.text.square.fill",
                summary: "Understanding the daily recovery dashboard",
                sections: [
                    .text("The Dashboard is your daily starting point. It shows your recovery status at a glance and drills into every component."),
                    .heading("Recovery Score Ring"),
                    .text("The large circular gauge (0-100) is your composite recovery score. It uses ln(RMSSD) z-score normalization against your personal 60-day baseline, automatically selecting the best available scoring tier (HRV-only, HRV + Sleep, or HRV + Sleep + Vitals at 60/25/15)."),
                    .keyValue([
                        (label: "90-100 · Excellent", value: "Well above your usual range"),
                        (label: "75-89 · Good", value: "Above your usual range"),
                        (label: "60-74 · Fair", value: "Your normal range — the most common"),
                        (label: "45-59 · Pay attention", value: "Below your usual range — an easy day is worth considering"),
                        (label: "30-44 · Low", value: "Well below your usual range"),
                        (label: "0-29 · Very low", value: "Far below your usual range — worth looking at sleep, illness and recent load")
                    ]),
                    .heading("Training Readiness"),
                    .text("When exercise data exists, a horizontal zone bar appears below the ring showing your readiness to train: Rest / Fatigued / Moderate / Ready."),
                    .heading("Dashboard Cards"),
                    .bullets([
                        "HRV Card — RMSSD value and label. Tap for the HRV Detail View with 30-day trends and nervous system analysis.",
                        "Sleep Card — Hours slept and efficiency. Tap for the Sleep Detail View with stages, vitals, and adjustment controls.",
                        "Training Load Card — ACR gauge with ATL/CTL/TSB. Appears when training integration is enabled. Tap for the Training Detail View.",
                        "Analysis Summary — What your scores mean in plain language, with probable causes and actionable recommendations."
                    ]),
                    .heading("Action Buttons"),
                    .bullets([
                        "\"View Full Report\" — Opens the full detailed report for today's session (from the morning-results flow)",
                        "\"Take a Reading\" — Navigates to the Record tab (shown when no reading exists today)",
                        "Paper-plane button — Email a recovery, daily or workout report as a PDF"
                    ]),
                    .tip("Pull down to refresh. The dashboard also updates automatically when you record a new session or when Apple Health provides new sleep data.")
                ]
            ),
            HelpArticle(
                id: "history-guide",
                title: "Browsing History",
                icon: "list.bullet.rectangle.fill",
                summary: "Search, filter, and manage all your past sessions",
                sections: [
                    .text("History (Dashboard → Recent → View all) shows all your recorded sessions, organized chronologically and grouped by time period (Today, Yesterday, This Week, Last Week, then by month)."),
                    .heading("Filtering"),
                    .bullets([
                        "Session Type — Filter by All, Overnight, Naps, Quick, or Breathe",
                        "Tags — Tap system or custom tags to filter sessions matching those tags",
                        "Search — Type to search by date, tag name, or notes"
                    ]),
                    .heading("Session List"),
                    .text("Sessions are paginated (10 at a time) for fast loading. Scroll to the bottom to load more. Each row shows the session type icon, time, tags, RMSSD, and recovery score with color coding."),
                    .heading("Actions"),
                    .bullets([
                        "Tap a session — Opens the full Recovery Report with all metrics, charts, and analysis",
                        "Swipe left — Delete the session (kept in the Trash for 90 days; the deletion syncs to iCloud)",
                        "Swipe right — Edit tags and notes",
                        "Long-press — \"Ask Flo about this session\" pre-fills a question in the Flo tab with the session's date, score, and key metrics"
                    ]),
                    .tip("The recovery score in each row shows a breakdown: the score plus the tier components (HRV, Sleep, Vitals) that contributed to it.")
                ]
            ),
            HelpArticle(
                id: "trends-guide",
                title: "Tracking Trends",
                icon: "chart.line.uptrend.xyaxis",
                summary: "Long-term pattern analysis across your sessions",
                sections: [
                    .text("Trends (More → Trends) reveals patterns across multiple sessions, helping you understand what drives your recovery over time."),
                    .heading("History Calendar"),
                    .text("A month calendar at the bottom carries two signals for each day: the cell's fill shows that day's training load, and a small dot in its corner shows your 1–5 morning feeling. Tap a day to open its readings."),
                    .heading("Period Selector"),
                    .text("Choose your analysis window: 7, 14, 30 or 90 days, or All."),
                    .heading("Trend Chart"),
                    .text("""
                        The main chart shows one metric over time, from overnight readings only. Use the tabs to switch between Recovery, RMSSD, SDNN, Mean HR, Balance (LF/HF), HF Power and Stress. \
                        Each reading is a dot, amber when it falls outside your normal range; the solid line is a 7-reading rolling average, and the shaded band is your 60-day mean ±1 SD. Drag across the chart to compare any reading with your baseline.
                        """),
                    .heading("Statistics Grid"),
                    .text("Below the chart, four cards show your averages for the period: Recovery, RMSSD, heart complexity (DFA α1) and the Stress index. Each says how many readings it covers and, where a baseline exists, how far the average sits from it."),
                    .heading("Tag Filtering"),
                    .text("Filter to the readings that carry one tag: Morning, Post-Exercise, Recovery or Evening. Useful for comparing, say, post-exercise readings with the rest."),
                    .heading("Insights"),
                    .text("The app auto-generates insights based on your data — trend direction, notable patterns, and what they might mean for your training."),
                    .note("You need at least 2 sessions to see trends. The more data you have, the more meaningful the patterns become.")
                ]
            ),
            HelpArticle(
                id: "breathing-guide",
                title: "Breathing Mandala",
                icon: "wind",
                summary: "Coherent breathing during quick readings",
                sections: [
                    .text("During Quick Readings, a breathing mandala visual guides you through slow paced breathing — a pattern shown to increase the size of the heart-rate oscillation during the reading."),
                    .heading("How It Works"),
                    .text("""
                        The mandala follows a 5.5 breaths-per-minute pattern (approximately 11-second cycles), close to the \"resonance frequency\" at which respiratory sinus arrhythmia is largest for most people. \
                        The exact rate is individual — roughly 4.5 to 6.5 breaths per minute — so 5.5 is a good default rather than your personal optimum.
                        """),
                    .note("""
                        Which numbers actually move, and why it surprises people. Slow breathing genuinely enlarges the heart-rate oscillation, so RMSSD, SDNN and total power all rise. HF POWER USUALLY FALLS. That is not a fault: HF is defined as \
                        0.15–0.40 Hz, which is 9–24 breaths per minute, and 5.5 breaths per minute is 0.09 Hz — below the HF floor and inside LF (0.04–0.15 Hz). So the enlarged oscillation moves OUT of HF and into LF, and LF/HF rises. A higher \
                        LF/HF during a paced reading says nothing about stress; it is the arithmetic of where the peak sits.
                        """),
                    .heading("Voice Guide"),
                    .text("Toggle the voice guide on or off during recording. When enabled, spoken cues (\"Breathe in\" / \"Breathe out\") are synced to the visual animation."),
                    .heading("Why It Matters"),
                    .bullets([
                        "Paced breathing genuinely enlarges the beat-to-beat oscillation, so the RMSSD is real, not inflated — but see the note above on which band it lands in",
                        "Controlled breathing during a reading gives a more stable, reproducible measurement",
                        "The mandala is optional — you can ignore it and breathe naturally"
                    ]),
                    .tip("For the most consistent baseline, choose one approach and stick with it — either always use the mandala or always breathe naturally. Mixing approaches adds variability that makes day-to-day comparison harder.")
                ]
            )
        ]
    )
}
