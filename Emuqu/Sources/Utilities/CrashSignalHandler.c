#include "CrashSignalHandler.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/ucontext.h>
#include <unistd.h>

#define EMUQU_MAX_FRAMES 128
// How long a second crashing thread waits for the first to finish the log
// before it ends the process itself.
#define EMUQU_SECOND_THREAD_WAIT_SECONDS 3

// All handler state is static and filled in at install time. The handler reads
// it and never writes to anything that could need an allocator.
static char g_crash_path[PATH_MAX];
static uintptr_t g_frames[EMUQU_MAX_FRAMES];
static intptr_t g_image_slide;
// The image the app's OWN code lives in, which on a debug build is NOT the
// main executable — see the note in the installer.
static const void *g_code_image_base;
static char g_code_image_name[256];
static size_t g_code_image_name_len;
static volatile sig_atomic_t g_handling;
// The thread that won g_handling. Written once, right after the atomic
// exchange that claims the handler, and read only by a later signal.
static pthread_t g_handling_thread;

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

/// A return address with any pointer-authentication bits cleared, so it is
/// an address `atos` can read.
static uintptr_t strip_return_address(uintptr_t address) {
#if defined(__arm64__)
    return address & 0x0000007FFFFFFFFFULL;
#else
    return address;
#endif
}

int emuqu_walk_frame_chain(
    uintptr_t fp, uintptr_t stack_low, uintptr_t stack_high, uintptr_t *out, int max
) {
    int count = 0;
    while (count < max && fp >= stack_low && fp <= stack_high - 2 * sizeof(uintptr_t)
           && (fp & (sizeof(uintptr_t) - 1)) == 0) {
        const uintptr_t *record = (const uintptr_t *)fp;
        uintptr_t next = record[0];
        uintptr_t return_address = record[1];
        if (return_address == 0) {
            break;
        }
        out[count++] = strip_return_address(return_address);
        if (next <= fp) {
            break; // The stack grows down: a caller's record sits above.
        }
        fp = next;
    }
    return count;
}

/// The crashed code's pc, link register (0 where there is none) and frame
/// pointer, from the context the kernel handed the handler.
static void interrupted_registers(void *context, uintptr_t *pc, uintptr_t *lr, uintptr_t *fp) {
    *pc = 0;
    *lr = 0;
    *fp = 0;
    ucontext_t *uc = (ucontext_t *)context;
    if (uc == NULL || uc->uc_mcontext == NULL) {
        return;
    }
#if defined(__arm64__)
    *pc = (uintptr_t)arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
    *lr = (uintptr_t)arm_thread_state64_get_lr(uc->uc_mcontext->__ss);
    *fp = (uintptr_t)arm_thread_state64_get_fp(uc->uc_mcontext->__ss);
#elif defined(__x86_64__)
    *pc = (uintptr_t)uc->uc_mcontext->__ss.__rip;
    *fp = (uintptr_t)uc->uc_mcontext->__ss.__rbp;
#endif
}

/// The crashed thread's frames: its pc, its link register when the crashing
/// function had not saved it yet, then the frame-pointer chain. Unlike
/// `backtrace()`, which can take the unwinder's locks, this only reads the
/// thread's own stack, within its bounds, so it cannot stall or fault.
static int crashed_thread_frames(void *context) {
    uintptr_t pc, lr, fp;
    interrupted_registers(context, &pc, &lr, &fp);
    pthread_t self = pthread_self();
    uintptr_t stack_high = (uintptr_t)pthread_get_stackaddr_np(self);
    uintptr_t stack_low = stack_high - (uintptr_t)pthread_get_stacksize_np(self);
    int count = 0;
    if (pc != 0) {
        g_frames[count++] = strip_return_address(pc);
    }
    // A function that had not saved its link register yet has its caller
    // only there; one that had has it as the chain's first return address.
    uintptr_t first_return = 0;
    int has_first = emuqu_walk_frame_chain(fp, stack_low, stack_high, &first_return, 1);
    if (lr != 0 && (has_first == 0 || first_return != strip_return_address(lr))) {
        g_frames[count++] = strip_return_address(lr);
    }
    return count + emuqu_walk_frame_chain(fp, stack_low, stack_high, g_frames + count, EMUQU_MAX_FRAMES - count);
}

static void emuqu_signal_handler(int signal_number, siginfo_t *info, void *context) {
    (void)info;
    // The first signal claims the handler with an atomic exchange, so two
    // threads crashing together cannot both truncate and write the file.
    if (__atomic_exchange_n(&g_handling, 1, __ATOMIC_SEQ_CST) != 0) {
        // A second fatal signal on the SAME thread means the handler itself
        // faulted. Leave immediately rather than recursing; _exit is
        // async-signal-safe and skips atexit handlers, which is what we want.
        if (pthread_equal(g_handling_thread, pthread_self())) {
            _exit(128 + signal_number);
        }
        // Another thread is still writing. Wait for it: its re-raise ends the
        // process, so the log is completed and the OS still writes its report.
        // The wait is bounded: if that thread never gets there, this one
        // ends the process with its own signal instead of hanging it.
        for (int waited = 0; waited < EMUQU_SECOND_THREAD_WAIT_SECONDS; waited++) {
            sleep(1);
        }
        signal(signal_number, SIG_DFL);
        raise(signal_number);
        _exit(128 + signal_number);
    }
    g_handling_thread = pthread_self();

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

        int count = crashed_thread_frames(context);
        for (int i = 0; i < count; i++) {
            safe_write_hex_line(fd, g_frames[i]);
        }

        safe_write_lit(fd, "\nEND OF CRASH LOG\n");
        close(fd);
    }

    // Restore the default disposition and re-raise, so the process dies the way
    // it would have without us and the OS still writes its own report.
    signal(signal_number, SIG_DFL);
    raise(signal_number);
}

/// Puts the first `count` fatal signals back to the dispositions saved in
/// `previous`, undoing a partial install.
static void restore_handlers(const struct sigaction *previous, int count) {
    for (int i = 0; i < count; i++) {
        (void)sigaction(kFatalSignals[i], &previous[i], NULL);
    }
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

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = emuqu_signal_handler;
    sigemptyset(&action.sa_mask);
    // SA_NODEFER is deliberately NOT set: the signal being handled stays
    // blocked on the handling thread for the duration. Other threads can still
    // take a fatal signal; the guard in the handler makes them wait.
    action.sa_flags = SA_SIGINFO;

    // All or nothing: if one sigaction fails, the handlers already installed
    // are put back to what they were, so `false` means none is installed.
    struct sigaction previous[sizeof(kFatalSignals) / sizeof(kFatalSignals[0])];
    for (int i = 0; i < kFatalSignalCount; i++) {
        if (sigaction(kFatalSignals[i], &action, &previous[i]) != 0) {
            restore_handlers(previous, i);
            return false;
        }
    }
    return true;
}
