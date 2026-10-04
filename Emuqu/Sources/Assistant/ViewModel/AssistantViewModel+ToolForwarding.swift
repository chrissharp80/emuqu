import Foundation

// The tool-use loop lives in `AssistantToolRunner` — ~800 lines kept off
// `AssistantViewModel`, itself already spread across four files. Callers
// reach it through `tools`.

extension AssistantViewModel {
    /// The tool-use subsystem: a lightweight value built on each access.
    var tools: AssistantToolRunner {
        AssistantToolRunner(owner: self)
    }
}
