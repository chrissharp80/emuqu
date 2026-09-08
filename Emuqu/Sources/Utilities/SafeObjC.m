// 2026-05-11 — See SafeObjC.h. Bare-minimum @try/@catch wrapper
// around `[AVAudioEngine startAndReturnError:]` so the Swift
// caller can recover from NSException instead of SIGABRT.

#import "SafeObjC.h"

NSString * const FRSafeAudioEngineErrorDomain = @"FlowRecovery.SafeAudioEngine";

BOOL FRSafeStartAudioEngine(AVAudioEngine *engine, NSError * _Nullable __autoreleasing * _Nullable outError) {
    if (engine == nil) {
        if (outError) {
            *outError = [NSError errorWithDomain:FRSafeAudioEngineErrorDomain
                                            code:-1
                                        userInfo:@{NSLocalizedDescriptionKey: @"engine is nil"}];
        }
        return NO;
    }
    @try {
        NSError *startErr = nil;
        BOOL ok = [engine startAndReturnError:&startErr];
        if (!ok || startErr != nil) {
            if (outError) { *outError = startErr; }
            return NO;
        }
        return YES;
    }
    @catch (NSException *ex) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
        userInfo[NSLocalizedDescriptionKey] = ex.reason ?: ex.name ?: @"AVAudioEngine raised NSException";
        if (ex.name) { userInfo[@"NSExceptionName"] = ex.name; }
        if (ex.reason) { userInfo[@"NSExceptionReason"] = ex.reason; }
        if (outError) {
            *outError = [NSError errorWithDomain:FRSafeAudioEngineErrorDomain
                                            code:-2
                                        userInfo:userInfo];
        }
        return NO;
    }
}

BOOL FRSafeInstallTap(AVAudioInputNode *node,
                      AVAudioNodeBus bus,
                      AVAudioFrameCount bufferSize,
                      AVAudioFormat *format,
                      void (^onAudio)(AVAudioPCMBuffer *buffer, AVAudioTime *when),
                      NSError * _Nullable __autoreleasing *outError) {
    if (node == nil) {
        if (outError) {
            *outError = [NSError errorWithDomain:FRSafeAudioEngineErrorDomain
                                            code:-10
                                        userInfo:@{NSLocalizedDescriptionKey: @"input node is nil"}];
        }
        return NO;
    }
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:onAudio];
        return YES;
    }
    @catch (NSException *ex) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
        userInfo[NSLocalizedDescriptionKey] = ex.reason ?: ex.name ?: @"installTap raised NSException";
        if (ex.name) { userInfo[@"NSExceptionName"] = ex.name; }
        if (ex.reason) { userInfo[@"NSExceptionReason"] = ex.reason; }
        if (outError) {
            *outError = [NSError errorWithDomain:FRSafeAudioEngineErrorDomain
                                            code:-11
                                        userInfo:userInfo];
        }
        return NO;
    }
}

BOOL FRSafePrepareAudioEngine(AVAudioEngine *engine,
                              NSError * _Nullable __autoreleasing *outError) {
    if (engine == nil) {
        if (outError) {
            *outError = [NSError errorWithDomain:FRSafeAudioEngineErrorDomain
                                            code:-20
                                        userInfo:@{NSLocalizedDescriptionKey: @"engine is nil"}];
        }
        return NO;
    }
    @try {
        [engine prepare];
        return YES;
    }
    @catch (NSException *ex) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
        userInfo[NSLocalizedDescriptionKey] = ex.reason ?: ex.name ?: @"prepare raised NSException";
        if (ex.name) { userInfo[@"NSExceptionName"] = ex.name; }
        if (ex.reason) { userInfo[@"NSExceptionReason"] = ex.reason; }
        if (outError) {
            *outError = [NSError errorWithDomain:FRSafeAudioEngineErrorDomain
                                            code:-21
                                        userInfo:userInfo];
        }
        return NO;
    }
}

// 2026-05-21 — Audit pass. Wrap every AVAudio NSException-prone call.

static NSError *_FRSafeErrorFromException(NSException *ex,
                                          NSInteger code,
                                          NSString *fallback) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = ex.reason ?: ex.name ?: fallback;
    if (ex.name) { userInfo[@"NSExceptionName"] = ex.name; }
    if (ex.reason) { userInfo[@"NSExceptionReason"] = ex.reason; }
    return [NSError errorWithDomain:FRSafeAudioEngineErrorDomain
                               code:code
                           userInfo:userInfo];
}

BOOL FRSafeRemoveTap(AVAudioInputNode *node,
                     AVAudioNodeBus bus,
                     NSError * _Nullable __autoreleasing *outError) {
    if (node == nil) {
        if (outError) {
            *outError = [NSError errorWithDomain:FRSafeAudioEngineErrorDomain
                                            code:-30
                                        userInfo:@{NSLocalizedDescriptionKey: @"node is nil"}];
        }
        return NO;
    }
    @try {
        [node removeTapOnBus:bus];
        return YES;
    }
    @catch (NSException *ex) {
        if (outError) {
            *outError = _FRSafeErrorFromException(ex, -31, @"removeTap raised NSException");
        }
        return NO;
    }
}

BOOL FRSafeSetVoiceProcessing(AVAudioInputNode *node,
                              BOOL enabled,
                              NSError * _Nullable __autoreleasing *outError) {
    if (node == nil) {
        if (outError) {
            *outError = [NSError errorWithDomain:FRSafeAudioEngineErrorDomain
                                            code:-40
                                        userInfo:@{NSLocalizedDescriptionKey: @"node is nil"}];
        }
        return NO;
    }
    @try {
        NSError *innerErr = nil;
        BOOL ok = [node setVoiceProcessingEnabled:enabled error:&innerErr];
        if (!ok && outError) { *outError = innerErr; }
        return ok;
    }
    @catch (NSException *ex) {
        if (outError) {
            *outError = _FRSafeErrorFromException(ex, -41, @"setVoiceProcessingEnabled raised NSException");
        }
        return NO;
    }
}

BOOL FRSafeAudioEngineStop(AVAudioEngine *engine,
                           NSError * _Nullable __autoreleasing *outError) {
    if (engine == nil) {
        if (outError) {
            *outError = [NSError errorWithDomain:FRSafeAudioEngineErrorDomain
                                            code:-50
                                        userInfo:@{NSLocalizedDescriptionKey: @"engine is nil"}];
        }
        return NO;
    }
    @try {
        [engine stop];
        return YES;
    }
    @catch (NSException *ex) {
        if (outError) {
            *outError = _FRSafeErrorFromException(ex, -51, @"engine.stop raised NSException");
        }
        return NO;
    }
}

BOOL FRSafeAudioEngineReset(AVAudioEngine *engine,
                            NSError * _Nullable __autoreleasing *outError) {
    if (engine == nil) {
        if (outError) {
            *outError = [NSError errorWithDomain:FRSafeAudioEngineErrorDomain
                                            code:-60
                                        userInfo:@{NSLocalizedDescriptionKey: @"engine is nil"}];
        }
        return NO;
    }
    @try {
        [engine reset];
        return YES;
    }
    @catch (NSException *ex) {
        if (outError) {
            *outError = _FRSafeErrorFromException(ex, -61, @"engine.reset raised NSException");
        }
        return NO;
    }
}

BOOL FRSafeSpeak(AVSpeechSynthesizer *synthesizer,
                 AVSpeechUtterance *utterance,
                 NSError * _Nullable __autoreleasing *outError) {
    if (synthesizer == nil || utterance == nil) {
        if (outError) {
            *outError = [NSError errorWithDomain:FRSafeAudioEngineErrorDomain
                                            code:-70
                                        userInfo:@{NSLocalizedDescriptionKey: @"synthesizer or utterance is nil"}];
        }
        return NO;
    }
    @try {
        [synthesizer speakUtterance:utterance];
        return YES;
    }
    @catch (NSException *ex) {
        if (outError) {
            *outError = _FRSafeErrorFromException(ex, -71, @"speak raised NSException");
        }
        return NO;
    }
}

BOOL FRSafeStopSpeaking(AVSpeechSynthesizer *synthesizer,
                        AVSpeechBoundary boundary,
                        NSError * _Nullable __autoreleasing *outError) {
    if (synthesizer == nil) {
        if (outError) {
            *outError = [NSError errorWithDomain:FRSafeAudioEngineErrorDomain
                                            code:-72
                                        userInfo:@{NSLocalizedDescriptionKey: @"synthesizer is nil"}];
        }
        return NO;
    }
    @try {
        [synthesizer stopSpeakingAtBoundary:boundary];
        return YES;
    }
    @catch (NSException *ex) {
        if (outError) {
            *outError = _FRSafeErrorFromException(ex, -73, @"stopSpeaking raised NSException");
        }
        return NO;
    }
}
