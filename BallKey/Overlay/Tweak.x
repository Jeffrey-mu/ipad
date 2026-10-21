// BallKey Overlay — injected into SpringBoard.
// Floating ball + canvas key editor + frontmost-app tracking.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <IOKit/hid/IOHIDEventTypes.h>
#import "BKConfig.h"

#pragma mark - IOKit externs (for key binding capture)

typedef const void *BKIOHIDEventRef;
typedef struct __IOHIDEventSystemClient *BKIOHIDEventSystemClientRef;
typedef void (*BKHIDEventCB)(void *target, void *refcon, void *queue, BKIOHIDEventRef event);

BKIOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
void IOHIDEventSystemClientSetMatching(BKIOHIDEventSystemClientRef client, CFTypeRef match);
void IOHIDEventSystemClientRegisterEventCallback(BKIOHIDEventSystemClientRef client, BKHIDEventCB callback, void *target, void *refcon);
void IOHIDEventSystemClientScheduleWithRunLoop(BKIOHIDEventSystemClientRef client, CFRunLoopRef runloop, CFStringRef mode);
void IOHIDEventSystemClientUnscheduleWithRunLoop(BKIOHIDEventSystemClientRef client, CFRunLoopRef runloop, CFStringRef mode);
int IOHIDEventGetType(BKIOHIDEventRef event);
int IOHIDEventGetIntegerValue(BKIOHIDEventRef event, IOHIDEventField field);

#pragma mark - Globals

static dispatch_queue_t gIOQ;
static NSString *gFrontBundle = nil;
static BOOL gEnabledFlag = YES;

static UIWindow *gBallWindow = nil;
static UIWindow *gEditorWindow = nil;
static UIView *gMenuView = nil;

static NSMutableArray<UIView *> *gMarkers = nil;
static UIView *gPendingBind = nil;
static BKIOHIDEventSystemClientRef gBindClient = NULL;
static UIView *gBindBanner = nil;

static void BKStartBindCapture(void);

#pragma mark - Plist IO

static NSDictionary *BKReadCfg(void)
{
    __block NSDictionary *cfg = nil;
    dispatch_sync(gIOQ, ^{ cfg = [NSDictionary dictionaryWithContentsOfFile:kBKConfigPath]; });
    return cfg ?: @{};
}

static void BKWriteCfg(void (^mutate)(NSMutableDictionary *cfg))
{
    dispatch_async(gIOQ, ^{
        NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithContentsOfFile:kBKConfigPath] ?: [NSMutableDictionary dictionary];
        mutate(cfg);
        [cfg writeToFile:kBKConfigPath atomically:YES];
        notify_post(kBKNotifyReload);
    });
}

#pragma mark - Orientation transforms

static UIInterfaceOrientation BKCurrentOrientation(void)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [UIApplication sharedApplication].statusBarOrientation;
#pragma clang diagnostic pop
}

// UIKit points -> native normalized (SimulateTouch convention)
static CGPoint BKNormFromUIKit(CGPoint p)
{
    CGSize s = [UIScreen mainScreen].bounds.size;
    CGFloat Wp = MIN(s.width, s.height);
    CGFloat Hp = MAX(s.width, s.height);
    UIInterfaceOrientation o = BKCurrentOrientation();
    CGPoint q = p;
    switch (o) {
        case UIInterfaceOrientationPortrait: break;
        case UIInterfaceOrientationPortraitUpsideDown:
            q = CGPointMake(s.width - p.x, s.height - p.y); break;
        case UIInterfaceOrientationLandscapeLeft:
            q = CGPointMake(p.y, s.height - p.x); break;
        case UIInterfaceOrientationLandscapeRight:
            q = CGPointMake(s.width - p.y, p.x); break;
        default: break;
    }
    return CGPointMake(q.x / Wp, q.y / Hp);
}

// native normalized -> UIKit points (inverse)
static CGPoint BKUIKitFromNorm(CGPoint n)
{
    CGSize s = [UIScreen mainScreen].bounds.size;
    CGFloat Wp = MIN(s.width, s.height);
    CGFloat Hp = MAX(s.width, s.height);
    UIInterfaceOrientation o = BKCurrentOrientation();
    switch (o) {
        case UIInterfaceOrientationPortrait:
            return CGPointMake(n.x * Wp, n.y * Hp);
        case UIInterfaceOrientationPortraitUpsideDown:
            return CGPointMake(Wp - n.x * Wp, Hp - n.y * Hp);
        case UIInterfaceOrientationLandscapeLeft:
            return CGPointMake(Hp - n.y * Hp, n.x * Wp);
        case UIInterfaceOrientationLandscapeRight:
            return CGPointMake(n.y * Hp, Wp - n.x * Wp);
        default:
            return CGPointMake(n.x * Wp, n.y * Hp);
    }
}

#pragma mark - Marker view

@interface BKMarkerView : UIView
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *keyEnc;
@property (nonatomic, assign) NSInteger holdMs;
@property (nonatomic, assign) CGFloat radius;
@property (nonatomic, assign) CGFloat sens;
@property (nonatomic, strong) UILabel *label;
- (void)bk_pan:(UIPanGestureRecognizer *)pan;
- (void)bk_tap:(UITapGestureRecognizer *)tap;
- (void)bk_long:(UILongPressGestureRecognizer *)lp;
@end

static NSString *BKKeyDisplayName(NSString *enc)
{
    if (!enc) return @"?";
    NSArray *parts = [enc componentsSeparatedByString:@":"];
    if (parts.count != 2) return enc;
    NSString *kind = parts[0];
    int code = [parts[1] intValue];
    if ([kind isEqualToString:@"m"]) {
        static NSArray *names;
        names = @[@"左键", @"右键", @"中键"];
        return names[MIN(code, 2)];
    }
    if (code == 44) return @"空格";
    if (code == 40) return @"回车";
    if (code == 41) return @"Esc";
    if (code == 42) return @"退格";
    if (code == 43) return @"Tab";
    if (code >= 4 && code <= 29) {
        return [NSString stringWithFormat:@"%c", (char)('A' + (code - 4))];
    }
    if (code >= 58 && code <= 63) return [NSString stringWithFormat:@"F%d", code - 57];
    return [NSString stringWithFormat:@"K%d", code];
}

static UIColor *BKTypeColor(NSString *type)
{
    if ([type isEqualToString:@"Tap"]) return [UIColor systemBlueColor];
    if ([type isEqualToString:@"Press"]) return [UIColor systemGreenColor];
    if ([type isEqualToString:@"Hold"]) return [UIColor systemOrangeColor];
    return [UIColor systemPurpleColor];
}

static NSString *BKTypeLabel(NSString *type)
{
    if ([type isEqualToString:@"Tap"]) return @"单击";
    if ([type isEqualToString:@"Press"]) return @"按下";
    if ([type isEqualToString:@"Hold"]) return @"长按";
    return @"方向";
}

@implementation BKMarkerView

- (void)bk_pan:(UIPanGestureRecognizer *)pan
{
    UIView *canvas = self.superview;
    CGPoint t = [pan translationInView:canvas];
    CGPoint c = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    c.x = MAX(0, MIN(canvas.bounds.size.width, c.x));
    c.y = MAX(0, MIN(canvas.bounds.size.height, c.y));
    self.center = c;
    [pan setTranslation:CGPointZero inView:canvas];
}
- (void)bk_tap:(UITapGestureRecognizer *)tap
{
    gPendingBind = self;
    gBindBanner.hidden = NO;
    [self.superview bringSubviewToFront:self];
    BKStartBindCapture();
}
- (void)bk_long:(UILongPressGestureRecognizer *)lp
{
    if (lp.state != UIGestureRecognizerStateBegan) return;
    if (gPendingBind == self) { gPendingBind = nil; gBindBanner.hidden = YES; }
    [self removeFromSuperview];
    [gMarkers removeObject:self];
}
@end

static BKMarkerView *BKMakeMarker(NSString *type, CGPoint center)
{
    BKMarkerView *m = [[BKMarkerView alloc] initWithFrame:CGRectMake(center.x - 26, center.y - 26, 52, 52)];
    m.backgroundColor = [BKTypeColor(type) colorWithAlphaComponent:0.45];
    m.layer.cornerRadius = 26;
    m.layer.borderColor = BKTypeColor(type).CGColor;
    m.layer.borderWidth = 2;
    m.type = type;
    m.holdMs = 400;
    m.radius = 0.12;
    m.sens = 1.0;

    UILabel *l = [[UILabel alloc] initWithFrame:m.bounds];
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont boldSystemFontOfSize:11];
    l.textColor = UIColor.whiteColor;
    l.numberOfLines = 2;
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    l.text = [NSString stringWithFormat:@"%@\n?", BKTypeLabel(type)];
    [m addSubview:l];
    m.label = l;

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:m action:@selector(bk_pan:)];
    [m addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:m action:@selector(bk_tap:)];
    [m addGestureRecognizer:tap];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:m action:@selector(bk_long:)];
    [m addGestureRecognizer:lp];
    return m;
}

#pragma mark - Bind HID capture

static void BKStopBindClient(void)
{
    if (gBindClient) {
        IOHIDEventSystemClientUnscheduleWithRunLoop(gBindClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        CFRelease(gBindClient);
        gBindClient = NULL;
    }
}

static void BKBindCB(void *target, void *refcon, void *queue, BKIOHIDEventRef ev)
{
    if (!ev || !gPendingBind) return;
    int type = IOHIDEventGetType(ev);
    NSString *enc = nil;
    if (type == kIOHIDEventTypeKeyboard) {
        int page = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardUsagePage);
        int usage = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardUsage);
        int down = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldKeyboardDown);
        if ((page == 0 || page == 7) && down) enc = [NSString stringWithFormat:@"k:%d", usage];
    } else if (type == kIOHIDEventTypeMouse) {
        int bmask = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldMouseButtonMask);
        if (bmask & 1) enc = @"m:0";
        else if (bmask & 2) enc = @"m:1";
        else if (bmask & 4) enc = @"m:2";
    } else if (type == kIOHIDEventTypeButton) {
        int num = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldButtonNumber);
        int click = IOHIDEventGetIntegerValue(ev, kIOHIDEventFieldButtonClickCount);
        int idx = (num >= 1) ? num - 1 : num;
        if (click > 0 && idx >= 0 && idx <= 2) enc = [NSString stringWithFormat:@"m:%d", idx];
    }
    if (!enc) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        BKMarkerView *m = (BKMarkerView *)gPendingBind;
        if (![m isKindOfClass:[BKMarkerView class]]) return;
        m.keyEnc = enc;
        m.label.text = [NSString stringWithFormat:@"%@\n%@", BKTypeLabel(m.type), BKKeyDisplayName(enc)];
        gPendingBind = nil;
        gBindBanner.hidden = YES;
        BKStopBindClient();
    });
}

static void BKStartBindCapture(void)
{
    BKStopBindClient();
    gBindClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!gBindClient) return;
    NSArray *matching = @[
        @{ @"DeviceUsagePage": @1, @"DeviceUsage": @6 },
        @{ @"DeviceUsagePage": @1, @"DeviceUsage": @2 },
        @{ @"DeviceUsagePage": @9, @"DeviceUsage": @1 },
    ];
    IOHIDEventSystemClientSetMatching(gBindClient, (__bridge CFTypeRef)matching);
    IOHIDEventSystemClientRegisterEventCallback(gBindClient, BKBindCB, NULL, NULL);
    IOHIDEventSystemClientScheduleWithRunLoop(gBindClient, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
}

#pragma mark - Forward decls

static void BKToggleEnabled(void);
static void BKOpenEditor(void);
static void BKShowMenu(void);

#pragma mark - Action target (singleton)

@interface BKActionTarget : NSObject
+ (instancetype)shared;
- (void)ballTap;
- (void)ballPan:(UIPanGestureRecognizer *)pan;
- (void)menuEdit;
- (void)menuToggle;
- (void)addTap;
- (void)addPress;
- (void)addHold;
- (void)addDir;
- (void)editorDone;
@end

@implementation BKActionTarget
+ (instancetype)shared { static BKActionTarget *t; static dispatch_once_t once; dispatch_once(&once, ^{ t = [BKActionTarget new]; }); return t; }
- (void)ballTap { BKShowMenu(); }
- (void)ballPan:(UIPanGestureRecognizer *)pan
{
    if (!gBallWindow) return;
    CGPoint t = [pan translationInView:gBallWindow];
    CGRect f = gBallWindow.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    gBallWindow.frame = f;
    [pan setTranslation:CGPointZero inView:gBallWindow];
}
- (void)menuEdit { [gMenuView removeFromSuperview]; gMenuView = nil; BKOpenEditor(); }
- (void)menuToggle { BKToggleEnabled(); [gMenuView removeFromSuperview]; gMenuView = nil; }
- (void)addTap { BKMarkerView *m = BKMakeMarker(@"Tap", CGPointMake(UIScreen.mainScreen.bounds.size.width/2, UIScreen.mainScreen.bounds.size.height/2)); [gEditorWindow.rootViewController.view addSubview:m]; [gMarkers addObject:m]; }
- (void)addPress { BKMarkerView *m = BKMakeMarker(@"Press", CGPointMake(UIScreen.mainScreen.bounds.size.width/2 + 60, UIScreen.mainScreen.bounds.size.height/2)); [gEditorWindow.rootViewController.view addSubview:m]; [gMarkers addObject:m]; }
- (void)addHold { BKMarkerView *m = BKMakeMarker(@"Hold", CGPointMake(UIScreen.mainScreen.bounds.size.width/2 - 60, UIScreen.mainScreen.bounds.size.height/2)); [gEditorWindow.rootViewController.view addSubview:m]; [gMarkers addObject:m]; }
- (void)addDir { BKMarkerView *m = BKMakeMarker(@"Dir", CGPointMake(UIScreen.mainScreen.bounds.size.width/3, UIScreen.mainScreen.bounds.size.height/2)); [gEditorWindow.rootViewController.view addSubview:m]; [gMarkers addObject:m]; }
- (void)editorDone
{
    NSMutableArray *pts = [NSMutableArray array];
    for (BKMarkerView *m in gMarkers) {
        CGPoint n = BKNormFromUIKit(m.center);
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"Type"] = m.type;
        d[@"X"] = @(n.x);
        d[@"Y"] = @(n.y);
        if ([m.type isEqualToString:@"Dir"]) {
            d[@"Button"] = m.keyEnc ?: @"m:0";
            d[@"Radius"] = @(m.radius);
            d[@"Sens"] = @(m.sens);
        } else {
            d[@"Key"] = m.keyEnc ?: @"";
            if ([m.type isEqualToString:@"Hold"]) d[@"HoldMs"] = @(m.holdMs);
        }
        [pts addObject:d];
    }
    NSString *bundle = gFrontBundle ?: @"unknown";
    BKWriteCfg(^(NSMutableDictionary *cfg) {
        NSMutableDictionary *profiles = [cfg[@"Profiles"] isKindOfClass:[NSDictionary class]] ? [cfg[@"Profiles"] mutableCopy] : [NSMutableDictionary dictionary];
        profiles[bundle] = pts;
        cfg[@"Profiles"] = profiles;
    });
    BKStopBindClient();
    [gEditorWindow setHidden:YES];
    gEditorWindow = nil;
    gMarkers = nil;
    gPendingBind = nil;
    gBindBanner = nil;
}
@end

#pragma mark - Menu

static void BKShowMenu(void)
{
    if (gMenuView) { [gMenuView removeFromSuperview]; gMenuView = nil; return; }
    UIView *menu = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 150, 96)];
    menu.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
    menu.layer.cornerRadius = 12;
    menu.clipsToBounds = YES;

    UIButton *b1 = [UIButton buttonWithType:UIButtonTypeSystem];
    b1.frame = CGRectMake(0, 0, 150, 48);
    [b1 setTitle:@"编辑键位" forState:UIControlStateNormal];
    [b1 setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [b1 addTarget:[BKActionTarget shared] action:@selector(menuEdit) forControlEvents:UIControlEventTouchUpInside];

    UIButton *b2 = [UIButton buttonWithType:UIButtonTypeSystem];
    b2.frame = CGRectMake(0, 48, 150, 48);
    [b2 setTitle:(gEnabledFlag ? @"映射:开" : @"映射:关") forState:UIControlStateNormal];
    [b2 setTitleColor:(gEnabledFlag ? UIColor.systemGreenColor : UIColor.systemGrayColor) forState:UIControlStateNormal];
    [b2 addTarget:[BKActionTarget shared] action:@selector(menuToggle) forControlEvents:UIControlEventTouchUpInside];

    [menu addSubview:b1];
    [menu addSubview:b2];
    gMenuView = menu;
    [gBallWindow addSubview:menu];
    menu.frame = CGRectMake(-158, 0, 150, 96);
}

#pragma mark - Editor

static void BKReloadMarkersFromCfg(void)
{
    for (UIView *v in gMarkers) [v removeFromSuperview];
    [gMarkers removeAllObjects];

    NSDictionary *cfg = BKReadCfg();
    id pts = cfg[@"Profiles"][gFrontBundle ?: @""];
    if (![pts isKindOfClass:[NSArray class]]) return;
    for (NSDictionary *pt in (NSArray *)pts) {
        NSString *type = pt[@"Type"] ?: @"Tap";
        CGPoint uiPt = BKUIKitFromNorm(CGPointMake([pt[@"X"] floatValue], [pt[@"Y"] floatValue]));
        BKMarkerView *m = BKMakeMarker(type, uiPt);
        m.keyEnc = pt[@"Key"] ?: pt[@"Button"];
        m.holdMs = pt[@"HoldMs"] ? [pt[@"HoldMs"] intValue] : 400;
        m.radius = pt[@"Radius"] ? [pt[@"Radius"] floatValue] : 0.12;
        m.sens = pt[@"Sens"] ? [pt[@"Sens"] floatValue] : 1.0;
        m.label.text = [NSString stringWithFormat:@"%@\n%@", BKTypeLabel(type), BKKeyDisplayName(m.keyEnc)];
        [gMarkers addObject:m];
    }
}

static void BKOpenEditor(void)
{
    if (gEditorWindow) return;
    gMarkers = [NSMutableArray array];

    CGRect screen = [UIScreen mainScreen].bounds;
    gEditorWindow = [[UIWindow alloc] initWithFrame:screen];
    gEditorWindow.windowLevel = UIWindowLevelAlert + 60;
    gEditorWindow.backgroundColor = UIColor.clearColor;

    UIViewController *vc = [[UIViewController alloc] init];
    gEditorWindow.rootViewController = vc;
    UIView *canvas = vc.view;
    canvas.backgroundColor = [UIColor colorWithWhite:0 alpha:0.25];

    UIStackView *bar = [[UIStackView alloc] init];
    bar.axis = UILayoutConstraintAxisHorizontal;
    bar.spacing = 6;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [canvas addSubview:bar];
    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:canvas.safeAreaLayoutGuide.topAnchor constant:8],
        [bar.centerXAnchor constraintEqualToAnchor:canvas.centerXAnchor],
    ]];

    BKActionTarget *t = [BKActionTarget shared];
    void (^addBtn)(NSString *, SEL, UIColor *) = ^(NSString *title, SEL sel, UIColor *color) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *bc = [UIButtonConfiguration plainButtonConfiguration];
        bc.title = title;
        bc.contentInsets = NSDirectionalEdgeInsetsMake(8, 10, 8, 10);
        bc.baseForegroundColor = UIColor.whiteColor;
        bc.background.backgroundColor = [color colorWithAlphaComponent:0.7];
        bc.cornerStyle = UIButtonConfigurationCornerStyleMedium;
        bc.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *attrs) {
            NSMutableDictionary *m = [attrs mutableCopy];
            m[NSFontAttributeName] = [UIFont boldSystemFontOfSize:13];
            return m;
        };
        b.configuration = bc;
        [b addTarget:t action:sel forControlEvents:UIControlEventTouchUpInside];
        [bar addArrangedSubview:b];
    };
    addBtn(@"+单击", @selector(addTap), UIColor.systemBlueColor);
    addBtn(@"+按下", @selector(addPress), UIColor.systemGreenColor);
    addBtn(@"+长按", @selector(addHold), UIColor.systemOrangeColor);
    addBtn(@"+方向", @selector(addDir), UIColor.systemPurpleColor);
    addBtn(@"完成", @selector(editorDone), UIColor.systemGrayColor);

    gBindBanner = [[UIView alloc] initWithFrame:CGRectMake(screen.size.width/2 - 130, screen.size.height - 90, 260, 36)];
    gBindBanner.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    gBindBanner.layer.cornerRadius = 8;
    gBindBanner.hidden = YES;
    UILabel *bl = [[UILabel alloc] initWithFrame:gBindBanner.bounds];
    bl.textAlignment = NSTextAlignmentCenter;
    bl.textColor = UIColor.whiteColor;
    bl.font = [UIFont systemFontOfSize:13];
    bl.text = @"按下要绑定的键或鼠标键…";
    bl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [gBindBanner addSubview:bl];
    [canvas addSubview:gBindBanner];

    [gEditorWindow makeKeyAndVisible];
    BKReloadMarkersFromCfg();
    for (UIView *m in gMarkers) [canvas addSubview:m];
}

#pragma mark - Ball

static void BKToggleEnabled(void)
{
    gEnabledFlag = !gEnabledFlag;
    BOOL en = gEnabledFlag;
    BKWriteCfg(^(NSMutableDictionary *cfg) { cfg[@"Enabled"] = @(en); });
}

static void BKSetupBall(void)
{
    if (gBallWindow) return;
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat bx = screen.size.width - 70;
    CGFloat by = screen.size.height * 0.35;
    gBallWindow = [[UIWindow alloc] initWithFrame:CGRectMake(bx, by, 56, 56)];
    gBallWindow.windowLevel = UIWindowLevelAlert + 50;
    gBallWindow.backgroundColor = UIColor.clearColor;

    UIViewController *vc = [[UIViewController alloc] init];
    gBallWindow.rootViewController = vc;
    vc.view.backgroundColor = UIColor.clearColor;

    UIButton *ball = [UIButton buttonWithType:UIButtonTypeCustom];
    ball.frame = vc.view.bounds;
    ball.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    ball.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.85];
    ball.layer.cornerRadius = 28;
    ball.layer.borderColor = UIColor.systemYellowColor.CGColor;
    ball.layer.borderWidth = 2;
    [ball setTitle:@"BK" forState:UIControlStateNormal];
    [ball setTitleColor:UIColor.systemYellowColor forState:UIControlStateNormal];
    ball.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [ball addTarget:[BKActionTarget shared] action:@selector(ballTap) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[BKActionTarget shared] action:@selector(ballPan:)];
    [ball addGestureRecognizer:pan];

    [vc.view addSubview:ball];
    [gBallWindow makeKeyAndVisible];
}

#pragma mark - Frontmost poll

static void BKPollFrontmost(void)
{
    Class sbCls = objc_getClass("SpringBoard");
    NSString *bid = nil;
    if (sbCls) {
        id sb = ((id (*)(id, SEL))objc_msgSend)(sbCls, @selector(sharedApplication));
        SEL sel = @selector(_accessibilityFrontMostApplication);
        if ([sb respondsToSelector:sel]) {
            id app = ((id (*)(id, SEL))objc_msgSend)(sb, sel);
            if ([app respondsToSelector:@selector(bundleIdentifier)]) {
                bid = ((id (*)(id, SEL))objc_msgSend)(app, @selector(bundleIdentifier));
            }
        }
    }
    if (bid.length && ![bid isEqualToString:gFrontBundle]) {
        gFrontBundle = bid;
        BKWriteCfg(^(NSMutableDictionary *cfg) { cfg[@"ActiveBundle"] = bid; });
    }
}

#pragma mark - Init

static void BKOverlayInit(void)
{
    gIOQ = dispatch_queue_create("com.wjf.ballkey.io", DISPATCH_QUEUE_SERIAL);
    NSDictionary *cfg = BKReadCfg();
    gEnabledFlag = cfg[@"Enabled"] ? [cfg[@"Enabled"] boolValue] : YES;
    gFrontBundle = cfg[@"ActiveBundle"];

    BKSetupBall();

    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        BKPollFrontmost();
    }];
}

%ctor {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BKOverlayInit();
        });
    }
}
