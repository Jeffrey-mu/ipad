#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

static const CAFrameRateRange kP120Range = {120.0f, 120.0f, 120.0f};
static CADisplayLink *p120Link;

@interface P120Ticker : NSObject
- (void)tick:(CADisplayLink *)link;
@end

@implementation P120Ticker
- (void)tick:(CADisplayLink *)link
{
}
@end

static void P120InstallPin(void)
{
    if (p120Link) {
        return;
    }
    P120Ticker *ticker = [P120Ticker new];
    p120Link = [CADisplayLink displayLinkWithTarget:ticker selector:@selector(tick:)];
    p120Link.preferredFrameRateRange = kP120Range;
    [p120Link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    NSLog(@"[Pin120] 120Hz pin active in %@ (%@)",
          [NSProcessInfo processInfo].processName,
          [NSBundle mainBundle].bundleIdentifier ?: @"no-bundle");
}

%ctor
{
    dispatch_async(dispatch_get_main_queue(), ^{
        P120InstallPin();
    });
}
