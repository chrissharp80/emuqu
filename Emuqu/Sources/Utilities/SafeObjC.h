// Minimal ObjC shim so Swift can catch NSExceptions
// from AVFoundation (and the rest of the ObjC runtime). Swift's
// native `try` only catches Swift errors; ObjC code can still
// raise NSException synchronously, which terminates the process
// when it bubbles through Swift unhandled.
//
// For example, AVAudioEngine.start() throws
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

/// `installTap` raises Objective-C `NSException`
/// (NSInvalidArgumentException / NSInternalInconsistencyException)
/// when the bus is already tapped, the format doesn't match the
/// node's actual current output format, or the engine is in a bad
/// state from a previous failed start. Swift can't catch those.
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

/// `prepare()` is documented as not throwing, but
/// has been observed raising `NSInternalInconsistencyException`
/// on iOS 26 betas when the session is mid-route-change or the
/// engine state is stale. Wrap it for the same reason as the
/// other shims: never let an Obj-C exception terminate the app.
BOOL FRSafePrepareAudioEngine(AVAudioEngine *engine,
                              NSError * _Nullable __autoreleasing * _Nullable outError);

/// The following Obj-C APIs can raise
/// uncatchable NSException when the audio graph or session is in
/// a degraded state (after a phone-call interruption, route
/// change, or daemon recovery). Swift's `try` does not catch
/// NSException, only NSError, so each is wrapped here.
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
