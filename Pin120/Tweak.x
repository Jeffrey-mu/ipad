// Pin120 2.2 — 让 iPad Pro (2018 / A12X) 的 ProMotion 稳定停在 120Hz
//
// 旧版为什么完全没用：
//   v1 的 Filter 只有 SpringBoard / backboardd，游戏进程根本没被注入；
//   而渲染刷新率是「前台 App 自己」向系统申请的，跟 SpringBoard 无关。
//   （ReplayKit 广播同样管不到别的 App 的帧率，所以 Pin120App 那条路走不通。）
//
// 这台机器本身是 ProMotion 120Hz 屏，但 iOS 会自适应在 120 / 80 / 60 之间跳。
// 全部在「游戏进程内」完成，改写游戏决定帧率的三个点，并每秒重压一次：
//   1) UIScreen.maximumFramesPerSecond  →  恒为 120
//      游戏判断「这台设备支不支持 120 帧」用的就是它。
//   2) CADisplayLink.preferredFramesPerSecond / preferredFrameRateRange  →  强制 120
//      引擎(Unity/Unreal)用它决定渲染节奏，游戏里往往写死 60/80。
//   3) Unity 原生 Application.targetFrameRate (UnityGet/SetTargetFrameRate)  →  强制 120
//      绕开游戏自己设置的帧率上限。
//   4) 可选：伪装 hw.machine 为 M1 iPad Pro + 伪装 thermalState / 低电量
//      有些游戏是按机型白名单或温度状态自己降画质/降帧率的。
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
#import <notify.h>
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
static void P120SBStart(void);
static void P120SBToggle(void);

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
- (void)sbTap:(UITapGestureRecognizer *)sender;
- (void)sbPan:(UIPanGestureRecognizer *)sender;
@end

static UIView   *gHUDBox    = nil;
static UILabel  *gHUDLabel  = nil;
static BOOL      gHUDExpanded = YES;   // 启动先展开几秒，方便找到
static BOOL      gHUDUserTouched = NO;
static BOOL      gHUDDismissed = NO;
static NSArray  *gHUDConstraints = nil;

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
    gHUDUserTouched = YES;
    // 收起状态：单击展开详情；展开状态：单击切换模式（关 / 标准 / 标准+机型伪装）
    if (gHUDExpanded) P120CycleMode();
    else              P120ToggleHUD();
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)sender
{
    if (sender.state != UIGestureRecognizerStateBegan) return;
    gHUDUserTouched = YES;
    if (gHUDExpanded) {
        P120ToggleHUD();          // 展开状态下长按 = 收起详情
    } else {
        P120HideCurrentApp();     // 收起状态下长按 = 本 App 不再显示
        gHUDDismissed = YES;
        gHUDBox.hidden = YES;
        [gHUDBox removeFromSuperview];
    }
}

- (void)sbTap:(UITapGestureRecognizer *)sender
{
    P120SBToggle();
}

- (void)sbPan:(UIPanGestureRecognizer *)sender
{
    UIView *v = sender.view;
    if (!v) return;
    CGPoint t = [sender translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [sender setTranslation:CGPointZero inView:v.superview];
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
    if (!gHUDBox) return;
    gHUDExpanded = !gHUDExpanded;
    gLastHUD = 0;              // 跳过节流，立刻刷新
    P120UpdateHUD();
}

// 直接挂到 App 自己的 key window 上。
// 比单独建一个 UIWindow 稳得多：不管游戏走不走 UIScene、启动多慢，都能显示。
static UIWindow *P120KeyWindow(void)
{
    UIWindow *fallback = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                if (w.isKeyWindow) return w;
                if (!fallback && !w.hidden && w.bounds.size.width > 0) fallback = w;
            }
        }
    }
    if (fallback) return fallback;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [UIApplication sharedApplication].keyWindow ?: [UIApplication sharedApplication].windows.firstObject;
#pragma clang diagnostic pop
}

static void P120AttachHUD(void)
{
    if (!gHUDBox || gHUDDismissed || gHUDBox.hidden) return;
    if (P120HiddenForCurrentApp()) return;

    UIWindow *host = P120KeyWindow();
    if (!host) return;
    if (gHUDBox.superview == host) { [host bringSubviewToFront:gHUDBox]; return; }

    if (gHUDConstraints) { [NSLayoutConstraint deactivateConstraints:gHUDConstraints]; gHUDConstraints = nil; }
    [gHUDBox removeFromSuperview];
    gHUDBox.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:gHUDBox];
    gHUDConstraints = @[
        [gHUDBox.leadingAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.leadingAnchor constant:8],
        [gHUDBox.topAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.topAnchor constant:8],
    ];
    [NSLayoutConstraint activateConstraints:gHUDConstraints];
    [host bringSubviewToFront:gHUDBox];
}

static void P120ShowHUD(void)
{
    if (P120HiddenForCurrentApp()) return;

    if (!gHUDBox) {
        gHUDBox = [[UIView alloc] init];
        gHUDBox.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.62];
        gHUDBox.layer.cornerRadius = 7;
        gHUDBox.layer.masksToBounds = YES;
        gHUDBox.userInteractionEnabled = YES;

        gHUDLabel = [[UILabel alloc] init];
        gHUDLabel.translatesAutoresizingMaskIntoConstraints = NO;
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
        ]];

        P120HUD *hud = [P120HUD shared];
        [gHUDBox addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:hud action:@selector(handleTap:)]];
        UILongPressGestureRecognizer *press =
            [[UILongPressGestureRecognizer alloc] initWithTarget:hud action:@selector(handleLongPress:)];
        press.minimumPressDuration = 0.45;
        [gHUDBox addGestureRecognizer:press];

        // 启动先展开 5 秒，方便一眼看到；用户碰过就不再自动收起
        gHUDExpanded = YES;
        gLastHUD = 0;
        P120UpdateHUD();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!gHUDUserTouched) {
                gHUDExpanded = NO;
                gLastHUD = 0;
                P120UpdateHUD();
            }
        });
    }
    P120AttachHUD();
}

#pragma mark - SpringBoard 悬浮条（铁证：插件到底有没有被加载）

// 插件只要被加载，桌面上就会出现这个条子。它顺便显示游戏进程上报的状态。
// 游戏进程 → SpringBoard 用 Darwin notify 传（沙盒之间唯一可靠的通道）。
#define kP120StateNotify "com.wjf.pin120.state"

static UIWindow *gSBWindow = nil;
static UIView   *gSBBox = nil;
static UILabel  *gSBLabel = nil;
static BOOL      gSBExpanded = NO;
static uint64_t  gRemoteState = 0;
static NSTimeInterval gRemoteStamp = 0;
static int       gSBToken = 0;
static NSTimer  *gSBTimer = nil;

static NSString *P120ThermalName(NSInteger t)
{
    switch (t) {
        case 0:  return @"正常";
        case 1:  return @"偏热";
        case 2:  return @"过热";
        case 3:  return @"极热";
    }
    return @"?";
}

static void P120SBLayout(void)
{
    if (!gSBWindow || !gSBLabel) return;

    CGSize sz = [gSBLabel sizeThatFits:CGSizeMake(380, CGFLOAT_MAX)];
    CGFloat w = ceil(sz.width) + 16.0, h = ceil(sz.height) + 8.0;
    CGRect scr = [UIScreen mainScreen].bounds;
    CGPoint c = gSBWindow.center;
    if (c.x <= 1 || c.y <= 1) c = CGPointMake(scr.size.width / 2.0, scr.size.height - 90);
    gSBWindow.frame = CGRectMake(c.x - w / 2.0, c.y - h / 2.0, w, h);
    gSBLabel.frame = CGRectMake(8, 4, w - 16, h - 8);
}

static void P120SBRefresh(void)
{
    if (!gSBLabel) return;

    NSInteger mode    = (NSInteger)(gRemoteState & 0x3);
    NSInteger thermal = (NSInteger)((gRemoteState >> 2) & 0x3);
    BOOL      lowPwr  = ((gRemoteState >> 4) & 0x1) != 0;
    NSInteger hz      = (NSInteger)((gRemoteState >> 8) & 0xFF);
    NSInteger engine  = (NSInteger)((gRemoteState >> 16) & 0xFF);
    NSInteger unity   = (NSInteger)((gRemoteState >> 24) & 0xFF);
    NSInteger relock  = (NSInteger)((gRemoteState >> 32) & 0xFFFF);

    BOOL online = (gRemoteStamp > 0) &&
                  ([NSDate timeIntervalSinceReferenceDate] - gRemoteStamp < 6.0);

    if (!gSBExpanded) {
        gSBLabel.text = online ? [NSString stringWithFormat:@"P120 %ldHz ✓", (long)hz]
                               : @"P120 ▸ 点我";
        return;
    }

    NSString *modeText = (mode == 0) ? @"关闭" : ((mode == 2) ? @"标准+机型伪装" : @"标准");
    NSString *gameLine = online
        ? [NSString stringWithFormat:@"游戏在线 · 屏幕 %ldHz · 引擎 %ld · Unity %ld", (long)hz, (long)engine, (long)unity]
        : @"游戏未上报（没进游戏，或注入失败）";

    gSBLabel.text = [NSString stringWithFormat:
        @"Pin120 2.3 · SpringBoard 已注入 ✓\n"
        @"%@\n"
        @"模式 %@ · 热:%@ 低电:%@ · 重压 %ld",
        gameLine, modeText, P120ThermalName(thermal), lowPwr ? @"开" : @"关", (long)relock];
}

static void P120SBToggle(void)
{
    gSBExpanded = !gSBExpanded;
    P120SBRefresh();
    P120SBLayout();
}

static void P120SBStart(void)
{
    if (gSBWindow) return;

    gSBWindow = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 140, 32)];
    gSBWindow.windowLevel = UIWindowLevelAlert + 100;
    gSBWindow.backgroundColor = [UIColor clearColor];
    gSBWindow.center = CGPointMake([UIScreen mainScreen].bounds.size.width / 2.0,
                                   [UIScreen mainScreen].bounds.size.height - 96);
    gSBWindow.rootViewController = [[UIViewController alloc] init];
    gSBWindow.rootViewController.view.backgroundColor = [UIColor clearColor];

    gSBBox = [[UIView alloc] initWithFrame:gSBWindow.bounds];
    gSBBox.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.65];
    gSBBox.layer.cornerRadius = 8;
    gSBBox.layer.masksToBounds = YES;
    gSBBox.userInteractionEnabled = YES;
    [gSBWindow.rootViewController.view addSubview:gSBBox];

    gSBLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    gSBLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    gSBLabel.textColor = [UIColor whiteColor];
    gSBLabel.numberOfLines = 0;
    gSBLabel.userInteractionEnabled = NO;
    gSBLabel.text = @"P120";
    [gSBBox addSubview:gSBLabel];

    P120HUD *hud = [P120HUD shared];
    [gSBBox addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:hud action:@selector(sbTap:)]];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:hud action:@selector(sbPan:)];
    [gSBBox addGestureRecognizer:pan];

    // 游戏进程上报的状态（Darwin notify，跨沙盒）
    notify_register_dispatch(kP120StateNotify, &gSBToken, dispatch_get_main_queue(), ^(int token) {
        uint64_t v = 0;
        if (notify_get_state(token, &v) == NOTIFY_STATUS_OK) {
            gRemoteState = v;
            gRemoteStamp = [NSDate timeIntervalSinceReferenceDate];
            P120SBRefresh();
            P120SBLayout();
        }
    });

    gSBTimer = [NSTimer timerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
        P120SBRefresh();
        P120SBLayout();
    }];
    [[NSRunLoop mainRunLoop] addTimer:gSBTimer forMode:NSRunLoopCommonModes];

    P120SBRefresh();
    P120SBLayout();
    [gSBWindow makeKeyAndVisible];   // BallKey 同款做法，SpringBoard 里最稳
}

#pragma mark - 状态上报（给 SpringBoard 挂件看）

static int gPostToken = 0;

static void P120PostState(void)
{
    if (!gActive) return;
    if (gPostToken == 0) {
        if (notify_register_check(kP120StateNotify, &gPostToken) != NOTIFY_STATUS_OK) return;
    }

    NSInteger th = 0;
    switch ([NSProcessInfo processInfo].thermalState) {
        case NSProcessInfoThermalStateFair:     th = 1; break;
        case NSProcessInfoThermalStateSerious:  th = 2; break;
        case NSProcessInfoThermalStateCritical: th = 3; break;
        default: th = 0; break;
    }

    uint64_t v = 0;
    v |= (uint64_t)(gMode & 0x3);
    v |= ((uint64_t)(th & 0x3)) << 2;
    v |= (([NSProcessInfo processInfo].isLowPowerModeEnabled ? 1ull : 0ull) << 4);
    v |= ((uint64_t)MIN((NSInteger)255, (NSInteger)(gMeasuredHz + 0.5))) << 8;
    v |= ((uint64_t)MIN((NSInteger)255, MAX((NSInteger)0, gEngineFPS))) << 16;
    v |= ((uint64_t)MIN((NSInteger)255, MAX((NSInteger)0, gUnityFPS))) << 24;
    v |= ((uint64_t)MIN((NSInteger)65535, gRelockCount)) << 32;

    notify_set_state(gPostToken, v);
    notify_post(kP120StateNotify);
}

// 顺便在 App 自己的容器里留一份，用 Filza 就能看
static void P120DumpStatus(void)
{
    NSString *text = gHUDLabel.text;
    if (text.length == 0) text = @"Pin120 injected";
    NSString *path = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"]
                      stringByAppendingPathComponent:@"pin120.status.txt"];
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
    if (!gActive) return;

    // 每秒给 SpringBoard 的悬浮条发一次状态（即使模式=关闭也发，方便排查）
    P120PostState();
    if (gMode == P120ModeOff) return;

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

    // 游戏可能重建/替换窗口，把挂件重新挂回当前 key window
    P120AttachHUD();

    P120UpdateHUD();

    static NSInteger dumpTick = 0;
    if (++dumpTick % 5 == 0) P120DumpStatus();
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

        // SpringBoard：只负责桌面悬浮条（证明插件被加载 + 显示游戏上报的状态），
        // 不碰任何帧率逻辑。
        if ([gBundleID isEqualToString:@"com.apple.springboard"] ||
            [gProcName isEqualToString:@"SpringBoard"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                P120SBStart();
                NSLog(@"[Pin120] SpringBoard chip started (2.3)");
            });
            return;
        }

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
