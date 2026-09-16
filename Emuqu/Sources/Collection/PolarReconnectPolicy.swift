import Foundation

/// How long a recording session waits for a strap that dropped.
///
/// The waiting itself is not the app's: the Polar SDK re-issues the
/// CoreBluetooth connect on an unexpected drop, and iOS keeps that request
/// pending until the strap is back in range. What the app decides is when to
/// stop waiting — at which point `PolarManager.reconnectExhausted` lets the
/// collector save the buffered stream rather than leave it in limbo.
///
/// The window decides whether a dropout costs the user the night. The H10 keeps
/// recording to its own memory throughout, so a strap that returns inside the
/// window loses nothing; shorten it and a toilet trip out of range ends the
/// session.
enum PolarReconnectPolicy {
    /// Twenty minutes: a long radio outage, or a strap left in another room,
    /// without abandoning the session for an ordinary one.
    static let windowSeconds: TimeInterval = 20 * 60
}
