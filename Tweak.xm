#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "Sources/DWPrefs.h"
#import "Sources/DWDepthEngine.h"
#import "Sources/DWRenderer.h"
#import "Sources/DWClassResolver.h"

// Placeholder để Logos biên dịch. Class thật được gắn lúc chạy qua %init(..., Name = cls).
// Các class này đã xác nhận có trên iOS 16.7.16 (log classes-SpringBoard-16.7.16.txt).
@interface SBFWallpaperView : UIView @end
@interface SBFLockScreenDateView : UIView @end
@interface CSCoverSheetViewController : UIViewController @end

static Class gWallpaperCls;
static Class gDateCls;
static Class gCoverCls;

// Trạng thái màn khóa
static BOOL gDepthOn = YES;
static BOOL gJitterDisabledByUs = NO;

#pragma mark - Log (để đọc lỗi trên máy)

static dispatch_queue_t gLogQueue;

static void DWLockLog(NSString *line) {
    NSLog(@"[DepthWallpaper][lock] %@", line);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLogQueue = dispatch_queue_create("dw.log", DISPATCH_QUEUE_SERIAL);
    });
    NSString *entry = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
    // Ghi file ở luồng nền, không chặn main thread
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

// Chụp nội dung view hiện tại. Trả về nil nếu ảnh gần như đen (chụp không ra nội dung).
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

    // Kiểm tra nhanh: lấy mẫu 16x16, nếu toàn đen thì coi như chụp thất bại
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
    if (sum < 1000) return nil;
    return img;
}

#pragma mark - Màn khóa: chiều sâu thật (cửa sổ chủ thể nằm trên cover sheet)

// Cửa sổ chứa chủ thể: đặt trên cửa sổ cover sheet, nên chủ thể nằm trên đồng hồ và thông báo.
static UIWindow *gSubjectWindow;

static void DWTearDownLock(void) {
    gSubjectWindow.hidden = YES;
    gSubjectWindow = nil;
}

// Tìm wallpaper ở mọi cửa sổ (wallpaper nằm ở cửa sổ riêng, không nằm trong cover sheet)
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

// Cửa sổ cover sheet: cửa sổ chứa đồng hồ, hoặc cửa sổ của cover sheet view controller
static UIWindow *DWCoverWindow(UIViewController *vc) {
    if (vc.view.window) return vc.view.window;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (DWFindSubview(w, gDateCls)) return w;
    }
    return nil;
}

static void DWAttachLockDepth(UIViewController *vc) {
    if (!DWPrefBool(@"enabled", YES) || !DWPrefBool(@"depthWallpaper", YES)) return;
    if (gSubjectWindow) return;

    NSArray<UIWindow *> *all = [UIApplication sharedApplication].windows;
    DWLockLog([NSString stringWithFormat:@"Số cửa sổ hiện tại: %lu", (unsigned long)all.count]);

    UIView *wall = DWFindWallpaperAnyWindow();
    if (!wall) { DWLockLog(@"KHÔNG tìm thấy wallpaper ở bất kỳ cửa sổ nào"); return; }
    DWLockLog([NSString stringWithFormat:@"Tìm thấy wallpaper: %@ bounds=%@",
               NSStringFromClass([wall class]), NSStringFromCGRect(wall.bounds)]);

    UIWindow *coverWin = DWCoverWindow(vc);
    if (!coverWin) { DWLockLog(@"KHÔNG tìm thấy cửa sổ cover sheet"); return; }

    UIImage *snap = DWSnapshotView(wall);
    if (!snap) { DWLockLog(@"Chụp wallpaper thất bại (ảnh đen hoặc nội dung nằm ở process khác)"); return; }
    DWLockLog([NSString stringWithFormat:@"Chụp wallpaper OK: %.0fx%.0f", snap.size.width, snap.size.height]);

    NSData *raw = UIImagePNGRepresentation(snap);
    [[DWDepthEngine shared] subjectMaskForImage:snap data:raw completion:^(UIImage *mask) {
        if (!DWPrefBool(@"enabled", YES) || !DWPrefBool(@"depthWallpaper", YES)) return;
        if (!mask) { DWLockLog(@"Không tách được chủ thể từ wallpaper"); return; }

        double cov = [DWDepthEngine coverageOfMask:mask];
        DWLockLog([NSString stringWithFormat:@"Mask chủ thể chiếm %.1f%%", cov * 100]);
        if (cov < 0.01 || cov > 0.95) { DWLockLog(@"Mask không dùng được, bỏ qua"); return; }

        UIImage *cut = [DWDepthEngine cutoutFromImage:snap mask:mask
                                            thickness:DWPrefDouble(@"subjectThickness", 0.0)];
        if (!cut) { DWLockLog(@"Cắt chủ thể thất bại"); return; }
        if (gSubjectWindow) return;

        UIWindowScene *scene = coverWin.windowScene;
        UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                            : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.frame = coverWin.bounds;
        w.windowLevel = coverWin.windowLevel + 0.5; // trên đồng hồ, dưới các cửa sổ hệ thống cao hơn
        w.backgroundColor = [UIColor clearColor];
        w.userInteractionEnabled = NO;

        UIImageView *iv = [[UIImageView alloc] initWithFrame:w.bounds];
        iv.image = cut;
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [w addSubview:iv];
        w.hidden = NO;

        gSubjectWindow = w;
        DWLockLog(@"Đã đặt chủ thể lên trên đồng hồ (cửa sổ chiều sâu)");
    }];
}

#pragma mark - Hook

// Màn khóa: gắn/gỡ lớp chiều sâu khi cover sheet hiện/ẩn
%group CoverHooks

%hook CSCoverSheetViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIViewController *selfVC = (UIViewController *)self;
    // Chờ animation xong rồi mới chụp
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DWAttachLockDepth(selfVC);
    });
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    DWTearDownLock();
}

// Nhấn giữ màn khóa để bật/tắt đẩy đồng hồ
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
    (void)gDepthOn;
}

%end

%end

// Tắt rung trên wallpaper (không dùng cho depth)
%group JitterHooks

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
}

%end

%end

// Áp lại cài đặt ngay khi công tắc thay đổi
static void DWReloadFromPrefs(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    DWPrefsInvalidate();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!DWPrefBool(@"enabled", YES) || !DWPrefBool(@"depthWallpaper", YES)) {
            DWTearDownLock();
        }
    });
}

%ctor {
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
