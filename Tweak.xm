#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "Sources/DWPrefs.h"
#import "Sources/DWDepthEngine.h"
#import "Sources/DWRenderer.h"
#import "Sources/DWClassResolver.h"

// Placeholder để Logos biên dịch. Class thật được gắn lúc chạy qua %init(..., Name = cls).
@interface SBFWallpaperView : UIView @end
@interface SBFLockScreenDateView : UIView @end
@interface NCNotificationCenterViewController : UIViewController @end

static Class gWallpaperCls;
static Class gDateCls;
static Class gNCCls;

static DWRenderer *gRenderer;
static UIView *gDateView;          // đồng hồ đang được đưa vào lớp giữa
static UIView *gDateOriginalSuper; // nơi đồng hồ thuộc về trước khi đổi
static UIImage *gSourceImage;
static BOOL gDepthOn = YES;
static BOOL gBusy = NO;
static BOOL gJitterDisabledByUs = NO;

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

// Trả đồng hồ về chỗ cũ và ẩn lớp chiều sâu.
static void DWTearDownDepth(void) {
    if (gDateView && gDateOriginalSuper && gDateView.superview != gDateOriginalSuper) {
        [gDateOriginalSuper addSubview:gDateView];
    }
    gDateView = nil;
    gDateOriginalSuper = nil;
    if (gRenderer) {
        [gRenderer removeFromSuperview];
        gRenderer = nil;
    }
    gSourceImage = nil;
}

static void DWApplyDepth(UIImage *image, UIView *host) {
    if (!image || !host || gBusy) return;
    if (image == gSourceImage) return;

    NSData *raw = UIImagePNGRepresentation(image);
    if (!raw) return;

    gBusy = YES;
    gSourceImage = image;

    [[DWDepthEngine shared] subjectMaskForImage:image data:raw completion:^(UIImage *mask) {
        gBusy = NO;
        if (!DWPrefBool(@"enabled", YES) || !DWPrefBool(@"depthWallpaper", YES)) {
            DWTearDownDepth();
            return;
        }

        UIImage *cutout = mask ? [DWDepthEngine cutoutFromImage:image mask:mask
                                                             thickness:DWPrefDouble(@"subjectThickness", 0.0)] : nil;

        if (!gRenderer) {
            gRenderer = [[DWRenderer alloc] initWithFrame:host.bounds];
            gRenderer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [host insertSubview:gRenderer atIndex:0];
        }
        [gRenderer setBackground:image subject:cutout];
        [gRenderer setClockPushedDown:gDepthOn];

        if (gDateView && gDateView.superview != gRenderer.clockSlot) {
            if (!gDateOriginalSuper) gDateOriginalSuper = gDateView.superview;
            [gRenderer.clockSlot addSubview:gDateView];
        }
    }];
}

// ---------- Nhóm 1: wallpaper view — tắt rung + lấy ảnh để làm chiều sâu ----------
%group WallpaperHooks

%hook SBFWallpaperView

- (void)layoutSubviews {
    %orig;

    BOOL enabled = DWPrefBool(@"enabled", YES);

    if (enabled && DWPrefBool(@"noJitter", YES)) {
        DWSendDouble(self, @"setZoomFactor:", 1.0);
        DWSendBool(self, @"setParallaxEnabled:", NO);
        gJitterDisabledByUs = YES;
    } else if (gJitterDisabledByUs) {
        DWSendBool(self, @"setParallaxEnabled:", YES);
        gJitterDisabledByUs = NO;
    }

    if (enabled && DWPrefBool(@"depthWallpaper", YES)) {
        DWApplyDepth(DWImageFromWallpaperView(self), (UIView *)self);
    } else if (gRenderer) {
        DWTearDownDepth();
    }
}

%end

%end

// ---------- Nhóm 2: đồng hồ vào lớp giữa ----------
%group DateHooks

%hook SBFLockScreenDateView

- (void)didMoveToSuperview {
    %orig;
    if (!DWPrefBool(@"enabled", YES) || !DWPrefBool(@"depthWallpaper", YES)) return;
    UIView *selfView = (UIView *)self;
    gDateView = selfView;
    if (gRenderer && gRenderer.clockSlot && selfView.superview != gRenderer.clockSlot) {
        if (!gDateOriginalSuper) gDateOriginalSuper = selfView.superview;
        [gRenderer.clockSlot addSubview:selfView];
    }
}

%end

%end

// ---------- Nhóm 3: nhấn giữ trung tâm thông báo để bật/tắt đẩy đồng hồ ----------
%group ToggleHooks

%hook NCNotificationCenterViewController

- (void)viewDidLoad {
    %orig;
    UIViewController *selfVC = (UIViewController *)self;
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(dw_longPress:)];
    lp.minimumPressDuration = 0.6;
    [selfVC.view addGestureRecognizer:lp];
}

%new
- (void)dw_longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (!DWPrefBool(@"enabled", YES) || !DWPrefBool(@"depthToggle", YES)) return;
    gDepthOn = !gDepthOn;
    if (gRenderer) [gRenderer setClockPushedDown:gDepthOn];
}

%end

%end

// ---------- Áp lại cài đặt ngay khi công tắc thay đổi ----------
static void DWReloadFromPrefs(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)DW_PREFS_SUITE);
    if (!DWPrefBool(@"enabled", YES) || !DWPrefBool(@"depthWallpaper", YES)) {
        dispatch_async(dispatch_get_main_queue(), ^{ DWTearDownDepth(); });
    } else {
        gSourceImage = nil; // buộc layoutSubviews áp dụng lại
    }
    gDepthOn = YES;
}

%ctor {
    DWDumpRelevantClassesOnce();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    DWReloadFromPrefs, CFSTR(DW_RELOAD_NOTE), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    gWallpaperCls = DWFindClass(@[@"SBFStaticWallpaperView", @"SBFWallpaperView"],
                                @"WallpaperView", @"wallpaperImage", [UIView class],
                                @"wallpaper");

    gDateCls = DWFindClass(@[@"CSLockScreenDateView", @"SBFLockScreenDateView"],
                           @"LockScreenDateView", @"didMoveToSuperview", [UIView class],
                           @"date");

    gNCCls = DWFindClass(@[@"CSCoverSheetViewController", @"NCNotificationCenterViewController",
                           @"SBNotificationCenterViewController"],
                         @"CoverSheetOrNC", @"viewDidLoad", [UIViewController class],
                         @"notification-center");

    // Luôn gắn hook khi tìm thấy class; mỗi hook tự kiểm tra công tắc lúc chạy.
    if (gWallpaperCls) %init(WallpaperHooks, SBFWallpaperView = gWallpaperCls);
    if (gDateCls)      %init(DateHooks, SBFLockScreenDateView = gDateCls);
    if (gNCCls)        %init(ToggleHooks, NCNotificationCenterViewController = gNCCls);
}
