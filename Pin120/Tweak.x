// Pin120 2.2 鈥?璁?iPad Pro (2018 / A12X) 鐨?ProMotion 绋冲畾鍋滃湪 120Hz
//
// 鏃х増涓轰粈涔堝畬鍏ㄦ病鐢細
//   v1 鐨?Filter 鍙湁 SpringBoard / backboardd锛屾父鎴忚繘绋嬫牴鏈病琚敞鍏ワ紱
//   鑰屾覆鏌撳埛鏂扮巼鏄€屽墠鍙?App 鑷繁銆嶅悜绯荤粺鐢宠鐨勶紝璺?SpringBoard 鏃犲叧銆?
//   锛圧eplayKit 骞挎挱鍚屾牱绠′笉鍒板埆鐨?App 鐨勫抚鐜囷紝鎵€浠?Pin120App 閭ｆ潯璺蛋涓嶉€氥€傦級
//
// 杩欏彴鏈哄櫒鏈韩鏄?ProMotion 120Hz 灞忥紝浣?iOS 浼氳嚜閫傚簲鍦?120 / 80 / 60 涔嬮棿璺炽€?
// 鍏ㄩ儴鍦ㄣ€屾父鎴忚繘绋嬪唴銆嶅畬鎴愶紝鏀瑰啓娓告垙鍐冲畾甯х巼鐨勪笁涓偣锛屽苟姣忕閲嶅帇涓€娆★細
//   1) UIScreen.maximumFramesPerSecond  鈫? 鎭掍负 120
//      娓告垙鍒ゆ柇銆岃繖鍙拌澶囨敮涓嶆敮鎸?120 甯с€嶇敤鐨勫氨鏄畠銆?
//   2) CADisplayLink.preferredFramesPerSecond / preferredFrameRateRange  鈫? 寮哄埗 120
//      寮曟搸(Unity/Unreal)鐢ㄥ畠鍐冲畾娓叉煋鑺傚锛屾父鎴忛噷寰€寰€鍐欐 60/80銆?
//   3) Unity 鍘熺敓 Application.targetFrameRate (UnityGet/SetTargetFrameRate)  鈫? 寮哄埗 120
//      缁曞紑娓告垙鑷繁璁剧疆鐨勫抚鐜囦笂闄愩€?
//   4) 鍙€夛細浼 hw.machine 涓?M1 iPad Pro + 浼 thermalState / 浣庣數閲?
//      鏈変簺娓告垙鏄寜鏈哄瀷鐧藉悕鍗曟垨娓╁害鐘舵€佽嚜宸遍檷鐢昏川/闄嶅抚鐜囩殑銆?
//
// 娉ㄥ叆鑼冨洿锛歱list 涓嶅甫 Filter 鈫?鎵€鏈夎繘绋嬮兘鍔犺浇锛?ctor 閲屽彧瀵圭涓夋柟 App 鐢熸晥锛?
// 绯荤粺杩涚▼(SpringBoard/UIKit/瀹堟姢杩涚▼)涓嶅彈浠讳綍褰卞搷銆?
//
// HUD锛氬乏涓婅灏忔寕浠躲€傚崟鍑诲睍寮€/鏀惰捣璇︽儏锛岄暱鎸夈€屾敹璧风姸鎬併€? 鏈?App 涓嶅啀鏄剧ず銆?

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

#pragma mark - 甯搁噺 / 绫诲瀷

static NSString *const kP120ConfigPath = @"/var/mobile/Library/Preferences/com.wjf.pin120.plist";
static NSString *const kP120FakeModel  = @"iPad13,4";   // iPad Pro 11" (M1)锛屽甫 ProMotion 120Hz

typedef NS_ENUM(NSInteger, P120Mode) {
    P120ModeOff      = 0,   // 瀹屽叏涓嶆敼鍐?
    P120ModeStandard = 1,   // 浼€犲埛鏂扮巼 + 寮哄埗 display link + Unity 120
    P120ModeFull     = 2,   // 鍐嶅彔鍔犳満鍨嬩吉瑁?
};

#pragma mark - 鍏ㄥ眬鐘舵€?

static P120Mode       gMode        = P120ModeStandard;
static BOOL           gActive      = NO;      // 褰撳墠杩涚▼鏄惁鍚敤
static BOOL           gInternal    = NO;      // 鎴戜滑鑷繁璋冪敤 setter 鏃剁疆浣嶏紝閬垮厤姹℃煋缁熻
static NSString      *gBundleID    = nil;
static NSString      *gProcName    = nil;
static NSInteger      gRealMaxFPS  = 0;       // 鐪熷疄鐨?UIScreen.maximumFramesPerSecond
static NSInteger      gEngineFPS   = 0;       // 寮曟搸璇锋眰鐨?preferredFramesPerSecond锛堝師鍊硷級
static NSInteger      gEngineRange = 0;       // 寮曟搸璇锋眰鐨勫抚鐜囧尯闂翠笂闄愶紙鍘熷€硷級
static NSInteger      gUnityFPS    = 0;       // Unity Application.targetFrameRate锛堝師鍊硷級
static double         gMeasuredHz  = 0.0;     // 瀹炴祴 display link 鍥炶皟棰戠巼
static NSTimeInterval gLastTick    = 0;

static NSHashTable   *gLinks       = nil;     // 鎵€鏈夎杩囩殑 CADisplayLink锛堝急寮曠敤锛?
static NSTimer       *gWatchdog    = nil;     // 姣忕閲嶆柊鍘?120 鐨勭湅闂ㄧ嫍
static NSInteger      gRelockCount = 0;
static NSTimeInterval gLastHUD     = 0;
static BOOL           gWantHUD     = NO;      // 榛樿涓嶇敾鐣岄潰锛屽彧鍐欐棩蹇楋紙鎺掓煡鍗℃鐢級

static void P120UpdateHUD(void);
static void P120ShowHUD(void);
static void P120CycleMode(void);
static void P120ToggleHUD(void);
static void P120SBStart(void);
static void P120SBToggle(void);

#pragma mark - 閰嶇疆璇诲啓

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
    NSDictionary *cfg = P120ReadConfig();
    NSNumber *mode = cfg[@"mode"];
    if (mode) gMode = (P120Mode)mode.integerValue;
    NSNumber *hud = cfg[@"hud"];
    gWantHUD = hud ? hud.boolValue : NO;   // 榛樿涓嶇敾 HUD
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

#pragma mark - HUD 浜や簰

@interface P120HUD : NSObject
+ (instancetype)shared;
- (void)handleTap:(UITapGestureRecognizer *)sender;
- (void)handleLongPress:(UILongPressGestureRecognizer *)sender;
- (void)sbTap:(UITapGestureRecognizer *)sender;
- (void)sbPan:(UIPanGestureRecognizer *)sender;
@end

static UIView   *gHUDBox    = nil;
static UILabel  *gHUDLabel  = nil;
static BOOL      gHUDExpanded = YES;   // 鍚姩鍏堝睍寮€鍑犵锛屾柟渚挎壘鍒?
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
    // 鏀惰捣鐘舵€侊細鍗曞嚮灞曞紑璇︽儏锛涘睍寮€鐘舵€侊細鍗曞嚮鍒囨崲妯″紡锛堝叧 / 鏍囧噯 / 鏍囧噯+鏈哄瀷浼锛?
    if (gHUDExpanded) P120CycleMode();
    else              P120ToggleHUD();
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)sender
{
    if (sender.state != UIGestureRecognizerStateBegan) return;
    gHUDUserTouched = YES;
    if (gHUDExpanded) {
        P120ToggleHUD();          // 灞曞紑鐘舵€佷笅闀挎寜 = 鏀惰捣璇︽儏
    } else {
        P120HideCurrentApp();     // 鏀惰捣鐘舵€佷笅闀挎寜 = 鏈?App 涓嶅啀鏄剧ず
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
#pragma mark - HUD 缁樺埗

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
        case P120ModeOff:  return @"鍏抽棴";
        case P120ModeFull: return @"鏍囧噯+鏈哄瀷浼";
        default:           return @"鏍囧噯";
    }
}

static NSString *P120ThermalText(void)
{
    switch ([NSProcessInfo processInfo].thermalState) {
        case NSProcessInfoThermalStateNominal:  return @"姝ｅ父";
        case NSProcessInfoThermalStateFair:     return @"鍋忕儹";
        case NSProcessInfoThermalStateSerious:  return @"杩囩儹";
        case NSProcessInfoThermalStateCritical: return @"鏋佺儹";
        default:                                return @"?";
    }
}

static void P120UpdateHUD(void)
{
    if (!gHUDLabel) return;

    // 姣忕 4 娆″氨澶熶簡锛屽埆璺熺潃 60/120Hz 鐨?display link 姣忓抚鎷煎瓧绗︿覆
    NSTimeInterval now = CACurrentMediaTime();
    if (now - gLastHUD < 0.25) return;
    gLastHUD = now;

    NSString *modeText = P120ModeText();
    if (!gHUDExpanded) {
        gHUDLabel.text = [NSString stringWithFormat:@"P120 %@", modeText];
        return;
    }

    // 瀹炴椂璇讳竴娆★細璧扮殑鏄?hook 涔嬪悗鐨勫€硷紝鑳界洿鎺ョ湅鍑?hook 鏈夋病鏈夌敓鏁?
    NSInteger reported = [UIScreen mainScreen].maximumFramesPerSecond;
    NSString *engine = gEngineFPS   > 0 ? [NSString stringWithFormat:@"%ld", (long)gEngineFPS]   : @"鈥?;
    NSString *range  = gEngineRange > 0 ? [NSString stringWithFormat:@"%ld", (long)gEngineRange] : @"鈥?;
    NSString *unity  = gUnityFPS != 0 ? [NSString stringWithFormat:@"%ld", (long)gUnityFPS]    : @"鈥?;
    BOOL lowPower = [NSProcessInfo processInfo].isLowPowerModeEnabled;

    gHUDLabel.text = [NSString stringWithFormat:
        @"Pin120 %@ 路 %@\n"
        @"涓婃姤 %ld(鐪?ld) 路 瀹炴祴 %.0fHz 路 鐑?%@%@ 浣庣數:%@\n"
        @"寮曟搸 %@fps(鍖洪棿%@) 路 Unity %@ 路 閲嶅帇 %ld",
        modeText,
        gBundleID ?: (gProcName ?: @"?"),
        (long)reported,
        (long)gRealMaxFPS,
        gMeasuredHz,
        P120ThermalText(),
        (gMode == P120ModeFull ? @"(宸蹭吉瑁?" : @""),
        lowPower ? @"寮€" : @"鍏?,
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
    gLastHUD = 0;              // 璺宠繃鑺傛祦锛岀珛鍒诲埛鏂?
    P120UpdateHUD();
}

// 鐩存帴鎸傚埌 App 鑷繁鐨?key window 涓娿€?
// 姣斿崟鐙缓涓€涓?UIWindow 绋冲緱澶氾細涓嶇娓告垙璧颁笉璧?UIScene銆佸惎鍔ㄥ鎱紝閮借兘鏄剧ず銆?
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

        // 鍚姩鍏堝睍寮€ 5 绉掞紝鏂逛究涓€鐪肩湅鍒帮紱鐢ㄦ埛纰拌繃灏变笉鍐嶈嚜鍔ㄦ敹璧?
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

#pragma mark - SpringBoard 鎮诞鏉★紙閾佽瘉锛氭彃浠跺埌搴曟湁娌℃湁琚姞杞斤級

// 鎻掍欢鍙琚姞杞斤紝妗岄潰涓婂氨浼氬嚭鐜拌繖涓潯瀛愩€傚畠椤轰究鏄剧ず娓告垙杩涚▼涓婃姤鐨勭姸鎬併€?
// 娓告垙杩涚▼ 鈫?SpringBoard 鐢?Darwin notify 浼狅紙娌欑洅涔嬮棿鍞竴鍙潬鐨勯€氶亾锛夈€?
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
        case 0:  return @"姝ｅ父";
        case 1:  return @"鍋忕儹";
        case 2:  return @"杩囩儹";
        case 3:  return @"鏋佺儹";
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
        gSBLabel.text = online ? [NSString stringWithFormat:@"P120 %ldHz 鉁?, (long)hz]
                               : @"P120 鈻?鐐规垜";
        return;
    }

    NSString *modeText = (mode == 0) ? @"鍏抽棴" : ((mode == 2) ? @"鏍囧噯+鏈哄瀷浼" : @"鏍囧噯");
    NSString *gameLine = online
        ? [NSString stringWithFormat:@"娓告垙鍦ㄧ嚎 路 灞忓箷 %ldHz 路 寮曟搸 %ld 路 Unity %ld", (long)hz, (long)engine, (long)unity]
        : @"娓告垙鏈笂鎶ワ紙娌¤繘娓告垙锛屾垨娉ㄥ叆澶辫触锛?;

    gSBLabel.text = [NSString stringWithFormat:
        @"Pin120 2.3 路 SpringBoard 宸叉敞鍏?鉁揬n"
        @"%@\n"
        @"妯″紡 %@ 路 鐑?%@ 浣庣數:%@ 路 閲嶅帇 %ld",
        gameLine, modeText, P120ThermalName(thermal), lowPwr ? @"寮€" : @"鍏?, (long)relock];
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

    // 娓告垙杩涚▼涓婃姤鐨勭姸鎬侊紙Darwin notify锛岃法娌欑洅锛?
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
    [gSBWindow makeKeyAndVisible];   // BallKey 鍚屾鍋氭硶锛孲pringBoard 閲屾渶绋?
}

#pragma mark - 鐘舵€佷笂鎶ワ紙缁?SpringBoard 鎸備欢鐪嬶級

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

// 椤轰究鍦?App 鑷繁鐨勫鍣ㄩ噷鐣欎竴浠斤紝鐢?Filza 灏辫兘鐪?
static void P120DumpStatus(void)
{
    NSString *text = gHUDLabel.text;
    if (text.length == 0) text = @"Pin120 injected";
    NSString *path = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"]
                      stringByAppendingPathComponent:@"pin120.status.txt"];
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark - 宸ュ叿

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

#pragma mark - Unity 鍘熺敓甯х巼鎺ュ彛

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

// Unity 鐨勭鍙峰彲鑳芥瘮鎻掍欢鍔犺浇寰楁洿鏅氾紙UnityFramework.framework 鏄?App 鍚姩鍚庢墠鍔犺浇鐨勶級锛?
// 鎵€浠ュ厑璁稿弽澶嶉噸璇曘€傝繖閲屽埢鎰忎笉涓诲姩 dlopen锛岄伩鍏嶆墦涔?Unity 鑷繁鐨勫姞杞芥祦绋嬨€?
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

#pragma mark - 鏈哄瀷浼

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

// 鏈変簺娓告垙鐢?uname() 鑰屼笉鏄?sysctlbyname 鎷挎満鍨嬶紝涓€骞跺鐞?
typedef int (*P120UnameFn)(struct utsname *);
static P120UnameFn gOrigUname = NULL;

// 鍙湪銆屾爣鍑?鏈哄瀷浼銆嶆ā寮忎笅鎵嶈杩欎袱涓?hook锛屽噺灏戦粯璁よ矾寰勭殑椋庨櫓
static void P120HookSysctlIfNeeded(void)
{
    if (gMode != P120ModeFull) return;
    if (!gOrigSysctlbyname) {
        MSHookFunction((void *)sysctlbyname, (void **)&gOrigSysctlbyname, (void *)P120Sysctlbyname);
    }
    if (!gOrigUname) {
        MSHookFunction((void *)uname, (void **)&gOrigUname, (void *)P120Uname);
    }
}

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

#pragma mark - 鐪嬮棬鐙?

// 姣忕鎶婅繕娲荤潃鐨?display link 閲嶆柊鍘嬪洖 120銆?
// 鎺掗櫎銆屾父鎴忚繃涓€浼氬効鑷繁鎶婂抚鐜囨敼鍥炲幓銆嶈繖绉嶅彲鑳斤細鏀瑰洖鍘讳篃浼氱珛鍒昏鍘嬪洖鏉ャ€?
static void P120Watchdog(void)
{
    if (!gActive) return;

    static NSInteger tick = 0;
    tick++;

    // 蹇冭烦鏃ュ織锛氭棩蹇楅噷鑳界湅鍒拌繖鏉?= 鎻掍欢纭疄杩涗簡杩欎釜杩涚▼
    if (tick % 3 == 0) {
        NSLog(@"[Pin120] alive pid=%d mode=%ld hz=%.1f engine=%ld unity=%ld thermal=%ld relock=%ld",
              getpid(), (long)gMode, gMeasuredHz, (long)gEngineFPS, (long)gUnityFPS,
              (long)[NSProcessInfo processInfo].thermalState, (long)gRelockCount);
        P120DumpStatus();
    }

    // 缁?SpringBoard 鎮诞鏉″彂鐘舵€侊紙鏈夊氨鍙戯紝娌℃湁涔熶笉褰卞搷锛?
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
    P120HookSysctlIfNeeded();

    // 娓告垙鍙兘閲嶅缓/鏇挎崲绐楀彛锛屾妸鎸備欢閲嶆柊鎸傚洖褰撳墠 key window
    if (gWantHUD) {
        P120AttachHUD();
        P120UpdateHUD();
    }
}

#pragma mark - Hooks

// 鏀惧湪 group 閲岋細鍙湁绗笁鏂?App 杩涚▼鎵?%init(All)锛?
// 绯荤粺杩涚▼(SpringBoard/UIKit/瀹堟姢杩涚▼)杩?hook 閮戒笉浼氳锛岄浂寮€閿€闆堕闄┿€?
%group All

%hook UIScreen

- (NSInteger)maximumFramesPerSecond
{
    if (gActive && gMode != P120ModeOff) return 120;
    return %orig;
}

%end

// 寮哄姏妯″紡涓嬮『鎵嬫妸銆岃繃鐑?/ 浣庣數閲忋€嶄篃浼鎴愭甯革細
// 鏈変簺娓告垙鏄湅 thermalState 鑷繁闄嶇敾璐?闄嶅抚鐜囩殑锛屼吉瑁呭悗灏遍檷涓嶄笅鍘讳簡銆?
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

#pragma mark - 鍚姩

%ctor
{
    @autoreleasepool {
        gBundleID = [[NSBundle mainBundle] bundleIdentifier];
        gProcName = [[NSProcessInfo processInfo] processName];

        // 鍔犺浇鑷锛氬彧瑕佹彃浠惰繘浜嗚繖涓繘绋嬶紝灏卞線璇?App 鑷繁鐨勫鍣ㄩ噷鐣欎竴涓枃浠躲€?
        // Filza 鈫?<App 瀹瑰櫒>/Library/Preferences/pin120.loaded.txt 瀛樺湪 = 娉ㄥ叆鎴愬姛銆?
        @try {
            NSString *dir  = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"];
            NSString *path = [dir stringByAppendingPathComponent:@"pin120.loaded.txt"];
            NSString *info = [NSString stringWithFormat:
                              @"Pin120 2.7.0 loaded\nbundle=%@\nproc=%@\narch=%@\ntime=%@\n",
                              gBundleID ?: @"?", gProcName ?: @"?",
#ifdef __arm64e__
                              @"arm64e",
#else
                              @"arm64",
#endif
                              [NSDate date]];
            [info writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSLog(@"[Pin120] loaded marker written to %@", path);
        } @catch (NSException *e) {
        }

        // 鍙仛绾?C 鐨勪簨锛氫笉纰?UIKit锛圼UIScreen mainScreen] 鍦?dylib 鏋勯€犳湡浼氭閿侊紝
        // 杩欏氨鏄?2.5 鎶?Sileo / 娓告垙鍗℃鐨勫師鍥狅級銆傜湡瀹炲埛鏂扮巼绛夎繘涓婚槦鍒楀悗鍐嶈銆?
        BOOL isApple = [gBundleID hasPrefix:@"com.apple."];
        BOOL hasUI   = (NSClassFromString(@"UIApplication") != nil);
        if (getenv("PIN120_ALL")) isApple = NO;

        // 绯荤粺杩涚▼ / 鏃?UI 鐨勫畧鎶よ繘绋嬶細瀹屽叏涓嶇
        if (isApple || !hasUI) return;

        gActive = YES;
        P120LoadConfig();
        %init(All);

        // Unity 鍘熺敓甯х巼鎺ュ彛锛堢悆鐞冨ぇ浣滄垬绛?Unity 娓告垙璧拌繖鏉¤矾锛夈€?
        // 涓嶄富鍔?dlopen UnityFramework锛堜細鎵撲贡瀹冭嚜宸辩殑鍔犺浇娴佺▼锛夛紝
        // 鎵句笉鍒板氨浜ょ粰鐪嬮棬鐙楁瘡绉掗噸璇曘€?
        P120TryHookUnity();

        dispatch_async(dispatch_get_main_queue(), ^{
            // UIKit 姝ゆ椂宸茬粡鍒濆鍖栧ソ锛岃繖鎵嶆槸鑳藉畨鍏ㄨ鍙栫殑鏃舵満
            gRealMaxFPS = [UIScreen mainScreen].maximumFramesPerSecond;

            P120Meter *meter = [P120Meter new];
            CADisplayLink *link = [CADisplayLink displayLinkWithTarget:meter selector:@selector(tick:)];
            gInternal = YES;
            [link setPreferredFrameRateRange:CAFrameRateRangeMake(120.0f, 120.0f, 120.0f)];
            gInternal = NO;
            [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

            // 鐪嬮棬鐙楋細姣忕閲嶆柊鍘?120 + 琛?hook Unity 绗﹀彿 + 蹇冭烦鏃ュ織
            gWatchdog = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
                P120Watchdog();
            }];
            [[NSRunLoop mainRunLoop] addTimer:gWatchdog forMode:NSRunLoopCommonModes];

            if (gWantHUD) P120ShowHUD();
            NSLog(@"[Pin120] injected into %@ (%@) mode=%ld realMaxFPS=%ld",
                  gBundleID ?: @"no-bundle", gProcName ?: @"?", (long)gMode, (long)gRealMaxFPS);
        });
    }
}

