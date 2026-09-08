#include "CrashSignalHandler.h"

#include <dlfcn.h>
#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#define EMUQU_MAX_FRAMES 128

// All handler state is static and filled in at install time. The handler reads
// it and never writes to anything that could need an allocator.
static char g_crash_path[PATH_MAX];
static void *g_frames[EMUQU_MAX_FRAMES];
static intptr_t g_image_slide;
// The image the app's OWN code lives in, which on a debug build is NOT the
// main executable — see the note in the installer.
static const void *g_code_image_base;
static char g_code_image_name[256];
static size_t g_code_image_name_len;
static volatile sig_atomic_t g_handling;

static const int kFatalSignals[] = {
    SIGABRT, // abort(), assertion / precondition failure
    SIGSEGV, // bad memory access
    SIGBUS,  // misaligned or non-existent physical address
    SIGFPE,  // arithmetic fault
    SIGILL,  // illegal instruction
    SIGTRAP  // debugger trap; also Swift's fatalError on arm64
};

static const int kFatalSignalCount =
    (int)(sizeof(kFatalSignals) / sizeof(kFatalSignals[0]));

/// write(2) is async-signal-safe but may write fewer bytes than asked, and may
/// be interrupted. Loop rather than assume.
static void safe_write(int fd, const char *bytes, size_t count) {
    size_t written = 0;
    while (written < count) {
        ssize_t n = write(fd, bytes + written, count - written);
        if (n > 0) {
            written += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        break; // A failing fd is not worth retrying forever while crashing.
    }
}

/// Literal helper — the length is known at compile time, so no strlen call.
#define safe_write_lit(fd, s) safe_write((fd), (s), sizeof(s) - 1)

/// Fixed-width 0x-prefixed 64-bit hex plus a newline, rendered into a stack
/// buffer. No allocation, no locks.
static void safe_write_hex_line(int fd, uintptr_t value) {
    static const char digits[] = "0123456789abcdef";
    char buf[19];
    buf[0] = '0';
    buf[1] = 'x';
    for (int i = 0; i < 16; i++) {
        buf[2 + i] = digits[(value >> ((15 - i) * 4)) & 0xF];
    }
    buf[18] = '\n';
    safe_write(fd, buf, sizeof(buf));
}

/// Small non-negative decimal, rendered back-to-front into a stack buffer.
static void safe_write_dec(int fd, int value) {
    char buf[12];
    size_t i = sizeof(buf);
    unsigned v = value < 0 ? (unsigned)(-value) : (unsigned)value;
    if (v == 0) {
        safe_write_lit(fd, "0");
        return;
    }
    while (v > 0 && i > 0) {
        buf[--i] = (char)('0' + (v % 10));
        v /= 10;
    }
    if (value < 0 && i > 0) {
        buf[--i] = '-';
    }
    safe_write(fd, buf + i, sizeof(buf) - i);
}

/// Constant strings only — nothing here is derived at runtime.
static void safe_write_signal_name(int fd, int sig) {
    switch (sig) {
    case SIGABRT: safe_write_lit(fd, "SIGABRT"); break;
    case SIGSEGV: safe_write_lit(fd, "SIGSEGV"); break;
    case SIGBUS:  safe_write_lit(fd, "SIGBUS");  break;
    case SIGFPE:  safe_write_lit(fd, "SIGFPE");  break;
    case SIGILL:  safe_write_lit(fd, "SIGILL");  break;
    case SIGTRAP: safe_write_lit(fd, "SIGTRAP"); break;
    default:      safe_write_lit(fd, "SIGNAL");  break;
    }
}

static void emuqu_signal_handler(int signal_number) {
    // A second fatal signal raised while we are mid-write means the handler
    // itself is the problem. Leave immediately rather than recursing; _exit is
    // async-signal-safe and skips atexit handlers, which is what we want.
    if (g_handling) {
        _exit(128 + signal_number);
    }
    g_handling = 1;

    int fd = open(g_crash_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd >= 0) {
        safe_write_lit(fd, "EMUQU CRASH LOG\n\n");
        safe_write_lit(fd, "Type: Signal\nName: ");
        safe_write_signal_name(fd, signal_number);
        safe_write_lit(fd, " (");
        safe_write_dec(fd, signal_number);
        safe_write_lit(fd, ")\nMain executable slide: ");
        safe_write_hex_line(fd, (uintptr_t)g_image_slide);
        safe_write_lit(fd, "App code image: ");
        safe_write(fd, g_code_image_name, g_code_image_name_len);
        safe_write_lit(fd, "\nApp code image load address: ");
        safe_write_hex_line(fd, (uintptr_t)g_code_image_base);

        safe_write_lit(
            fd,
            "\nThese frames are raw return addresses, not symbols. Resolving a\n"
            "symbol needs malloc, and malloc is very often exactly what the\n"
            "process died inside, so it cannot be called from here.\n\n"
            "Symbolicate the app's own frames with:\n"
            "  atos -o <the app code image above, or its dSYM> -arch arm64 \\\n"
            "       -l <app code image load address> <address>\n\n"
            "Use the LOAD ADDRESS, not the slide. The two differ, and on the\n"
            "builds installed straight from Xcode they differ by tens of\n"
            "megabytes: the app binary is then only a launcher stub and every\n"
            "line of app code lives in Emuqu.debug.dylib beside it. Subtracting\n"
            "the main executable's slide from a frame in that dylib lands on an\n"
            "unrelated function, which reads as a plausible answer and is not\n"
            "one. Frames outside that address range belong to system libraries.\n"
            "\nSTACK TRACE\n");

        // backtrace() only walks frames into the buffer we already own. Its
        // symbolising sibling, backtrace_symbols(), allocates — never call it
        // here.
        int count = backtrace(g_frames, EMUQU_MAX_FRAMES);
        for (int i = 0; i < count; i++) {
            safe_write_hex_line(fd, (uintptr_t)g_frames[i]);
        }

        safe_write_lit(fd, "\nEND OF CRASH LOG\n");
        close(fd);
    }

    // Restore the default disposition and re-raise, so the process dies the way
    // it would have without us and the OS still writes its own report.
    signal(signal_number, SIG_DFL);
    raise(signal_number);
}

bool emuqu_install_crash_signal_handlers(const char *crash_file_path) {
    if (crash_file_path == NULL) {
        return false;
    }
    size_t len = strlen(crash_file_path);
    if (len == 0 || len >= sizeof(g_crash_path)) {
        return false;
    }
    memcpy(g_crash_path, crash_file_path, len + 1);

    // Resolved once, here: the dyld lookups are not async-signal-safe. Image 0
    // is the main executable.
    g_image_slide = _dyld_get_image_vmaddr_slide(0);

    // The main executable's slide is NOT enough to read this trace, because
    // the app's code is not always IN the main executable. Xcode's debug
    // builds ship the app binary as a small launcher and put every line of
    // app code in `Emuqu.debug.dylib`, loaded separately at its own address —
    // a 154 MB dylib behind a 92 KB stub. A frame from that dylib, resolved
    // against the main executable's slide, lands on whatever unrelated
    // function happens to sit at that offset in the app binary, and reports
    // it with a file and a line number. That is worse than an unresolved
    // address: it is a wrong answer that looks like a right one, and a lost
    // workout was mis-attributed to a settings screen this way.
    //
    // `dladdr` on a function defined in THIS file names the image the app's
    // own code is in, whichever image that turns out to be, and gives its
    // load address directly — the value `atos -l` wants. It allocates, so it
    // is called here at install time and never from the handler.
    Dl_info info;
    if (dladdr((const void *)(uintptr_t)&emuqu_install_crash_signal_handlers, &info) != 0) {
        g_code_image_base = info.dli_fbase;
        const char *path = info.dli_fname != NULL ? info.dli_fname : "";
        const char *slash = strrchr(path, '/');
        const char *base = slash != NULL ? slash + 1 : path;
        size_t base_len = strlen(base);
        if (base_len >= sizeof(g_code_image_name)) {
            base_len = sizeof(g_code_image_name) - 1;
        }
        memcpy(g_code_image_name, base, base_len);
        g_code_image_name[base_len] = '\0';
        g_code_image_name_len = base_len;
    } else {
        // Never leave the field blank — a blank line reads as "no code image"
        // rather than "the lookup failed", and the two need different fixes.
        static const char unknown[] = "(dladdr failed)";
        memcpy(g_code_image_name, unknown, sizeof(unknown));
        g_code_image_name_len = sizeof(unknown) - 1;
    }

    // Warm backtrace() so that the call inside the handler is never the one
    // that has to initialise anything lazily.
    void *warm[4];
    (void)backtrace(warm, 4);

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = emuqu_signal_handler;
    sigemptyset(&action.sa_mask);
    // SA_NODEFER is deliberately NOT set: the signal being handled stays
    // blocked for the duration, which is what keeps the re-entrancy guard
    // above simple and correct.
    action.sa_flags = 0;

    for (int i = 0; i < kFatalSignalCount; i++) {
        if (sigaction(kFatalSignals[i], &action, NULL) != 0) {
            return false;
        }
    }
    return true;
}
