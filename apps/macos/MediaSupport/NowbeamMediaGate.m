#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>

// 仅在受控的系统 Perl 子进程中调用。接口不可用时返回不可用，不猜测暂停。
typedef NSDictionary *(*MetadataFunction)(BOOL);
typedef void (*StateFunction)(dispatch_queue_t, void (^)(uint32_t));
typedef void (*PIDFunction)(dispatch_queue_t, void (^)(int));

static BOOL readIdentity(StateFunction stateFunction, PIDFunction pidFunction,
                         dispatch_queue_t queue, uint32_t *state, int *pid) {
    dispatch_group_t group = dispatch_group_create();
    __block uint32_t observedState = 0;
    __block int observedPID = 0;
    dispatch_group_enter(group);
    stateFunction(queue, ^(uint32_t value) {
        observedState = value;
        dispatch_group_leave(group);
    });
    dispatch_group_enter(group);
    pidFunction(queue, ^(int value) {
        observedPID = value;
        dispatch_group_leave(group);
    });
    if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC)) != 0) {
        return NO;
    }
    *state = observedState;
    *pid = observedPID;
    return YES;
}

static NSString *boundedText(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *text = value;
    NSUInteger length = MIN(text.length, 512);
    if (length && [text characterAtIndex:length - 1] >= 0xD800
        && [text characterAtIndex:length - 1] <= 0xDBFF) length--;
    unichar bounded[512];
    NSUInteger count = 0;
    for (NSUInteger index = 0; index < length; index++) {
        unichar character = [text characterAtIndex:index];
        if (character >= 0x20 && character != 0x7F) bounded[count++] = character;
    }
    return [[NSString alloc] initWithCharacters:bounded length:count];
}

__attribute__((visibility("default"))) void nowbeam_media_snapshot(void) {
    @autoreleasepool {
        NSDictionary *result = @{@"status": @"unavailable", @"payload": NSNull.null};
        MetadataFunction metadata = (MetadataFunction)dlsym(RTLD_DEFAULT, "internal_get");
        NSURL *url = [NSURL fileURLWithPath:@"/System/Library/PrivateFrameworks/MediaRemote.framework"];
        CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, (__bridge CFURLRef)url);
        StateFunction stateFunction = bundle ? (StateFunction)CFBundleGetFunctionPointerForName(
            bundle, CFSTR("MRMediaRemoteGetNowPlayingApplicationPlaybackState")) : NULL;
        PIDFunction pidFunction = bundle ? (PIDFunction)CFBundleGetFunctionPointerForName(
            bundle, CFSTR("MRMediaRemoteGetNowPlayingApplicationPID")) : NULL;
        if (metadata && stateFunction && pidFunction) {
            dispatch_queue_t queue = dispatch_queue_create("Nowbeam.media.validity", DISPATCH_QUEUE_SERIAL);
            uint32_t firstState = 0, lastState = 0;
            int firstPID = 0, lastPID = 0;
            if (readIdentity(stateFunction, pidFunction, queue, &firstState, &firstPID)) {
                result = @{@"status": @"ok", @"payload": NSNull.null};
                if (firstPID > 0 && (firstState == 1 || firstState == 2)) {
                    NSDictionary *information = metadata(NO);
                    if (information && readIdentity(stateFunction, pidFunction, queue, &lastState, &lastPID)
                        && firstPID == lastPID && firstState == lastState
                        && [information[@"processIdentifier"] intValue] == lastPID
                        && [information[@"playing"] boolValue] == (lastState == 1)) {
                        NSMutableDictionary *payload = [NSMutableDictionary dictionary];
                        for (NSString *key in @[@"bundleIdentifier", @"parentApplicationBundleIdentifier",
                                                @"title", @"artist", @"album", @"contentItemIdentifier"]) {
                            NSString *text = boundedText(information[key]);
                            if (text) payload[key] = text;
                        }
                        for (NSString *key in @[@"durationMicros", @"elapsedTimeMicros", @"timestampEpochMicros", @"playbackRate"]) {
                            id number = information[key];
                            if ([number isKindOfClass:NSNumber.class] && isfinite([number doubleValue])) payload[key] = number;
                        }
                        payload[@"playbackState"] = @(lastState);
                        result = @{@"status": @"ok", @"payload": payload};
                    }
                }
            }
        }
        if (bundle) CFRelease(bundle);
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        if (!encoded) encoded = [@"{\"status\":\"unavailable\",\"payload\":null}" dataUsingEncoding:NSUTF8StringEncoding];
        fwrite(encoded.bytes, 1, encoded.length, stdout);
        fputc('\n', stdout);
        fflush(stdout);
    }
}
