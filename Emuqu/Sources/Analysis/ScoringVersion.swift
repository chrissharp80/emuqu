import Foundation

/// The identifier of the scoring algorithm that produced a recovery score.
///
/// Why it exists governs how the retained heuristics are handled:
///
/// > "Changing history" is a product-migration concern, not a scientific
/// > justification. The correct solution may be score-versioning rather than
/// > silently rewriting history — but historical compatibility is not evidence
/// > for retaining a mechanism.
///
/// That is right. Several inputs to the composite are unvalidated heuristics
/// (resting DFA α1, the LF/HF window filter, the PNS−SNS gap), and training
/// readiness carries one more (the ACWR damper). The argument for leaving their arithmetic alone is that
/// changing it rewrites every stored score — which is a reason not to change
/// scores SILENTLY, not a reason to keep the mechanism. Stamping the version
/// onto each score removes that excuse: a future version can drop a heuristic
/// and old scores stay readable and correctly attributed, instead of the
/// archive becoming a silent mixture of two algorithms.
///
/// `Tools/science_register/register.json` records which heuristics each
/// version contains and their validation status.
enum ScoringVersion {
    /// The version this build computes. Referenced rather than retyped —
    /// before this existed the version string was duplicated across the
    /// assistant context, the knowledge base and the fact resolver, with
    /// nothing keeping them in step.
    static let current = "v3.1.oct2026"

    /// What a score decoded without a version is called.
    ///
    /// Deliberately not `current`. Scores stored before this build carry no
    /// version, and the archive genuinely cannot tell whether they came from
    /// v1 or v2 — the app has a v1→v2 history recompute the user may or may
    /// not have run. Defaulting them to `current` would assert something
    /// unknown; `unversioned` says what is true.
    static let unversioned = "unversioned"
}
