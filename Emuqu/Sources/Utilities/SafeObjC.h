// 2026-05-11 — Minimal ObjC shim so Swift can catch NSExceptions
// from AVFoundation (and the rest of the ObjC runtime). Swift's
// native `try` only catches Swift errors; ObjC code can still
// raise NSException synchronously, which terminates the process
// when it bubbles through Swift unhandled.
//
// User-visible crash: AVAudioEngine.start() throws
// NSInternalInconsistencyException when the audio session,
// node graph, or input format is in a bad state — Swift can't
// catch it, so the app aborts (SIGABRT, signal 6).

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Start an AVAudioEngine inside @try/@catch. Returns YES on
/// success. On NSException, returns NO and populates `error`
/// with a domain/code/description derived from the exception
/// (so Swift `catch` can read the reason).
///
/// Wraps both the Swift-bridged `startAndReturnError:` (which
/// already throws `NSError` on recoverable failures) AND any
/// uncatchable `NSException` raised during graph realization.
BOOL FRSafeStartAudioEngine(AVAudioEngine *engine, NSError * _Nullable __autoreleasing * _Nullable outError);

/// 2026-05-20 — `installTap` raises Objective-C `NSException`
/// (NSInvalidArgumentException / NSInternalInconsistencyException)
/// when the bus is already tapped, the format doesn't match the
/// node's actual current output format, or the engine is in a bad
/// state from a previous failed start. Swift can't catch those.
/// Beta tester crash log 2026-05-20 07:10:14 (SIGABRT at signal 6,
/// stack inside AVFAudio's installTap path) — the existing
/// `startAudioEngineAndRecognizer` shim wraps `start()` but not
/// this call, so the NSException bubbled through and terminated
/// the app.
///
/// This shim installs the tap inside @try/@catch. On exception,
/// returns NO with the reason populated in `error`. Caller bails
/// to recoverable Swift-error path instead of aborting.
BOOL FRSafeInstallTap(AVAudioInputNode *node,
                      AVAudioNodeBus bus,
                      AVAudioFrameCount bufferSize,
                      AVAudioFormat * _Nullable format,
                      void (^onAudio)(AVAudioPCMBuffer *buffer, AVAudioTime *when),
                      NSError * _Nullable __autoreleasing * _Nullable outError);

/// 2026-05-20 — `prepare()` is documented as not throwing, but
/// has been observed raising `NSInternalInconsistencyException`
/// on iOS 26 betas when the session is mid-route-change or the
/// engine state is stale. Wrap it for the same reason as the
/// other shims: never let an Obj-C exception terminate the app.
BOOL FRSafePrepareAudioEngine(AVAudioEngine *engine,
                              NSError * _Nullable __autoreleasing * _Nullable outError);

/// 2026-05-21 — Full sweep of AVAudio NSException-prone calls
/// after a deep audit. The following Obj-C APIs can raise
/// uncatchable NSException when the audio graph or session is in
/// a degraded state (after a phone-call interruption, route
/// change, or daemon recovery). Swift's `try` does not catch
/// NSException — only NSError. Each was a latent SIGABRT.
///
/// Beta tester report 2026-05-21: user "afraid to call AI for fear
/// my workout would crash." The fear is justified because their
/// 06:55:26 audio session interrupt 5 minutes before workout
/// start left AVAudio in a state where any of these calls could
/// raise NSException.
BOOL FRSafeRemoveTap(AVAudioInputNode *node,
                     AVAudioNodeBus bus,
                     NSError * _Nullable __autoreleasing * _Nullable outError);

BOOL FRSafeSetVoiceProcessing(AVAudioInputNode *node,
                              BOOL enabled,
                              NSError * _Nullable __autoreleasing * _Nullable outError);

BOOL FRSafeAudioEngineStop(AVAudioEngine *engine,
                           NSError * _Nullable __autoreleasing * _Nullable outError);

BOOL FRSafeAudioEngineReset(AVAudioEngine *engine,
                            NSError * _Nullable __autoreleasing * _Nullable outError);

/// `AVSpeechSynthesizer.speak(...)` raises NSException when the
/// utterance has no voice and no default voice is available, or
/// when the synthesizer is in a teardown state. Used by the
/// workout-start "Started" announce AND by every AI TTS chunk.
/// Wrapping it means the AI TTS path can't crash the workout.
BOOL FRSafeSpeak(AVSpeechSynthesizer *synthesizer,
                 AVSpeechUtterance *utterance,
                 NSError * _Nullable __autoreleasing * _Nullable outError);

/// `AVSpeechSynthesizer.stopSpeaking(at:)` can also raise NSException
/// when the synthesizer is in a degraded / teardown audio-session state
/// — exactly the Stop / interrupt / barge-in moments. Like `speak`, a
/// raised exception is uncatchable from Swift (→ SIGABRT), so wrap it.
BOOL FRSafeStopSpeaking(AVSpeechSynthesizer *synthesizer,
                        AVSpeechBoundary boundary,
                        NSError * _Nullable __autoreleasing * _Nullable outError);

NS_ASSUME_NONNULL_END
