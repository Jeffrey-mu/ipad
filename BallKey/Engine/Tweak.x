// BallKey Engine — injected into backboardd.
// Listens to keyboard/mouse HID events and synthesizes digitizer touches
// via IOHIDEventSystemClientDispatchEvent (Veency/SimulateTouch lineage).

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <IOKit/hid/IOHIDEventTypes.h>
#import "BKConfig.h"

#pragma mark - IOKit extern declarations (modern signatures)

typedef const void *BKIOHIDEventRef;
typedef struct __IOHIDEventSystemClient *BKIOHIDEventSystemClientRef;
typedef void (*BKHIDEventCB)(void *target, void *refcon, void *queue, BKIOHIDEventRef event);

BKIOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
void IOHIDEventSystemClientDispatchEvent(BKIOHIDEventSystemClientRef client, BKIOHIDEventRef event);
void IOHIDEventSystemClientSetMatching(BKIOHIDEventSystemClientRef client, CFTypeRef match);
void IOHIDEventSystemClientRegisterEventCallback(BKIOHIDEventSystemClientRef client, BKHIDEventCB callback, void *target, void *refcon);
void IOHIDEventSystemClientScheduleWithRunLoop(BKIOHIDEventSystemClientRef client, CFRunLoopRef runloop, CFStringRef mode);

BKIOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef allocator, uint64_t timeStamp, uint32_t type,
    uint32_t index, uint32_t identity, uint32_t eventMask, uint32_t buttonMask,
    float x, float y, float z, float tipPressure, float barrelPressure,
    uint8_t range, uint8_t touch, uint32_t options);
BKIOHIDEventRef IOHIDEventCreateDigitizerFingerEventWithQuality(CFAllocatorRef allocator, uint64_t timeStamp,
    uint32_t index, uint32_t identity, uint32_t eventMask,
    float x, float y, float z, float tipPressure, float twist,
    float minorRadius, float majorRadius, float quality, float density, float irregularity,
    uint8_t range, uint8_t touch, uint32_t options);

void IOHIDEventAppendEvent(BKIOHIDEventRef event, BKIOHIDEventRef childEvent);
void IOHIDEventSetIntegerValueWithOptions(BKIOHIDEventRef event, IOHIDEventField field, int value, uint32_t options);
void IOHIDEventSetSenderID(BKIOHIDEventRef event, uint64_t senderID);
int IOHIDEventGetType(BKIOHIDEventRef event);
int IOHIDEventGetIntegerValue(BKIOHIDEventRef event, IOHIDEventField field);
float IOHIDEventGetFloatValue(BKIOHIDEventRef event, IOHIDEventField field);

#define kTransducerHand 3
#define kFieldDigitizerDisplayIntegrated 720921
#define kFieldBuiltIn 4
#define kSetOpt 0xF0000000u
#define kSenderID 0xDEFACEDBEEFFECE5ull
#define kDirNormFactor (1.0f / 1024.0f)

#pragma mark - State

static BKIOHIDEventSystemClientRef gListenClient = NULL;
static BKIOHIDEventSystemClientRef gSendClient = NULL;
static NSArray *gPoints = nil;
static BOOL gEnabled = NO;
static NSString *gActiveBundle = nil;

// per-point touch state: index -> @YES while a synthetic touch is down
static NSMutableDictionary<NSNumber *, NSNumber *> *gPointDown = nil;
// hold timers generation: index -> generation counter
static NSMutableDictionary<NSNumber *, NSNumber *> *gHoldGen = nil;

// direction drag state
static BOOL gDirDown = NO;
static float gDirX = 0, gDirY = 0;
static float gDirAnchorX = 0, gDirAnchorY = 0;
static float gDirRadius = 0.12f;
static float gDirSens = 1.0f;

static uint16_t gPrevButtonMask = 0;

#pragma mark - Touch synthesis

static void BKNotifyUserActivity(void)
{
    Class cls = objc_getClass("BKUserEventTimer");
    if (!cls) return;
    id timer = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
    if (!timer) return;
    SEL sel1 = @selector(userEventOccurred);
    SEL sel2 = @selector(userEventOccurredOnDisplay:);
    if ([timer respondsToSelector:sel1]) {
        ((void (*)(id, SEL))objc_msgSend)(timer, sel1);
    } else if ([timer respondsToSelector:sel2]) {
        ((void (*)(id, SEL, id))objc_msgSend)(timer, sel2, nil);
    }
}

// nx, ny in 0..1 native display space. phase: 0 move, 1 down, 2 up
static void BKSendTouch(float nx, float ny, int phase)
{
    if (!gSendClient) {
        gSendClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!gSendClient) return;
    }

    uint64_t ab = mach_absolute_time();

    BKIOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, ab, kTransducerHand,
        0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    if (!hand) return;

    IOHIDEventSetIntegerValueWithOptions(hand, kFieldDigitizerDisplayIntegrated, 1, kSetOpt);
    IOHIDEventSetIntegerValueWithOptions(hand, kFieldBuiltIn, 1, kSetOpt);

    int eventM;
    int touch;
    if (phase == 0) {
        eventM = kIOHIDDigitizerEventPosition;
        touch = 1;
    } else {
        eventM = kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch;
        touch = (phase == 2) ? 0 : 1;
    }

    BKIOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEventWithQuality(kCFAllocatorDefault, ab,
        1, 2, eventM, nx, ny, 0, 0, 0, 0, 0, 0, 0, 0, touch, touch, 0);
    if (finger) {
        IOHIDEventAppendEvent(hand, finger);
        CFRelease(finger);
    }

    int handMask;
    if (phase == 0) {
        handMask = kIOHIDDigitizerEventPosition;
    } else {
        handMask = kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventIdentity;
        if (phase == 2) handMask |= kIOHIDDigitizerEventPosition;
    }
    IOHIDEventSetIntegerValueWithOptions(hand, kIOHIDEventFieldDigitizerEventMask, handMask, kSetOpt);
    IOHIDEventSetIntegerValueWithOptions(hand, kIOHIDEventFieldDigitizerRange, touch, kSetOpt);
    IOHIDEventSetIntegerValueWithOptions(hand, kIOHIDEventFieldDigitizerTouch, touch, kSetOpt);

    IOHIDEventSetSenderID(hand, kSenderID);
    IOHIDEventSystemClientDispatchEvent(gSendClient, hand);
    CFRelease(hand);

    BKNotifyUserActivity();
}

static void BKTouchDown(NSUInteger idx, float nx, float ny)
{
    if ([gPointDown[@(idx)] boolValue]) return;
    gPointDown[@(idx)] = @YES;
    BKSendTouch(nx, ny, 1);
}

static void BKTouchUp(NSUInteger idx)
{
    if (![gPointDown[@(idx)] boolValue]) return;
    gPointDown[@(idx)] = @NO;
    BKSendTouch(0, 0, 2);
}

static void BKTouchMove(NSUInteger idx, float nx, float ny)
{
    if (![gPointDown[@(idx)] boolValue]) return;
    BKSendTouch(nx, ny, 0);
}

#pragma mark - Mapping

static NSString *BKEncodeKey(NSString *kind, NSInteger code)
{
    return [NSString stringWithFormat:@"%@:%ld", kind, (long)code];
}

static void BKHandleKey(NSInteger usage, BOOL down)
{
    NSString *key = BKEncodeKey(@"k", usage);
    [gPoints enumerateObjectsUsingBlock:^(NSDictionary *pt, NSUInteger idx, BOOL *stop) {
        NSString *type = pt[@"Type"];
        if (![pt[@"Key"] isEqualToString:key]) return;
        float nx = [pt[@"X"] floatValue];
        float ny = [pt[@"Y"] floatValue];
        if ([type isEqualToString:@"Tap"]) {
            if (down) {
                BKSendTouch(nx, ny, 1);
                BKSendTouch(0, 0, 2);
            }
        } else if ([type isEqualToString:@"Press"]) {
            if (down) BKTouchDown(idx, nx, ny);
            else BKTouchUp(idx);
        } else if ([type isEqualToString:@"Hold"]) {
            if (down) {
                BKTouchDown(idx, nx, ny);
                NSNumber *gen = @( [gHoldGen[@(idx)] intValue] + 1 );
                gHoldGen[@(idx)] = gen;
                int holdMs = pt[@"HoldMs"] ? [pt[@"HoldMs"] intValue] : 400;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)holdMs * NSEC_PER_MSEC),
                    dispatch_get_main_queue(), ^{
                        if ([gHoldGen[@(idx)] isEqualToNumber:gen]) {
                            BKTouchUp(idx);
                        }
                    });
            }
        }
    }];
}

static void BKHandleMouseButton(NSInteger idx, BOOL down)
{
    NSString *key = BKEncodeKey(@"m", idx);
    // direction component
    [gPoints enumerateObjectsUsingBlock:^(NSDictionary *pt, NSUInteger i, BOOL *stop) {
        if (![pt[@"Type"] isEqualToString:@"Dir"]) return;
        if (![pt[@"Button"] isEqualToString:key]) return;
        *stop = YES;
        if (down && !gDirDown) {
            gDirAnchorX = [pt[@"X"] floatValue];
            gDirAnchorY = [pt[@"Y"] floatValue];
            gDirRadius = pt[@"Radius"] ? [pt[@"Radius"] floatValue] : 0.12f;
            gDirSens = pt[@"Sens"] ? [pt[@"Sens"] floatValue] : 1.0f;
            gDirX = gDirAnchorX;
            gDirY = gDirAnchorY;
            gDirDown = YES;
            BKTouchDown(i, gDirX, gDirY);
        } else if (!down && gDirDown) {
            gDirDown = NO;
            BKTouchUp(i);
        }
    }];

    // other point types bound to mouse buttons
    [gPoints enumerateObjectsUsingBlock:^(NSDictionary *pt, NSUInteger i, BOOL *stop) {
        NSString *type = pt[@"Type"];
        if ([type isEqualToString:@"Dir"]) return;
        if (![pt[@"Key"] isEqualToString:key]) return;
        if ([type isEqualToString:@"Tap"]) {
            if (down) {
                float nx = [pt[@"X"] floatValue], ny = [pt[@"Y"] floatValue];
                BKSendTouch(nx, ny, 1);
                BKSendTouch(0, 0, 2);
            }
        } else if ([type isEqualToString:@"Press"]) {
            float nx = [pt[@"X"] floatValue], ny = [pt[@"Y"] floatValue];
            if (down) BKTouchDown(i, nx, ny);
            else BKTouchUp(i);
        } else if ([type isEqualToString:@"Hold"]) {
            if (down) {
                float nx = [pt[@"X"] floatValue], ny = [pt[@"Y"] floatValue];
                BKTouchDown(i, nx, ny);
                NSNumber *gen = @([gHoldGen[@(i)] intValue] + 1);
                gHoldGen[@(i)] = gen;
                int holdMs = pt[@"HoldMs"] ? [pt[@"HoldMs"] intValue] : 400;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)holdMs * NSEC_PER_MSEC),
                    dispatch_get_main_queue(), ^{
                        if ([gHoldGen[@(i)] isEqualToNumber:gen]) BKTouchUp(i);
                    });
            }
        }
    }];
}

static void BKHandleDirMove(float dx, float dy)
{
    if (!gDirDown) return;
    NSDictionary *dirPt = nil;
    NSUInteger dirIdx = 0;
    for (NSUInteger i = 0; i < gPoints.count; i++) {
        NSDictionary *pt = gPoints[i];
        if ([pt[@"Type"] isEqualToString:@"Dir"]) { dirPt = pt; dirIdx = i; break; }
    }
    if (!dirPt) return;

    gDirX += dx * gDirSens * kDirNormFactor;
    gDirY += dy * gDirSens * kDirNormFactor;
    float ddx = gDirX - gDirAnchorX;
    float ddy = gDirY - gDirAnchorY;
    float len = sqrtf(ddx * ddx + ddy * ddy);
    if (len > gDirRadius && len > 0.0001f) {
        gDirX = gDirAnchorX + ddx / len * gDirRadius;
        gDirY = gDirAnchorY + ddy / len * gDirRadius;
    }
    if (gDirX < 0) gDirX = 0; if (gDirX > 1) gDirX = 1;
    if (gDirY < 0) gDirY = 0; if (gDirY > 1) gDirY = 1;
    BKTouchMove(dirIdx, gDirX, gDirY);
}

#pragma mark - Listen callback

static void BKListenCB(void *target, void *refcon, void *queue, BKIOHIDEventRef ev)
{
    if (!ev) return;
    if (!gEnabled || gPoints.count == 0) return;

    int type = IOHIDEventGetType(ev);
    if (type == kIOHIDEventTypeKeyboard) {
        int page = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardUsagePage);
        int usage = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardUsage);
        int down = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardDown);
        int repeat = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardRepeat);
        if (page != 0 && page != 7) return;
        if (repeat) return;
        BKHandleKey(usage, down != 0);
    } else if (type == kIOHIDEventTypeMouse) {
        float dx = IOHIDEventGetFloatValue(ev, kIOHIDEventFieldMouseX);
        float dy = IOHIDEventGetFloatValue(ev, kIOHIDEventFieldMouseY);
        int bmask = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldMouseButtonMask);
        if (gDirDown && (dx != 0 || dy != 0)) {
            BKHandleDirMove(dx, dy);
        }
        uint16_t prev = gPrevButtonMask;
        uint16_t cur = (uint16_t)bmask;
        for (int b = 0; b < 3; b++) {
            uint16_t bit = 1 << b;
            BOOL was = (prev & bit) != 0;
            BOOL now = (cur & bit) != 0;
            if (was != now) BKHandleMouseButton(b, now);
        }
        gPrevButtonMask = cur;
    } else if (type == kIOHIDEventTypeButton) {
        int num = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldButtonNumber);
        int click = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldButtonClickCount);
        int idx = (num >= 1) ? (num - 1) : num;
        if (idx >= 0 && idx <= 2) BKHandleMouseButton(idx, click > 0);
    }
}

#pragma mark - Config

static void BKLoadConfig(void)
{
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kBKConfigPath];
    BOOL enabled = [cfg[@"Enabled"] boolValue];
    NSString *active = cfg[@"ActiveBundle"];
    NSArray *pts = nil;
    NSDictionary *profiles = cfg[@"Profiles"];
    if ([profiles isKindOfClass:[NSDictionary class]] && [active isKindOfClass:[NSString class]]) {
        id p = profiles[active];
        if ([p isKindOfClass:[NSArray class]]) pts = p;
    }
    gEnabled = enabled && pts.count > 0;
    gActiveBundle = active;
    gPoints = pts;
    if (!gEnabled) {
        // lift any active touches
        for (NSNumber *k in gPointDown.allKeys) {
            if ([gPointDown[k] boolValue]) {
                gPointDown[k] = @NO;
                BKSendTouch(0, 0, 2);
            }
        }
        gDirDown = NO;
    }
}

#pragma mark - Init

static void BKEngineInit(void)
{
    gPointDown = [NSMutableDictionary dictionary];
    gHoldGen = [NSMutableDictionary dictionary];

    gListenClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!gListenClient) return;

    NSArray *matching = @[
        @{ @"DeviceUsagePage": @1, @"DeviceUsage": @6 },  // keyboard
        @{ @"DeviceUsagePage": @1, @"DeviceUsage": @2 },  // mouse
        @{ @"DeviceUsagePage": @1, @"DeviceUsage": @1 },  // pointer
        @{ @"DeviceUsagePage": @9, @"DeviceUsage": @1 },  // button
    ];
    IOHIDEventSystemClientSetMatching(gListenClient, (__bridge CFTypeRef)matching);
    IOHIDEventSystemClientRegisterEventCallback(gListenClient, BKListenCB, NULL, NULL);
    IOHIDEventSystemClientScheduleWithRunLoop(gListenClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

    int token = 0;
    notify_register_dispatch(kBKNotifyReload, &token, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        BKLoadConfig();
    });

    BKLoadConfig();
}

%ctor {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            BKEngineInit();
        });
    }
}
