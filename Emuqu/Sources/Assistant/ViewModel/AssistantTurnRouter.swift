import Foundation

/// Which model answers a turn, and the machinery that drives its stream.
///
/// Picks a provider — honouring the smart-route tier, tool support and the
/// user's pinned choice — then dispatches the request and walks the stream
/// through its stages to the post-stream effects.
///
/// ## Why this is not on `AssistantViewModel`
///
/// A ~750-line extension in its own file would not help: the aggregate
/// type-size gate counts a type across all of its files, so an extension in a
/// new file is the same object with another window.
///
/// The coupling is measured rather than assumed: 33 view-model
/// members — the provider registry, the turn list, streaming state. Routing is
/// genuinely part of running a conversation and does not claim otherwise. What
/// changes is that the reads are `owner.` and countable.
///
/// A plain strong reference: the view model builds a router on demand
/// (`AssistantViewModel.router`) and never stores it, so no cycle forms.
@MainActor
struct AssistantTurnRouter {
    let owner: AssistantViewModel

}
