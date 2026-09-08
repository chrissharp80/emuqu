// 2026-05-11 — Bridging header. Created so Swift code can call
// the small ObjC shim that catches NSException from AVFoundation
// (see Sources/Utilities/SafeObjC.h). Keep this file lean —
// adding entries here recompiles the entire Swift target.

#import "SafeObjC.h"
#import "CrashSignalHandler.h"
