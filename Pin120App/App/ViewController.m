#import "ViewController.h"
#import <ReplayKit/ReplayKit.h>

@interface ViewController ()
@property (nonatomic, strong) RPSystemBroadcastPickerView *picker;
@end

@implementation ViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Pin120";
    title.font = [UIFont systemFontOfSize:36 weight:UIFontWeightBold];
    [self.view addSubview:title];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"一键锁定系统 120Hz";
    subtitle.font = [UIFont systemFontOfSize:17];
    subtitle.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:subtitle];

    UILabel *steps = [[UILabel alloc] init];
    steps.translatesAutoresizingMaskIntoConstraints = NO;
    steps.numberOfLines = 0;
    steps.font = [UIFont systemFontOfSize:15];
    steps.text = @"使用方法：\n1. 点下方按钮，弹出「屏幕广播」面板\n2. 选择「Pin120广播」→ 开始广播\n3. 等 3 秒倒数结束，切到游戏即可\n4. 停止：点状态栏红条 → 停止\n\n原理：系统在广播/录屏时会把 ProMotion\n锁定在 120Hz。本工具开启广播后直接丢弃\n所有画面帧，不录制、不占存储，只保留\n锁帧效果——等价于你手动开录屏，但不会\n生成任何视频文件。\n\n注意：\n· 状态栏会出现红色/紫色录制指示（系统强制）\n· 请关闭低电量模式（会强制 60Hz）\n· 广播停止后系统恢复自适应刷新率";
    steps.textColor = [UIColor labelColor];
    [self.view addSubview:steps];

    self.picker = [[RPSystemBroadcastPickerView alloc] initWithFrame:CGRectZero];
    self.picker.preferredExtension = @"com.wjf.pin120app.broadcast";
    self.picker.showsMicrophoneButton = NO;
    [self.view addSubview:self.picker];

    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [title.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:36],
        [subtitle.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],
        [steps.leadingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.leadingAnchor constant:12],
        [steps.trailingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.trailingAnchor constant:-12],
        [steps.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:24],
        [self.picker.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.picker.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-32],
        [self.picker.widthAnchor constraintEqualToConstant:260],
        [self.picker.heightAnchor constraintEqualToConstant:56],
    ]];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    for (UIView *sub in self.picker.subviews) {
        if ([sub isKindOfClass:[UIButton class]]) {
            UIButton *btn = (UIButton *)sub;
            btn.frame = self.picker.bounds;
            btn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            UIButtonConfiguration *cfg = [UIButtonConfiguration filledButtonConfiguration];
            cfg.title = @"开始锁定 120Hz";
            cfg.cornerStyle = UIButtonConfigurationCornerStyleMedium;
            cfg.contentInsets = NSDirectionalEdgeInsetsMake(12, 24, 12, 24);
            btn.configuration = cfg;
            break;
        }
    }
}

@end
