#import <UIKit/UIKit.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/message.h>
#import "Sources/DWPrefs.h"
#import "Sources/DWDepthEngine.h"
#import "Sources/DWRenderer.h"
#import "Sources/DWClassResolver.h"
#import "Sources/DWModelSegmenter.h"
// Placeholder để Logos biên dịch. Class thật được gắn lúc chạy qua %init(..., Name = cls).
// Đã xác nhận có trên iOS 16.7.16 (resolved-SpringBoard.txt):
//   SBFWallpaperView / SBFLockScreenDateView / CSCoverSheetViewController.
@interface SBFWallpaperView : UIView @end
@interface SBFLockScreenDateView : UIView @end
@interface CSCoverSheetViewController : UIViewController @end
static Class gWallpaperCls;
static Class gDateCls;
static Class gCoverCls;

// CHỈ hỗ trợ iOS 16.0 - 18.0; ngoài khoảng này không gắn hook, không làm gì.
static BOOL DWSystemSupported(void) {
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    return (v.majorVersion >= 16 && v.majorVersion <= 18);
}

#pragma mark - Log (để đọc lỗi trên máy)
static dispatch_queue_t gLogQueue;
static void DWLockLog(NSString *line) {
    NSLog(@"[DepthWallpaper][lock] %@", line);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLogQueue = dispatch_queue_create("dw.log", DISPATCH_QUEUE_SERIAL);
    });
    NSString *entry = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
    dispatch_async(gLogQueue, ^{
        NSString *dir = @"/var/mobile/Library/Logs/DepthWallpaper";
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                                   attributes:nil error:nil];
        NSString *path = [dir stringByAppendingPathComponent:@"lock.txt"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [entry writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        [fh seekToEndOfFile];
        [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    });
}

#pragma mark - Tiện ích view
static void DWSendDouble(id obj, NSString *selName, double v) {
    SEL sel = NSSelectorFromString(selName);
    if ([obj respondsToSelector:sel]) ((void (*)(id, SEL, double))objc_msgSend)(obj, sel, v);
}
static void DWSendBool(id obj, NSString *selName, BOOL v) {
    SEL sel = NSSelectorFromString(selName);
    if ([obj respondsToSelector:sel]) ((void (*)(id, SEL, BOOL))objc_msgSend)(obj, sel, v);
}
static UIView *DWFindSubview(UIView *root, Class cls) {
    if (!cls || !root) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIView *v in root.subviews) {
        UIView *found = DWFindSubview(v, cls);
        if (found) return found;
    }
    return nil;
}

// Chụp wallpaper. Trả về nil nếu ảnh gần như đen (nội dung ở process PosterBoard/remote).
static UIImage *DWSnapshotView(UIView *v) {
    CGSize sz = v.bounds.size;
    if (sz.width < 1 || sz.height < 1) return nil;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = YES;
    fmt.scale = [UIScreen mainScreen].scale;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [v drawViewHierarchyInRect:v.bounds afterScreenUpdates:YES];
    }];
    if (!img.CGImage) return nil;
    uint8_t px[16 * 16 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, 16, 16, 8, 16 * 4, cs,
                                             kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGContextDrawImage(ctx, CGRectMake(0, 0, 16, 16), img.CGImage);
    CGContextRelease(ctx);
    long sum = 0;
    for (int i = 0; i < 16 * 16 * 4; i += 4) sum += px[i] + px[i + 1] + px[i + 2];
    if (sum < 20000) return nil;
    return img;
}

#pragma mark - Trạng thái cửa sổ chủ thể (V2: giữ ảnh giữa các lần hiện, bay bằng spring + parallax)
static UIWindow    *gSubjectWindow;
static UIView      *gSubjectContainer;   // nhận chuyển động parallax, không đè lên transform bay
static UIImageView *gSubjectView;
static UIImage     *gCutoutImage;        // giữ lại để hiện lại tức thì, không tái tính
static UIWindow    *gCoverWindow;
static BOOL         gSubjectVisible = NO;
static CMMotionManager *gMotion;
static NSOperationQueue *gMotionQueue;

static void DWStartMotion(void) {
    if (!DWPrefBool(@"parallax", YES)) return;
    if (!gMotion) {
        gMotion = [CMMotionManager new];
        gMotionQueue = [[NSOperationQueue alloc] init];
        gMotionQueue.maxConcurrentOperationCount = 1;
    }
    if (gMotion.isAccelerometerActive) return;
    gMotion.accelerometerUpdateInterval = 1.0 / 30.0;
    [gMotion startAccelerometerUpdatesToQueue:gMotionQueue withHandler:^(CMAccelerometerData *d, NSError *e) {
        CGFloat tx = -d.acceleration.x * 7.0;
        CGFloat ty = -d.acceleration.y * 5.0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gSubjectContainer && gSubjectVisible) {
                gSubjectContainer.transform = CGAffineTransformMakeTranslation(tx, ty);
            }
        });
    }];
}
static void DWStopMotion(void) {
    if (gMotion) [gMotion stopAccelerometerUpdates];
}

static void DWBuildSubjectWindow(UIWindow *coverWin) {
    if (gSubjectWindow) { gCoverWindow = coverWin; return; }
    if (!coverWin) return;
    UIWindowScene *scene = coverWin.windowScene;
    UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                        : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.frame = coverWin.bounds;
    w.windowLevel = coverWin.windowLevel + 0.5; // trên đồng hồ, dưới cửa sổ hệ thống cao hơn
    w.backgroundColor = [UIColor clearColor];
    w.userInteractionEnabled = NO;
    UIView *container = [[UIView alloc] initWithFrame:w.bounds];
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    container.userInteractionEnabled = NO;
    UIImageView *iv = [[UIImageView alloc] initWithFrame:container.bounds];
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    iv.userInteractionEnabled = NO;
    [container addSubview:iv];
    [w addSubview:container];
    w.hidden = YES;
    gSubjectWindow = w;
    gSubjectContainer = container;
    gSubjectView = iv;
    gCoverWindow = coverWin;
}

// Hiệu ứng "flying": chủ thể bay từ dưới lên + xoáy lento (spring), kiểu lớp nổi iOS 26.
static void DWShowSubject(void) {
    if (!gSubjectWindow || !gCutoutImage) return;
    gSubjectView.image = gCutoutImage;
    gSubjectWindow.hidden = NO;
    gSubjectVisible = YES;
    gSubjectView.alpha = 0.0;
    gSubjectView.transform = CGAffineTransformMakeTranslation(0, 38.0);
    [UIView animateWithDuration:0.55
                          delay:0.05
         usingSpringWithDamping:0.82
          initialSpringVelocity:0.25
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        gSubjectView.transform = CGAffineTransformIdentity;
        gSubjectView.alpha = 1.0;
    } completion:nil];
    DWStartMotion();
}

// Ẩn mềm khi cover sheet thoát (vd vuốt đóng Notification Center); KHÔNG xoá ảnh/cửa sổ.
static void DWHideSubject(void) {
    DWStopMotion();
    gSubjectVisible = NO;
    if (!gSubjectWindow) return;
    [UIView animateWithDuration:0.18
                          delay:0.0
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{ gSubjectView.alpha = 0.0; }
                     completion:^(BOOL finished) { gSubjectWindow.hidden = YES; }];
}

// Xoá hẳn: tắt pref / cảnh báo bộ nhớ (chống jetsam kill SpringBoard).
static void DWFullTeardown(void) {
    DWStopMotion();
    gSubjectWindow.hidden = YES;
    gSubjectWindow = nil;
    gSubjectContainer = nil;
    gSubjectView = nil;
    gCutoutImage = nil;
    gSubjectVisible = NO;
}

// Tìm wallpaper ở mọi cửa sổ (wallpaper ở cửa sổ riêng, không nằm trong cover sheet)
static UIView *DWFindWallpaperAnyWindow(void) {
    NSMutableArray<Class> *classes = [NSMutableArray array];
    if (gWallpaperCls) [classes addObject:gWallpaperCls];
    for (NSString *n in @[@"PBUIStaticWallpaperView", @"PBUIWallpaperView",
                          @"PBUIScrollableStaticWallpaperView"]) {
        Class c = NSClassFromString(n);
        if (c) [classes addObject:c];
    }
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        for (Class c in classes) {
            UIView *v = DWFindSubview(w, c);
            if (v) return v;
        }
    }
    return nil;
}

static UIWindow *DWCoverWindow(UIViewController *vc) {
    if (vc && vc.view.window) return vc.view.window;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (DWFindSubview(w, gDateCls)) return w;
    }
    return nil;
}

static void DWAttachLockDepth(UIViewController *vc) {
    if (!DWSystemSupported()) return;
    if (!DWPrefBool(@"enabled", YES) || !DWPrefBool(@"depthWallpaper", YES)) return;
    if (gSubjectVisible) return;
    // Đã có ảnh chủ thể: dựng lại cửa sổ và bay lên ngay, không tái tính mask/CI (hết đơ).
    if (gCutoutImage) {
        DWBuildSubjectWindow(DWCoverWindow(vc));
        DWShowSubject();
        return;
    }
    UIView *wall = DWFindWallpaperAnyWindow();
    if (!wall) { DWLockLog(@"KHÔNG tìm thấy wallpaper ở bất kỳ cửa sổ nào"); return; }
    UIWindow *coverWin = DWCoverWindow(vc);
    if (!coverWin) { DWLockLog(@"KHÔNG tìm thấy cửa sổ cover sheet"); return; }
    DWLockLog([NSString stringWithFormat:@"Tìm thấy wallpaper: %@ | cover: %@ level=%.2f",
               NSStringFromClass([wall class]), NSStringFromClass([coverWin class]),
               coverWin.windowLevel]);
    UIImage *snap = DWSnapshotView(wall);
    if (!snap) { DWLockLog(@"Chụp wallpaper thất bại (ảnh đen hoặc nội dung ở process khác)"); return; }
    DWLockLog([NSString stringWithFormat:@"Chụp OK %.0fx%.0f; tách chủ thể ở luồng nền",
               snap.size.width, snap.size.height]);
    NSData *raw = UIImagePNGRepresentation(snap);
    double thickness = DWPrefDouble(@"subjectThickness", 0.0);
    __block UIImage *snapKeep = snap;
    [[DWDepthEngine shared] subjectCutoutForImage:snap data:raw thickness:thickness
                                       completion:^(UIImage *cut) {
        snapKeep = nil;
        if (!DWPrefBool(@"enabled", YES) || !DWPrefBool(@"depthWallpaper", YES)) return;
        if (!cut) {
            DWLockLog([NSString stringWithFormat:@"Không tách được chủ thể (mask: %@ | model: %@)",
                       [DWDepthEngine lastMaskSource], [DWModelSegmenter lastStatus]]);
            return;
        }
        gCutoutImage = cut;
        DWBuildSubjectWindow(coverWin);
        DWShowSubject();
        DWLockLog([NSString stringWithFormat:@"Đặt chủ thể OK (mask: %@ | model: %@)",
                   [DWDepthEngine lastMaskSource], [DWModelSegmenter lastStatus]]);
    }];
}

#pragma mark - Hook
%group CoverHooks
%hook CSCoverSheetViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIViewController *selfVC = (UIViewController *)self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DWAttachLockDepth(selfVC);
    });
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    // Chỉ ẩn mềm; giữ ảnh để lần xuất hiện sau bay lại ngay (không tính lại, không đơ).
    DWHideSubject();
}
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
    if (gSubjectVisible) { DWHideSubject(); } else { DWShowSubject(); }
}
%end
%end

// Tắt rung/parallax nền khi pref bật; chỉ ghi khi trạng thái đổi, không spam mỗi layoutSubviews.
%group JitterHooks
%hook SBFWallpaperView
static BOOL gDWJitterApplied = NO;
- (void)layoutSubviews {
    %orig;
    BOOL want = DWPrefBool(@"enabled", YES) && DWPrefBool(@"noJitter", YES);
    if (want != gDWJitterApplied) {
        gDWJitterApplied = want;
        if (want) {
            DWSendDouble(self, @"setZoomFactor:", 1.0);
            DWSendBool(self, @"setParallaxEnabled:", NO);
        } else {
            DWSendBool(self, @"setParallaxEnabled:", YES);
        }
    }
}
%end
%end

static void DWInstallObservers(void) {
    [[NSNotificationCenter defaultCenter]
     addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                 object:nil queue:nil
             usingBlock:^(NSNotification * _Nonnull note) {
        DWLockLog(@"Cảnh báo bộ nhớ: giải phóng ảnh chủ thể, tránh jetsam");
        DWFullTeardown();
    }];
}

// Áp lại cài đặt ngay khi công tắc thay đổi
static void DWReloadFromPrefs(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    DWPrefsInvalidate();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!DWPrefBool(@"enabled", YES) || !DWPrefBool(@"depthWallpaper", YES)) {
            DWFullTeardown();
        } else {
            DWAttachLockDepth(nil);
        }
    });
}

%ctor {
    if (!DWSystemSupported()) return;
    dispatch_async(dispatch_get_main_queue(), ^{ DWInstallObservers(); });
    DWDumpRelevantClassesOnce();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    DWReloadFromPrefs, CFSTR(DW_RELOAD_NOTE), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    gWallpaperCls = DWFindClass(@[@"SBFWallpaperView", @"SBFStaticWallpaperView"],
                                @"WallpaperView", @"setZoomFactor:", [UIView class], @"wallpaper");
    gDateCls = DWFindClass(@[@"SBFLockScreenDateView"],
                           @"LockScreenDateView", nil, [UIView class], @"date");
    gCoverCls = DWFindClass(@[@"CSCoverSheetViewController"],
                            @"CoverSheetViewController", @"viewDidAppear:", [UIViewController class],
                            @"cover-sheet");
    if (gWallpaperCls && DWPrefBool(@"noJitter", YES)) %init(JitterHooks, SBFWallpaperView = gWallpaperCls);
    if (gCoverCls) %init(CoverHooks, CSCoverSheetViewController = gCoverCls);
}
