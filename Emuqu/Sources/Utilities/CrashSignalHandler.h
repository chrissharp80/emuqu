#ifndef CrashSignalHandler_h
#define CrashSignalHandler_h

#include <stdbool.h>

/// Install async-signal-safe handlers for the fatal signals (SIGABRT, SIGSEGV,
/// SIGBUS, SIGFPE, SIGILL, SIGTRAP).
///
/// This lives in C rather than Swift on purpose. A fatal signal is delivered on
/// the crashing thread with the process in an arbitrary state — very often
/// *inside* malloc, because heap corruption is what raised SIGSEGV or SIGABRT in
/// the first place. Only the POSIX async-signal-safe functions may be called
/// from that context. Swift cannot make that promise: string interpolation,
/// `Array`, `Date`, and even ARC traffic can allocate, and allocating means
/// taking a lock the crashing thread may already hold. The result is not a
/// missing log, it is a *hang* — the app stops without dying until the watchdog
/// kills it, which is strictly worse than having no handler at all.
///
/// `crash_file_path` is copied into a private static buffer, so the caller does
/// not need to keep it alive. Everything else the handler needs — the image
/// slide, the backtrace buffer — is resolved here too, while the process is
/// still healthy. The handler itself only calls open/write/close, `backtrace`,
/// and `raise`.
///
/// Returns true if every handler was installed.
bool emuqu_install_crash_signal_handlers(const char *crash_file_path);

#include <stdint.h>

/// Up to `max` return addresses from the frame-pointer chain whose first
/// record is at `fp`, written to `out`; returns how many. Each record is two
/// words (the caller's record, then the return address). The walk stops at
/// a record outside [stack_low, stack_high), a misaligned one, a zero return
/// address, or a link that does not lead up the stack, so a corrupt chain
/// ends it instead of faulting or looping. Signal-safe: it reads memory and
/// nothing else.
int emuqu_walk_frame_chain(
    uintptr_t fp, uintptr_t stack_low, uintptr_t stack_high, uintptr_t *out, int max
);

#endif /* CrashSignalHandler_h */
