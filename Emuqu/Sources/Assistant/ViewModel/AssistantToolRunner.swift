import Foundation

/// The tool-use dispatch loop: sending a turn to a provider, running whatever
/// tools it asks for, feeding the results back, and deciding what to do when a
/// provider fails or refuses.
///
/// A plain strong reference: the view model builds a runner on demand
/// (`AssistantViewModel.tools`) and never stores it, so no cycle forms.
@MainActor
struct AssistantToolRunner {
    let owner: AssistantViewModel

}
