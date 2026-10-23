// Pin120 2.0 — 让 60Hz 的 iPad Pro (2018 / A12X) 上的游戏跑 120fps
//
// 旧版为什么完全没用：
//   v1 的 Filter 只有 SpringBoard / backboardd，游戏进程根本没被注入；
//   而渲染刷新率是「前台 App 自己」向系统申请的，跟 SpringBoard 无关。
//   （ReplayKit 广播同样管不到别的 App 的帧率，所以 Pin120App 那条路走不通。）
//
// 现在全部在「游戏进程内」完成，改写游戏决定帧率的三个点：
//   1) UIScreen.maximumFramesPerSecond  →  伪造为 120
//      游戏判断「这台设备支不支持 120 帧」用的就是它，60Hz 机型返回 60，
//      于是 120 帧选项被隐藏/降级，帧率被锁在 60/80。
//   2) CADisplayLink.preferredFramesPerSecond / preferredFrameRateRange  →  强制 120
//      引擎(Unity/Unreal)用它决定渲染节奏，游戏里往往写死 60/80。
//   3) Unity 原生 Application.targetFrameRate (UnityGet/SetTargetFrameRate)  →  强制 120
//      绕开游戏自己设置的帧率上限（80fps 多半就是从这条路来的）。
//   4) 可选：伪造 hw.machine 为 M1 iPad Pro (iPad13,4)
//      少数游戏是按机型白名单判断 120Hz 支持的。
//
// 注入范围：plist 不带 Filter → 所有进程都加载；%ctor 里只对第三方 App 生效，
// 系统进程(SpringBoard/UIKit/守护进程)不受任何影响。
//
// HUD：左上角小挂件。单击展开/收起详情，长按「收起状态」= 本 App 不再显示。

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <dlfcn.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>

#pragma mark - 常量 / 类型

static NSString *const kP120ConfigPath = @"/var/mobile/Library/Preferences/com.wjf.pin120.plist";
static NSString *const kP120FakeModel  = @"iPad13,4";   // iPad Pro 11" (M1)，带 ProMotion 120Hz

typedef NS_ENUM(NSInteger, P120Mode) {
    P120ModeOff      = 0,   // 完全不改写
    P120ModeStandard = 1,   // 伪造刷新率 + 强制 display link + Unity 120
    P120ModeFull     = 2,   // 再叠加机型伪装
};

#pragma mark - 全局状态

static P120Mode       gMode        = P120ModeStandard;
static BOOL           gActive      = NO;      // 当前进程是否启用
static BOOL           gInternal    = NO;      // 我们自己调用 setter 时置位，避免污染统计
static NSString      *gBundleID    = nil;
static NSString      *gProcName    = nil;
static NSInteger      gRealMaxFPS  = 0;       // 真实的 UIScreen.maximumFramesPerSecond
static NSInteger      gEngineFPS   = 0;       // 引擎请求的 preferredFramesPerSecond（原值）
static NSInteger      gEngineRange = 0;       // 引擎请求的帧率区间上限（原值）
static NSInteger      gUnityFPS    = 0;       // Unity Application.targetFrameRate（原值）
static double         gMeasuredHz  = 0.0;     // 实测 display link 回调频率
static NSTimeInterval gLastTick    = 0;

static NSHashTable   *gLinks       = nil;     // 所有见过的 CADisplayLink（弱引用）
static NSTimer       *gWatchdog    = nil;     // 每秒重新压 120 的看门狗
static NSInteger      gRelockCount = 0;
static NSTimeInterval gLastHUD     = 0;

static void P120UpdateHUD(void);
static void P120ShowHUD(void);
static void P120CycleMode(void);
static void P120ToggleHUD(void);

#pragma mark - 配置读写

static NSDictionary *P120ReadConfig(void)
{
    return [NSDictionary dictionaryWithContentsOfFile:kP120ConfigPath] ?: @{};
}

static void P120WriteConfig(NSMutableArray *hidden)
{
    NSDictionary *cfg = @{
        @"mode":   @(gMode),
        @"hidden": hidden ?: @[],
        @"ts":     @([[NSDate date] timeIntervalSince1970]),
    };
    [cfg writeToFile:kP120ConfigPath atomically:YES];
}

static void P120LoadConfig(void)
{
    NSNumber *mode = P120ReadConfig()[@"mode"];
    if (mode) gMode = (P120Mode)mode.integerValue;
}

static void P120SaveConfig(void)
{
    NSMutableArray *hidden = [NSMutableArray array];
    NSArray *oldHidden = P120ReadConfig()[@"hidden"];
    if (oldHidden) [hidden addObjectsFromArray:oldHidden];
    P120WriteConfig(hidden);
}

static BOOL P120HiddenForCurrentApp(void)
{
    NSArray *hidden = P120ReadConfig()[@"hidden"];
    if (!hidden.count || !gBundleID) return NO;
    return [hidden containsObject:gBundleID];
}

static void P120HideCurrentApp(void)
{
    NSMutableArray *hidden = [NSMutableArray array];
    NSArray *oldHidden = P120ReadConfig()[@"hidden"];
    if (oldHidden) [hidden addObjectsFromArray:oldHidden];
    if (gBundleID && ![hidden containsObject:gBundleID]) [hidden addObject:gBundleID];
    P120WriteConfig(hidden);
}

#pragma mark - HUD 交互

@interface P120HUD : NSObject
+ (instancetype)shared;
- (void)handleTap:(UITapGestureRecognizer *)sender;
- (void)handleLongPress:(UILongPressGestureRecognizer *)sender;
@end

static UIWindow *gHUDWindow = nil;
static UIView   *gHUDBox    = nil;
static UILabel  *gHUDLabel  = nil;
static BOOL      gHUDExpanded = NO;
static NSInteger gHUDAttempts = 0;

@implementation P120HUD

+ (instancetype)shared
{
    static P120HUD *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [P120HUD new]; });
    return shared;
}

- (void)handleTap:(UITapGestureRecognizer *)sender
{
    // 收起状态：单击展开详情；展开状态：单击切换模式（关 / 标准 / 标准+机型伪装）
    if (gHUDExpanded) P120CycleMode();
    else              P120ToggleHUD();
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)sender
{
    if (sender.state != UIGestureRecognizerStateBegan) return;
    if (gHUDExpanded) {
        P120ToggleHUD();       // 展开状态下长按 = 收起详情
    } else {
        P120HideCurrentApp();  // 收起状态下长按 = 本 App 不再显示
        gHUDWindow.hidden = YES;
    }
}

@end

#pragma mark - HUD 绘制

@interface P120Meter : NSObject
- (void)tick:(CADisplayLink *)link;
@end

@implementation P120Meter
- (void)tick:(CADisplayLink *)link
{
    NSTimeInterval now = link.timestamp;
    if (gLastTick > 0) {
        double dt = now - gLastTick;
        if (dt > 0.0005) {
            double hz = 1.0 / dt;
            gMeasuredHz = (gMeasuredHz > 0) ? (gMeasuredHz * 0.85 + hz * 0.15) : hz;
        }
    }
    gLastTick = now;
    P120UpdateHUD();
}
@end

static NSString *P120ModeText(void)
{
    switch (gMode) {
        case P120ModeOff:  return @"关闭";
        case P120ModeFull: return @"标准+机型伪装";
        default:           return @"标准";
    }
}

static NSString *P120ThermalText(void)
{
    switch ([NSProcessInfo processInfo].thermalState) {
        case NSProcessInfoThermalStateNominal:  return @"正常";
        case NSProcessInfoThermalStateFair:     return @"偏热";
        case NSProcessInfoThermalStateSerious:  return @"过热";
        case NSProcessInfoThermalStateCritical: return @"极热";
        default:                                return @"?";
    }
}

static void P120UpdateHUD(void)
{
    if (!gHUDLabel) return;

    // 每秒 4 次就够了，别跟着 60/120Hz 的 display link 每帧拼字符串
    NSTimeInterval now = CACurrentMediaTime();
    if (now - gLastHUD < 0.25) return;
    gLastHUD = now;

    NSString *modeText = P120ModeText();
    if (!gHUDExpanded) {
        gHUDLabel.text = [NSString stringWithFormat:@"P120 %@", modeText];
        return;
    }

    // 实时读一次：走的是 hook 之后的值，能直接看出 hook 有没有生效
    NSInteger reported = [UIScreen mainScreen].maximumFramesPerSecond;
    NSString *engine = gEngineFPS   > 0 ? [NSString stringWithFormat:@"%ld", (long)gEngineFPS]   : @"—";
    NSString *range  = gEngineRange > 0 ? [NSString stringWithFormat:@"%ld", (long)gEngineRange] : @"—";
    NSString *unity  = gUnityFPS != 0 ? [NSString stringWithFormat:@"%ld", (long)gUnityFPS]    : @"—";
    BOOL lowPower = [NSProcessInfo processInfo].isLowPowerModeEnabled;

    gHUDLabel.text = [NSString stringWithFormat:
        @"Pin120 %@ · %@\n"
        @"上报 %ld(真%ld) · 实测 %.0fHz · 热:%@%@ 低电:%@\n"
        @"引擎 %@fps(区间%@) · Unity %@ · 重压 %ld",
        modeText,
        gBundleID ?: (gProcName ?: @"?"),
        (long)reported,
        (long)gRealMaxFPS,
        gMeasuredHz,
        P120ThermalText(),
        (gMode == P120ModeFull ? @"(已伪装)" : @""),
        lowPower ? @"开" : @"关",
        engine, range, unity,
        (long)gRelockCount];
}

static void P120CycleMode(void)
{
    gMode = (P120Mode)((gMode + 1) % 3);
    P120SaveConfig();
    P120UpdateHUD();
}

static void P120ToggleHUD(void)
{
    if (!gHUDWindow) return;
    gHUDExpanded = !gHUDExpanded;
    P120UpdateHUD();
}

static void P120ShowHUD(void)
{
    if (gHUDWindow) { gHUDWindow.hidden = NO; return; }
    if (P120HiddenForCurrentApp()) return;

    // 很多 Unity 游戏用老式 AppDelegate 生命周期，根本没有 UIScene。
    // scene-based App 又需要等 scene 连上，所以这里分三路处理。
    BOOL sceneBased = NO;
    if (@available(iOS 13.0, *)) {
        sceneBased = ([[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIApplicationSceneManifest"] != nil);
    }

    UIWindowScene *scene = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)s;
                break;
            }
        }
        if (sceneBased && !scene && gHUDAttempts < 10) {
            // scene 还没连上，过一会儿再试
            gHUDAttempts++;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ P120ShowHUD(); });
            return;
        }
    }

    if (@available(iOS 13.0, *)) {
        if (scene) {
            gHUDWindow = [[UIWindow alloc] initWithWindowScene:scene];
        } else {
            gHUDWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }
    } else {
        gHUDWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }
    gHUDWindow.windowLevel = UIWindowLevelAlert + 100;
    gHUDWindow.backgroundColor = [UIColor clearColor];

    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor clearColor];
    gHUDWindow.rootViewController = root;

    gHUDBox = [[UIView alloc] init];
    gHUDBox.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    gHUDBox.layer.cornerRadius = 7;
    gHUDBox.layer.masksToBounds = YES;
    gHUDBox.userInteractionEnabled = YES;
    [root.view addSubview:gHUDBox];

    gHUDLabel = [[UILabel alloc] init];
    gHUDLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    gHUDLabel.textColor = [UIColor whiteColor];
    gHUDLabel.numberOfLines = 0;
    gHUDLabel.text = @"Pin120";
    [gHUDBox addSubview:gHUDLabel];

    [NSLayoutConstraint activateConstraints:@[
        [gHUDLabel.topAnchor constraintEqualToAnchor:gHUDBox.topAnchor constant:3],
        [gHUDLabel.bottomAnchor constraintEqualToAnchor:gHUDBox.bottomAnchor constant:-3],
        [gHUDLabel.leadingAnchor constraintEqualToAnchor:gHUDBox.leadingAnchor constant:6],
        [gHUDLabel.trailingAnchor constraintEqualToAnchor:gHUDBox.trailingAnchor constant:-6],
        [gHUDBox.leadingAnchor constraintEqualToAnchor:root.view.safeAreaLayoutGuide.leadingAnchor constant:6],
        [gHUDBox.topAnchor constraintEqualToAnchor:root.view.safeAreaLayoutGuide.topAnchor constant:6],
    ]];

    P120HUD *hud = [P120HUD shared];
    [gHUDBox addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:hud action:@selector(handleTap:)]];
    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:hud action:@selector(handleLongPress:)];
    press.minimumPressDuration = 0.45;
    [gHUDBox addGestureRecognizer:press];

    P120UpdateHUD();
    gHUDWindow.hidden = NO;   // 刻意不 makeKeyAndVisible，别抢游戏的第一响应者
}

#pragma mark - 工具

static void P120TuneLink(CADisplayLink *link)
{
    if (!gActive || gMode == P120ModeOff || !link) return;
    if (!gLinks) gLinks = [NSHashTable weakObjectsHashTable];
    [gLinks addObject:link];
    gInternal = YES;
    @try {
        [link setPreferredFrameRateRange:CAFrameRateRangeMake(120.0f, 120.0f, 120.0f)];
        [link setPreferredFramesPerSecond:120];
    } @catch (NSException *e) {
    }
    gInternal = NO;
}

#pragma mark - Unity 原生帧率接口

static int  (*gOrigUnityGetTargetFrameRate)(void) = NULL;
static void (*gOrigUnitySetTargetFrameRate)(int) = NULL;

static int P120UnityGetTargetFrameRate(void)
{
    int v = gOrigUnityGetTargetFrameRate ? gOrigUnityGetTargetFrameRate() : 0;
    gUnityFPS = v;
    if (gActive && gMode != P120ModeOff && v > 0) return 120;
    return v;
}

static void P120UnitySetTargetFrameRate(int fr)
{
    gUnityFPS = fr;
    if (gActive && gMode != P120ModeOff && fr > 0) fr = 120;
    if (gOrigUnitySetTargetFrameRate) gOrigUnitySetTargetFrameRate(fr);
}

// Unity 的符号可能比插件加载得更晚（UnityFramework.framework 是 App 启动后才加载的），
// 所以允许反复重试。这里刻意不主动 dlopen，避免打乱 Unity 自己的加载流程。
static void P120TryHookUnity(void)
{
    if (gOrigUnityGetTargetFrameRate && gOrigUnitySetTargetFrameRate) return;

    void *getSym = dlsym(RTLD_DEFAULT, "UnityGetTargetFrameRate");
    void *setSym = dlsym(RTLD_DEFAULT, "UnitySetTargetFrameRate");
    if (getSym && !gOrigUnityGetTargetFrameRate) {
        MSHookFunction(getSym, (void **)&gOrigUnityGetTargetFrameRate, (void *)P120UnityGetTargetFrameRate);
    }
    if (setSym && !gOrigUnitySetTargetFrameRate) {
        MSHookFunction(setSym, (void **)&gOrigUnitySetTargetFrameRate, (void *)P120UnitySetTargetFrameRate);
    }
}

#pragma mark - 机型伪装

typedef int (*P120SysctlbynameFn)(const char *, void *, size_t *, void *, size_t);
static P120SysctlbynameFn gOrigSysctlbyname = NULL;

static int P120Sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen)
{
    if (gActive && gMode == P120ModeFull && name && oldp && strcmp(name, "hw.machine") == 0) {
        const char *fake = [kP120FakeModel UTF8String];
        size_t len = strlen(fake) + 1;
        if (oldlenp) {
            if (*oldlenp < len) { *oldlenp = len; return ENOMEM; }
            memcpy(oldp, fake, len);
            *oldlenp = len;
            return 0;
        }
    }
    return gOrigSysctlbyname ? gOrigSysctlbyname(name, oldp, oldlenp, newp, newlen) : -1;
}

// 有些游戏用 uname() 而不是 sysctlbyname 拿机型，一并处理
typedef int (*P120UnameFn)(struct utsname *);
static P120UnameFn gOrigUname = NULL;

static int P120Uname(struct utsname *buf)
{
    int ret = gOrigUname ? gOrigUname(buf) : -1;
    if (ret == 0 && gActive && gMode == P120ModeFull && buf) {
        const char *fake = [kP120FakeModel UTF8String];
        size_t len = strlen(fake) + 1;
        if (len <= sizeof(buf->machine)) {
            memcpy(buf->machine, fake, len);
        }
    }
    return ret;
}

#pragma mark - 看门狗

// 每秒把还活着的 display link 重新压回 120。
// 排除「游戏过一会儿自己把帧率改回去」这种可能：改回去也会立刻被压回来。
static void P120Watchdog(void)
{
    if (!gActive || gMode == P120ModeOff) return;

    NSArray *links = gLinks.allObjects;
    if (links.count) {
        for (CADisplayLink *l in links) {
            @try {
                gInternal = YES;
                [l setPreferredFrameRateRange:CAFrameRateRangeMake(120.0f, 120.0f, 120.0f)];
                [l setPreferredFramesPerSecond:120];
                gInternal = NO;
            } @catch (NSException *e) {
                gInternal = NO;
            }
        }
        gRelockCount++;
    }

    P120TryHookUnity();
    P120UpdateHUD();
}

#pragma mark - Hooks

// 放在 group 里：只有第三方 App 进程才 %init(All)，
// 系统进程(SpringBoard/UIKit/守护进程)连 hook 都不会装，零开销零风险。
%group All

%hook UIScreen

- (NSInteger)maximumFramesPerSecond
{
    if (gActive && gMode != P120ModeOff) return 120;
    return %orig;
}

%end

// 强力模式下顺手把「过热 / 低电量」也伪装成正常：
// 有些游戏是看 thermalState 自己降画质/降帧率的，伪装后就降不下去了。
%hook NSProcessInfo

- (NSProcessInfoThermalState)thermalState
{
    if (gActive && gMode == P120ModeFull) return NSProcessInfoThermalStateNominal;
    return %orig;
}

- (BOOL)isLowPowerModeEnabled
{
    if (gActive && gMode == P120ModeFull) return NO;
    return %orig;
}

%end

%hook CADisplayLink

- (void)setPreferredFramesPerSecond:(NSInteger)fps
{
    if (!gInternal) gEngineFPS = fps;
    if (gActive && gMode != P120ModeOff && fps > 0) fps = 120;
    %orig(fps);
}

- (void)setPreferredFrameRateRange:(CAFrameRateRange)range
{
    if (!gInternal) gEngineRange = (NSInteger)range.maximum;
    if (gActive && gMode != P120ModeOff) {
        range = CAFrameRateRangeMake(120.0f, 120.0f, 120.0f);
    }
    %orig(range);
}

+ (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)selector
{
    CADisplayLink *link = %orig(target, selector);
    P120TuneLink(link);
    return link;
}

+ (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)selector queue:(NSOperationQueue *)queue
{
    CADisplayLink *link = %orig(target, selector, queue);
    P120TuneLink(link);
    return link;
}

%end

%end

#pragma mark - 启动

%ctor
{
    @autoreleasepool {
        gBundleID = [[NSBundle mainBundle] bundleIdentifier];
        gProcName = [[NSProcessInfo processInfo] processName];

        // 必须在装 hook 之前取真实值
        gRealMaxFPS = [UIScreen mainScreen].maximumFramesPerSecond;

        BOOL isApple = [gBundleID hasPrefix:@"com.apple."];
        BOOL hasUI   = (NSClassFromString(@"UIApplication") != nil);
        if (getenv("PIN120_ALL")) isApple = NO;

        // 系统进程 / 无 UI 的守护进程：完全不碰
        if (isApple || !hasUI) return;

        gActive = YES;
        P120LoadConfig();
        %init(All);

        // Unity 原生帧率接口（球球大作战等 Unity 游戏走这条路）。
        // 不主动 dlopen UnityFramework（会打乱它自己的加载流程），
        // 找不到就交给看门狗每秒重试。
        P120TryHookUnity();

        // 机型伪装（可选）
        MSHookFunction((void *)sysctlbyname, (void **)&gOrigSysctlbyname, (void *)P120Sysctlbyname);
        MSHookFunction((void *)uname, (void **)&gOrigUname, (void *)P120Uname);

        dispatch_async(dispatch_get_main_queue(), ^{
            P120Meter *meter = [P120Meter new];
            CADisplayLink *link = [CADisplayLink displayLinkWithTarget:meter selector:@selector(tick:)];
            gInternal = YES;
            [link setPreferredFrameRateRange:CAFrameRateRangeMake(120.0f, 120.0f, 120.0f)];
            gInternal = NO;
            [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

            // 看门狗：每秒重新压 120 + 补 hook Unity 符号
            gWatchdog = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
                P120Watchdog();
            }];
            [[NSRunLoop mainRunLoop] addTimer:gWatchdog forMode:NSRunLoopCommonModes];

            P120ShowHUD();
            NSLog(@"[Pin120] injected into %@ (%@) mode=%ld realMaxFPS=%ld",
                  gBundleID ?: @"no-bundle", gProcName ?: @"?", (long)gMode, (long)gRealMaxFPS);
        });
    }
}
