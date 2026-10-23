#import "ViewController.h"
#import <QuartzCore/QuartzCore.h>
#import <sys/sysctl.h>

#pragma mark - 设备信息

static NSString *P120DeviceIdentifier(void)
{
    size_t size = 0;
    if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) return @"unknown";
    char *buf = malloc(size);
    if (!buf) return @"unknown";
    NSString *result = @"unknown";
    if (sysctlbyname("hw.machine", buf, &size, NULL, 0) == 0) {
        result = [NSString stringWithUTF8String:buf] ?: @"unknown";
    }
    free(buf);
    return result;
}

#pragma mark - 刷新率测量

@interface P120Meter : NSObject
- (void)tick:(CADisplayLink *)link;
@end

@implementation P120Meter
{
    NSTimeInterval _last;
    double _hz;
}
- (void)tick:(CADisplayLink *)link
{
    NSTimeInterval now = link.timestamp;
    if (_last > 0) {
        double dt = now - _last;
        if (dt > 0.0005) {
            double hz = 1.0 / dt;
            _hz = (_hz > 0) ? (_hz * 0.85 + hz * 0.15) : hz;
        }
    }
    _last = now;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refresh];
    });
}
- (void)refresh
{
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc postNotificationName:@"P120MeterUpdate" object:@(self->_hz)];
}
@end

#pragma mark - ViewController

@interface ViewController ()
@property (nonatomic, strong) UILabel *bigLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, strong) P120Meter *meter;
@end

@implementation ViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Pin120 检测";
    title.font = [UIFont systemFontOfSize:32 weight:UIFontWeightBold];
    [self.view addSubview:title];

    self.bigLabel = [[UILabel alloc] init];
    self.bigLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.bigLabel.text = @"-- Hz";
    self.bigLabel.font = [UIFont monospacedDigitSystemFontOfSize:52 weight:UIFontWeightBold];
    self.bigLabel.textColor = [UIColor systemBlueColor];
    [self.view addSubview:self.bigLabel];

    self.detailLabel = [[UILabel alloc] init];
    self.detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailLabel.text = @"测量中…";
    self.detailLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
    self.detailLabel.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:self.detailLabel];

    self.infoLabel = [[UILabel alloc] init];
    self.infoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.infoLabel.numberOfLines = 0;
    self.infoLabel.font = [UIFont systemFontOfSize:14];
    self.infoLabel.textColor = [UIColor labelColor];
    [self.view addSubview:self.infoLabel];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24],

        [self.bigLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.bigLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:18],

        [self.detailLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.detailLabel.topAnchor constraintEqualToAnchor:self.bigLabel.bottomAnchor constant:4],

        [self.infoLabel.leadingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.leadingAnchor constant:16],
        [self.infoLabel.trailingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.trailingAnchor constant:-16],
        [self.infoLabel.topAnchor constraintEqualToAnchor:self.detailLabel.bottomAnchor constant:24],
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(meterUpdate:)
                                                 name:@"P120MeterUpdate"
                                               object:nil];
    [self refreshInfo];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (!self.link) {
        self.meter = [P120Meter new];
        self.link = [CADisplayLink displayLinkWithTarget:self.meter selector:@selector(tick:)];
        // 请求 120：能拿到多少就说明面板真实能力有多少
        self.link.preferredFrameRateRange = CAFrameRateRangeMake(120.0f, 120.0f, 120.0f);
        [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.link invalidate];
    self.link = nil;
}

- (void)meterUpdate:(NSNotification *)note
{
    double hz = [note.object doubleValue];
    self.bigLabel.text = [NSString stringWithFormat:@"%.1f Hz", hz];
    self.detailLabel.text = [NSString stringWithFormat:@"屏幕上报上限 %ld fps",
                             (long)[UIScreen mainScreen].maximumFramesPerSecond];
}

- (void)refreshInfo
{
    NSString *model = P120DeviceIdentifier();
    NSString *os = [[NSProcessInfo processInfo] operatingSystemVersionString];
    NSString *screen = [NSString stringWithFormat:@"%@ x %@",
                        NSStringFromCGSize([UIScreen mainScreen].bounds.size),
                        NSStringFromCGSize([UIScreen mainScreen].nativeBounds.size)];

    self.infoLabel.text =
        [NSString stringWithFormat:
         @"机型 %@\n系统 %@\n屏幕 %@\n\n"
         @"怎么让游戏跑到 120fps\n"
         @"1. 装 Pin120 插件（com.wjf.pin120 2.0），它会注入游戏进程，\n"
         @"   把 UIScreen.maximumFramesPerSecond 伪造成 120、\n"
         @"   并强制 CADisplayLink / Unity targetFrameRate = 120。\n"
         @"2. 进游戏后看左上角 P120 挂件：\n"
         @"   「引擎请求」= 游戏自己想要的帧率，「Unity target」= 引擎上限。\n"
         @"   单击展开，长按收起或屏蔽当前 App。\n"
         @"3. 装完插件后游戏画质设置里通常会多出 120 帧选项。\n\n"
         @"注意：iPad Pro 2018(12.9\"/A12X) 的屏幕物理上只有 60Hz，\n"
         @"插件能做的是让游戏按 120fps 渲染（降低延迟、帧率数字变 120），\n"
         @"屏幕本身仍然只能显示 60 帧。真·120Hz 需要 ProMotion 机型\n"
         @"（iPad Pro 2020 M1 及以后）。",
         model, os, screen];
}

@end
