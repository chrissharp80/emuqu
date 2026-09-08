# Code Refactor Specification

## Purpose

This document is a **standing refactor specification** — principles, not a feature
inventory. Apply these to any code module submitted for refactoring. The goal is
production-grade code that is **bulletproof**, **trivially debuggable**,
**fully modular**, and **unmistakably professional**. This codebase is maintained
by a solo developer — there is zero margin for ambiguity, hidden state, or
cleverness that sacrifices clarity.

> **New to the codebase?** Start with the [`MAINTAINERS.md`](MAINTAINERS.md)
> guide — the map of the whole app (structure, file index, flows) that links to
> every other doc.
>
> **For "what does the app do today?"** — see [`README.md`](../README.md) and
> [`USERS_MANUAL.md`](USERS_MANUAL.md). For architecture and subsystem deep dives,
> [`ARCHITECTURE.md`](ARCHITECTURE.md). For data flow,
> [`FLOWCHART.md`](FLOWCHART.md). For the AI assistant + fact catalog,
> [`VOICE_AND_TOOL_USE.md`](VOICE_AND_TOOL_USE.md). For public APIs,
> [`API_REFERENCE.md`](API_REFERENCE.md).
>
> This file intentionally has no "as of date" header — the principles below
> hold across all build phases. Every sweep through the codebase should be
> measured against them.

---

## Core Philosophy

- **Refactor = behavior preserved, structure upgraded.** If behavior changes, it is a feature change and must be separated.
- **Functional core, imperative shell.** Pure logic inside; side effects at the edges.
- **Make illegal states unrepresentable.** Encode invariants in types/structures/validation, not in tribal knowledge.
- **Small, explicit, boring.** Boring code ships, debugs, and refactors like a weapon.

---

## Vocabulary Contract (Framework-Agnostic)

When this spec uses the following terms, it means the *capability*, not a specific library/framework:

- **Module boundary:** The smallest unit you can reason about independently (file/package/class/component). A module has one public surface and one responsibility.
- **Public API:** Anything callable/importable from outside the module boundary. Public API is sacred.
- **Side-effect boundary:** Any interaction with the outside world (I/O, network, DB, time, randomness, threads, UI, OS calls, environment/config).
- **Explicit dependency wiring:** The module does not reach out and create/locate its dependencies inside business logic. Dependencies are provided by the caller or a single wiring layer.
- **Typed/explicit errors:** Errors are categorized and intentional (enum/class/code/tagged union/etc.), not “stringly” or generic exceptions unless the language forces it.
- **Structured logging:** Machine-parsable events *if supported*. Otherwise: consistent, greppable log lines with stable keys/prefixes.
- **Test doubles:** Any substitute for a real dependency (fake/in-memory/simulator/record-replay/mock/stub). The *form* is irrelevant; the ability to verify behavior is the point.

---

## Non-Negotiable Principles

### 1) Pure Functions First

Every function that *can* be pure *must* be pure. A pure function:

- Takes explicit inputs (no reaching outside its scope)
- Returns a value (no relying on side effects to communicate results)
- Produces the same output for the same input, every time
- Mutates nothing — not its arguments, not external state, nothing

If a function must perform a side effect (network call, disk write, sensor read, UI update), isolate it at the boundary. The interior of the codebase should be a pure functional core wrapped in a thin imperative shell.

### 2) Immutable Data Flow

Data flows in one direction. Never mutate shared state. Prefer value semantics where available. When state must change, produce a new version — don't modify in place. If the language makes immutability hard, enforce it by convention: copy-on-write patterns, defensive copying at boundaries, and *no shared mutable state*.

### 3) Single Responsibility — For Real

Each function does exactly one thing. Each module owns exactly one concern. If you need the word “and” to describe what a function does, split it.

- Structural rule: one reason to change.
- Functional rule: one transformation step in a pipeline.

### 4) Small Functions, Meaningful Names

- Functions: 5–15 lines is the target. 20 is a yellow flag. 30+ gets broken up.
- Names: `calculateOvernightHrvBaseline` not `processData`. `filterValidReadings` not `handle`.
- No abbreviations unless universally understood in the domain.
- Boolean functions and variables read as assertions: `isValidReading`, `hasMinimumSamples`, `shouldRetryConnection`.

### 5) Composition Over Inheritance

Build complex behavior by composing small functions, not by extending class hierarchies. Prefer:
`input → validate → transform → decide → format → output`

Use interfaces/protocols/abstract types only when they *reduce coupling* and *reduce duplication*. No “pattern theater”.

### 6) Explicit Error Handling

No swallowed errors. No empty catch blocks. No “this should never happen” without handling the case where it does.

- Prefer explicit error categories over generic exceptions where possible.
- Every failure mode must be visible at the call site (in signature, return shape, or documented contract).
- Errors must include enough context to debug without guessing (operation, identifiers, key parameters—not secrets).

### 7) Zero Tolerance for Magic

- No implicit dependencies
- No global mutable state
- No hidden side effects
- No “stringly-typed” APIs where real types/enums exist
- If something can fail, the interface must say so

---

## Refactoring Process

### Step 1: Audit

Before changing anything, document:

- What does this module do? (one sentence)
- What are its inputs and outputs?
- What state does it touch?
- Where are the side effects?
- What are the implicit dependencies?
- What would break if you deleted this file?

### Step 2: Extract Pure Logic

Identify all business logic, calculations, transformations, and decision-making currently tangled with side effects. Extract them into pure functions. This is the highest-value move: it instantly makes logic testable and debuggable in isolation.

### Step 3: Establish Data Flow

Map how data moves through the module. Refactor toward a clear pipeline:

```
Input → Validate → Transform → Process → Format → Output
```

Each stage is a pure function. Side effects happen only at the edges.

### Step 4: Name Everything

Rename functions, variables, and types until the code reads like documentation. A developer six months later should understand the module by reading identifiers alone. No comments needed to explain *what* — only *why* when reasoning is non-obvious.

### Step 5: Enforce Module Boundaries

Each module exposes a clean public API. Internal implementation details are private. Dependencies flow one direction (no circular imports). If module A needs something from module B, that dependency is explicit and one-way.

### Step 6: Handle Every Edge Case

Every code path must be accounted for:

- empty inputs
- missing/invalid data
- partial failures
- timeouts/retries (where relevant)
- resource cleanup
- concurrency hazards (if concurrency exists)

No “default” behavior that hides broken states.

---

## Code Structure Standards

### File Organization

- One module, one concern.
- Group by feature/domain, not by generic technical layer names.
- Keep private helpers close to where they’re used.
- Delete unused exports and dead utilities.

### Function Ordering Within a File

1. Public API (top)
2. Core pure logic (middle)
3. Side-effect boundary adapters (bottom)
4. Private helpers last

### Explicit Dependency Wiring (No Hidden Instantiation)

Never instantiate/locate dependencies inside business logic. Dependencies must be provided through an explicit wiring point (constructor/params/factory/module init/etc.). This is not about DI frameworks — it’s about making dependencies **visible**, **replaceable**, and **auditable**.

Rules:
- The *only* place allowed to create real dependencies is the wiring layer / boundary shell.
- Pure logic never imports “the world”. It only accepts what it needs.

---

## Functional Patterns to Apply

### Pipeline / Compose

Turn “do everything” functions into a pipeline of small transformations. Prefer readable steps over clever chaining.

### Map / Filter / Reduce Over Manual Loops

Use higher-level iteration patterns when they reduce incidental complexity. If they obscure control flow, use a simple loop—clarity wins.

### Closures for Configuration

Use closures/functions to bind configuration once, then operate with clean signatures.

### Option/Result Shapes Over Null Checks

Prefer explicit “present/absent” and “success/failure” shapes to scattered null checks and sentinel values. Where the language lacks these, emulate them with consistent conventions.

---

## What NOT to Do

- No sweeping rewrites.
- No “while I’m here” changes.
- No style-only refactors without structural payoff.
- No new abstractions that do not delete more complexity than they introduce.
- No clever metaprogramming/macros/reflection as a “cleanup”.
- No new global state, no new hidden state.

---

## Eliminate Bloat, Duplication, and Dead Weight

### Dead Code Removal

Delete unused code. If you’re not sure, prove it’s used. If you can’t prove it’s used, quarantine then delete.

### Duplication Elimination (DRY — But Smart)

Remove duplication when it’s truly the same concept. Do **not** DRY away clarity. Two similar functions are fine if they represent distinct domain intent.

### Bloat Reduction

Prefer fewer moving parts:
- fewer files
- fewer types
- fewer layers
- fewer configuration knobs

### Dependency Audit

- Remove unnecessary dependencies.
- Replace heavy dependencies with small local code when it reduces surface area and risk.
- Every dependency must earn its place: clear value, maintained, minimal footprint.

### Size Benchmarks

- Files should be readable in one sitting.
- Modules should be comprehensible without jumping across the codebase.
- If a module requires a “tour”, it’s too big.

---

## Concurrency Safety

If concurrency exists in the module, it must be explicit and safe.

- No shared mutable state across threads/tasks unless guarded.
- No race conditions, no unsafe caches, no non-atomic updates.
- Cancellation and timeouts must be handled intentionally.
- Any background work must have a clear ownership lifecycle.

If concurrency does not exist here, do not introduce it during a refactor.

---

## Testability Contract

Refactoring without tests is just rearranging furniture in a burning building. Every refactored module must include:

- **Test scaffolding at minimum.** If full test coverage isn't in scope for this pass, the structure must be in place: test files created, test targets configured, key functions stubbed with placeholder tests.
- **Representative tests for every pure function.** Pure functions are trivially testable — there is no excuse for skipping them. Cover the happy path, edge cases (empty input, boundary values, malformed data), and at least one failure case.
- **Test doubles for all injected dependencies.** Provide substitutes so tests run without real side effects (I/O/network/sensors/DB). The exact technique is irrelevant; the ability to verify behavior is required.
- **Behavioral parity tests** (see Migration Safety below).

---

## Migration Safety

When refactoring an existing system, behavioral parity is non-negotiable.

- Write parity tests comparing old vs. new behavior where feasible.
- Preserve output formats, error shapes, and side effects unless explicitly changing behavior.
- If refactoring transforms data, validate round-trip integrity.
- If the code interacts with external systems, use recorded fixtures or a controlled test environment.

---

## Logging and Observability

Clean code still breaks in production. When it does, you need to know what happened without attaching a debugger.

- Add structured logging at every side-effect boundary. Log what went in, what came out, and whether it succeeded or failed.
- Logs must carry **correlation** (request/job/session IDs) so a single flow can be traced end-to-end.
- Use consistent levels: error (action required), warn (degraded), info (significant transitions), debug (development-only).
- Logs must be **stable**: consistent keys/messages so they can be searched and aggregated.
- Never log sensitive user data. Redact/sanitize before logging.
- If the platform supports crash-report breadcrumbs, add them at key decision points so crash reports tell a story, not just a stack trace.

---

## Performance-Sensitive Paths

Refactors must not silently tank performance.

- Identify hot paths before refactoring.
- After refactoring, measure performance using whatever harness exists (benchmark/load/profiling script).
- If performance changes, it must be explained, justified, and accepted explicitly.
- Prefer algorithmic clarity over micro-optimizations. Optimize only where it matters.

---

## Data Model Versioning

If the codebase persists data (DB, files, caches), refactors must respect schema evolution.

- Persisted structures must be versioned or safely migratable.
- Never break backwards compatibility unless the migration path is real and verified.
- Validate migrations with real samples (fixtures) and parity checks.

---

## API Contract Stability

Public API changes are forbidden in refactors unless explicitly requested.

- Do not rename exported symbols, change signatures, or alter behavior as part of “cleanup”.
- If public API must change, introduce a compatibility layer and deprecate intentionally.
- Keep interfaces small and intention-revealing.

---

## Graceful Degradation and Recovery

Failure is normal; chaos is optional.

- When dependencies fail, degrade gracefully with explicit error signals.
- No silent fallbacks that hide data corruption or broken systems.
- Retries must be bounded and observable.
- Recovery paths must be deterministic and testable.

---

## Refactor Safety Protocol

Refactors break things. This is the most common and most preventable source of bugs. The rules below exist to ensure refactored code works **exactly as well** as what it replaced — verified, not assumed.

### Before Touching Anything

- **Build and run the existing code.** Confirm it compiles/runs and passes any existing checks before making a single change. If it's already broken, fix that first (separately).
- **Identify every entry point.** Map every call site, public function, callback, event handler, scheduled job, and integration hook. These are the contracts you cannot break.
- **Snapshot current behavior.** For critical paths, capture concrete input/output pairs (fixtures, recordings, screenshots, logs—whatever creates a verifiable baseline).
- **Mark side-effect boundaries.** List every external dependency and every stateful resource touched.

### During the Refactor

- **One change at a time.** Do not rename + restructure + optimize in the same step. Each transformation is a single, verifiable move.
- **Verify continuously.** Keep the module in a working state. If it stops compiling/running, undo the last move and re-approach. Never accumulate breakage.
- **Never refactor and change behavior simultaneously.** If you discover a bug, finish the structural refactor first, then fix the bug as a separate change.
- **Preserve all edge-case handling.** If the original code handled a weird case, the refactor must handle it too unless explicitly removing that behavior.
- **No new surface area by accident.** No new public API, no new config knobs, no new global state, no new dependencies unless they delete more risk than they add.

### After the Refactor

- **Run the full project verification suite.** Entire build + all tests + all checks. Not just the files you touched.
- **Manually verify critical paths.** Exercise the primary workflows and compare outputs to the baseline captured up front.
- **Diff review.** Read the entire diff line-by-line. Look for accidental behavior changes, lost error handling, dead extractions, and subtle reorderings.
- **Temporary dual-pathing is allowed only for verification.** If you keep old code around to compare outputs, it must be removed immediately once parity is confirmed.

### The Cardinal Rule

**If the refactored code cannot be proven to behave identically to the original for all known inputs, the refactor is not complete.** Ship the working version, not the pretty version.

---

## Refactor Completion Checklist (Hard Gate)

Before considering any refactored module complete, verify:

### Correctness & Parity
- [ ] Behavioral parity verified — same inputs produce same outputs before and after (unless a behavior change was explicitly requested).
- [ ] All edge cases preserved or intentionally redesigned with explicit approval.
- [ ] Full project verification suite passes (build/checks/tests) with **zero new warnings**.

### Purity, State, and Flow
- [ ] Every function that can be pure, is pure.
- [ ] No shared mutable state (or it is explicitly guarded where concurrency exists).
- [ ] Data flows in one clear direction; no hidden backchannels or implicit state.

### Boundaries & Dependencies
- [ ] Side effects are isolated at boundaries; the core is pure logic.
- [ ] Dependencies are explicitly wired (provided), not instantiated/located inside business logic.
- [ ] No circular dependencies; module boundaries are clean.

### Clarity & Complexity
- [ ] Function names describe exactly what they do.
- [ ] Code reads top-to-bottom without jumping around.
- [ ] Nesting depth is **≤ 2** throughout (rare, justified exceptions only).
- [ ] Functions are **≤ 20 lines** (rare, justified exceptions only).
- [ ] No wrapper functions that add zero value.
- [ ] No unnecessary abstraction layers (interfaces with one implementation, factories that build one thing) unless they *remove* coupling elsewhere.

### Errors & Observability
- [ ] Every error case is handled explicitly (no swallowed errors, no empty catches).
- [ ] Errors are categorized (explicit taxonomy) and include actionable context (no secrets).
- [ ] Logging at every side-effect boundary with correlation identifiers.
- [ ] No sensitive data in logs; redaction rules applied.

### Data, Config, and Magic
- [ ] No magic numbers/strings in logic; constants/config are centralized and named.
- [ ] No implicit environment/config behavior; configuration is explicit at boundaries.
- [ ] Persisted data models remain compatible, versioned, and migratable (where applicable).

### Hygiene & Footprint
- [ ] All dead code, commented-out code, and unused imports removed.
- [ ] Duplication reduced where it represents the same concept; clarity preserved where concepts differ.
- [ ] Total line count did not increase **or** every added line is justified by reduced complexity/risk.
- [ ] No trivial third-party dependencies added; existing dependencies audited for necessity.

### Performance & Reliability
- [ ] Hot paths identified (if relevant) and performance measured post-refactor.
- [ ] Graceful degradation defined for every external dependency.
- [ ] Retry/recovery strategies exist where transient failure is expected and are bounded/observable.


## Final Standard (Definition of Done)

A refactor is complete only when all are true:

- The module’s responsibility is obvious from names and structure.
- Pure logic is separated from side effects.
- Dependencies are explicit and swappable.
- Error cases are explicit, categorized, and informative.
- Edge cases are handled without silent failure.
- Dead code is removed and duplication is reduced without harming clarity.
- Tests exist and cover pure logic and key behaviors.
- Parity is preserved unless explicitly changed.
- No new global state, no new hidden state, no new magic.
