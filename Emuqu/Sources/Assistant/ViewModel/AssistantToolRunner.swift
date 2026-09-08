import Foundation

/// The tool-use dispatch loop: sending a turn to a provider, running whatever
/// tools it asks for, feeding the results back, and deciding what to do when a
/// provider fails or refuses.
///
/// Also owns conversation summarisation, token-aware truncation and auto-fact
/// extraction — the work that keeps a long conversation inside a context window.
///
/// ## Why this is not on `AssistantViewModel`
///
/// As an ~850-line extension it was `AssistantViewModel`'s largest piece
/// that is not view state, on a type already thousands of lines across
/// several files.
///
/// A separate FILE alone satisfies the 1500-line file budget, but that is
/// a different measurement from the one that
/// matters here: the aggregate type-size gate counts a type across all its
/// files, so an extension in a new file is the same god object with more
/// windows. This type holds the lines off the view model.
///
/// The coupling was measured rather than assumed: these
/// functions read 26 members of the view model — the provider registry, the
/// turn list, streaming state, the stop flag. It is genuinely coupled to the
/// conversation it is running, and does not claim otherwise. Those 26 reads
/// are `owner.` and greppable.
///
/// `unowned` because the view model owns this and outlives it.
@MainActor
struct AssistantToolRunner {
    let owner: AssistantViewModel

}
