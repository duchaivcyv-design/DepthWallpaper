#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "Sources/DWPrefs.h"
#import "Sources/DWDepthEngine.h"
#import "Sources/DWRenderer.h"
#import "Sources/DWClassResolver.h"

// Khai báo placeholder để Logos biên dịch. Class thật được gắn lúc chạy qua %init(..., Name = cls).
@interface SBFWallpaperView : UIView @end
@interface SBFLockScreenDateView : UIView @end
@interface NCNotificationCenterViewController : UIViewController @end

static Class gWallpaperCls;
static Class gDateCls;
static Class gNCCls;

static DWRenderer *gRenderer;
static UIImage *gSourceImage;   // ảnh gốc đang dùng
static UIImage *gCutout;        // chủ thể đã cắt
static BOOL gDepthOn = YES;
static BOOL gBusy = NO;

// ---------- Gọi selector an toàn (không crash nếu không tồn tại) ----------
static void DWSendDouble(id obj, NSString *selName, double v) {
    SEL sel = NSSelectorFromString(selName);
    if ([obj respondsToSelector:sel]) ((void (*)(id, SEL, double))objc_msgSend)(obj, sel, v);
}

static void DWSendBool(id obj, NSString *selName, BOOL v) {
    SEL sel = NSSelectorFromString(selName);
    if ([obj respondsToSelector:sel]) ((void (*)(id, SEL, BOOL))objc_msgSend)(obj, sel, v);
}

static UIImage *DWImageFromWallpaperView(id view) {
    SEL sel = NSSelectorFromString(@"wallpaperImage");
    if (![view respondsToSelector:sel]) return nil;
    return ((UIImage *(*)(id, SEL))objc_msgSend)(view, sel);
}

// ---------- Áp dụng chiều sâu cho một ảnh ----------
static void DWApplyDepth(UIImage *image, UIView *host) {
    if (!image || !host || gBusy) return;
    if (image == gSourceImage) return;

    NSData *raw = UIImagePNGRepresentation(image);
    if (!raw) return;

    gBusy = YES;
    gSourceImage = image;

    [[DWDepthEngine shared] subjectMaskForImage:image data:raw completion:^(UIImage *mask) {
        gBusy = NO;
        if (!DWPrefBool(@"depthWallpaper", YES)) return;

        gCutout = mask ? [DWDepthEngine cutoutFromImage:image mask:mask] : nil;

        if (!gRenderer) {
            gRenderer = [[DWRenderer alloc] initWithFrame:host.bounds];
            gRenderer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [host insertSubview:gRenderer atIndex:0];
        }
        [gRenderer setBackground:image subject:gCutout];
        [gRenderer setClockPushedDown:gDepthOn];
    }];
}

// ---------- Nhóm 1: wallpaper view — tắt rung + lấy ảnh để làm chiều sâu ----------
%group WallpaperHooks

%hook SBFWallpaperView

- (void)layoutSubviews {
    %orig;

    if (DWPrefBool(@"noJitter", YES)) {
        DWSendDouble(self, @"setZoomFactor:", 1.0);
        DWSendBool(self, @"setParallaxEnabled:", NO);
    }

    if (DWPrefBool(@"depthWallpaper", YES)) {
        DWApplyDepth(DWImageFromWallpaperView(self), self);
    }
}

%end

%end

// ---------- Nhóm 2: đưa đồng hồ vào lớp giữa ----------
%group DateHooks

%hook SBFLockScreenDateView

- (void)didMoveToSuperview {
    %orig;
    if (!DWPrefBool(@"depthWallpaper", YES)) return;
    if (gRenderer && self.superview != gRenderer.clockSlot) {
        [gRenderer.clockSlot addSubview:self];
    }
}

%end

%end

// ---------- Nhóm 3: nhấn giữ trung tâm thông báo để bật/tắt chiều sâu ----------
%group ToggleHooks

%hook NCNotificationCenterViewController

- (void)viewDidLoad {
    %orig;
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(dw_longPress:)];
    lp.minimumPressDuration = 0.6;
    [self.view addGestureRecognizer:lp];
}

%new
- (void)dw_longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    gDepthOn = !gDepthOn;
    if (gRenderer) [gRenderer setClockPushedDown:gDepthOn];
}

%end

%end

%ctor {
    if (!DWPrefBool(@"enabled", YES)) return;

    DWDumpRelevantClassesOnce();

    gWallpaperCls = DWFindClass(@[@"SBFWallpaperView", @"SBFStaticWallpaperView"],
                                @"WallpaperView", @"setZoomFactor:", [UIView class],
                                @"wallpaper");

    gDateCls = DWFindClass(@[@"SBFLockScreenDateView"],
                           @"LockScreenDateView", @"setDate:", [UIView class],
                           @"date");

    gNCCls = DWFindClass(@[@"NCNotificationCenterViewController"],
                         @"NotificationCenter", @"viewDidLoad", [UIViewController class],
                         @"notification-center");

    if (gWallpaperCls) %init(WallpaperHooks, SBFWallpaperView = gWallpaperCls);
    if (gDateCls && DWPrefBool(@"depthWallpaper", YES)) %init(DateHooks, SBFLockScreenDateView = gDateCls);
    if (gNCCls && DWPrefBool(@"depthToggle", YES)) %init(ToggleHooks, NCNotificationCenterViewController = gNCCls);
}
