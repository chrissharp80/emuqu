import Foundation

/// Whether a failed archive read or write is worth repeating soon.
///
/// A launch scan that is not stamped done while one of its workouts cannot
/// be read runs again on the next launch. That is right while the failure
/// clears by itself (the device was locked) and wrong when it never does (a
/// corrupt or undecodable file): one such workout would rerun the scan on
/// every launch, for good. The weekly rescan still retries those.
enum ArchiveAccessFailure {
    /// True for the failures that clear once the device is unlocked or space
    /// is freed: data protection keeping the file closed (Cocoa no-permission
    /// read or write, or POSIX EPERM / EACCES underneath), a full disk, or the
    /// keychain refusing the key for now (`JSONFileSeal.isKeyLocked`). False
    /// for the rest, which give the same result next time: a hash mismatch, a
    /// payload that does not decrypt or decode, a missing file or key, or a
    /// session from a newer schema.
    nonisolated static func mayClear(_ error: any Error) -> Bool {
        if JSONFileSeal.isKeyLocked(error) { return true }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, clearingCocoaCodes.contains(nsError.code) { return true }
        if isClearingPOSIX(nsError) { return true }
        guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return isClearingPOSIX(underlying)
    }

    nonisolated private static let clearingCocoaCodes: Set<Int> = [
        NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileWriteOutOfSpaceError
    ]

    nonisolated private static func isClearingPOSIX(_ error: NSError) -> Bool {
        error.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES), Int(ENOSPC)].contains(error.code)
    }
}
