#import "DWDepthPreviewController.h"
#import "../Sources/DWDepthEngine.h"
#import "../Sources/DWRenderer.h"
#import "../Sources/DWPrefs.h"

static const CGFloat kDWPreviewMaxSide = 900.0;
static const CGFloat kDWClockHeight = 210.0;
static const CGFloat kDWHandleSize = 30.0;

static UIImage *DWScaledImage(UIImage *img, CGSize size) {
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1.0;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }];
}

@interface DWDepthPreviewController () <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) DWRenderer *renderer;
@property (nonatomic, strong) UIView *clockView;
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UIView *handle;
@property (nonatomic, strong) UISlider *thicknessSlider;
@property (nonatomic, strong) UILabel *thicknessLabel;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UIButton *pickButton;
@property (nonatomic, strong) UIImage *displayImage;
@property (nonatomic, strong) UIImage *displayMask;
@property (nonatomic, assign) BOOL laidOut;
@property (nonatomic, assign) CGFloat handleStartValue;
@end

@implementation DWDepthPreviewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Xem thử chiều sâu";
    self.view.backgroundColor = [UIColor blackColor];

    // Nền + lớp đồng hồ + chủ thể
    self.renderer = [[DWRenderer alloc] initWithFrame:CGRectZero];
    self.renderer.translatesAutoresizingMaskIntoConstraints = NO;
    self.renderer.clockSlot.userInteractionEnabled = YES;
    [self.view addSubview:self.renderer];

    // Đồng hồ kiểu iOS: ngày phía trên, giờ 9:41 phía dưới
    self.clockView = [[UIView alloc] init];
    self.clockView.backgroundColor = [UIColor clearColor];
    [self.renderer.clockSlot addSubview:self.clockView];

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"vi_VN"];
    df.dateFormat = @"EEEE, d 'tháng' M";

    self.dateLabel = [[UILabel alloc] init];
    self.dateLabel.text = [df stringFromDate:[NSDate date]];
    self.dateLabel.textColor = [UIColor whiteColor];
    self.dateLabel.textAlignment = NSTextAlignmentCenter;
    self.dateLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
    self.dateLabel.adjustsFontSizeToFitWidth = YES;
    self.dateLabel.minimumScaleFactor = 0.5;
    [self.clockView addSubview:self.dateLabel];

    self.timeLabel = [[UILabel alloc] init];
    self.timeLabel.text = @"9:41";
    self.timeLabel.textColor = [UIColor whiteColor];
    self.timeLabel.textAlignment = NSTextAlignmentCenter;
    self.timeLabel.font = [UIFont systemFontOfSize:160 weight:UIFontWeightSemibold];
    self.timeLabel.adjustsFontSizeToFitWidth = YES;
    self.timeLabel.minimumScaleFactor = 0.3;
    [self.clockView addSubview:self.timeLabel];

    // Góc kéo lên xuống để chỉnh độ dày chủ thể
    self.handle = [[UIView alloc] init];
    self.handle.backgroundColor = [UIColor whiteColor];
    self.handle.layer.cornerRadius = kDWHandleSize / 2.0;
    self.handle.layer.shadowColor = [UIColor blackColor].CGColor;
    self.handle.layer.shadowOpacity = 0.35;
    self.handle.layer.shadowRadius = 4;
    self.handle.layer.shadowOffset = CGSizeMake(0, 2);
    [self.clockView addSubview:self.handle];
    UIPanGestureRecognizer *handlePan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                                 action:@selector(handlePanned:)];
    [self.handle addGestureRecognizer:handlePan];

    UIPanGestureRecognizer *clockPan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                               action:@selector(clockPanned:)];
    [self.clockView addGestureRecognizer:clockPan];

    // Thanh chỉnh độ dày (-1 mỏng ... +1 dày)
    self.thicknessLabel = [[UILabel alloc] init];
    self.thicknessLabel.textColor = [UIColor whiteColor];
    self.thicknessLabel.font = [UIFont systemFontOfSize:14];
    self.thicknessLabel.textAlignment = NSTextAlignmentCenter;
    self.thicknessLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.thicknessLabel];

    self.thicknessSlider = [[UISlider alloc] init];
    self.thicknessSlider.minimumValue = -1.0;
    self.thicknessSlider.maximumValue = 1.0;
    self.thicknessSlider.value = (float)DWPrefDouble(@"subjectThickness", 0.0);
    [self.thicknessSlider addTarget:self action:@selector(thicknessChanged:)
                   forControlEvents:UIControlEventValueChanged];
    self.thicknessSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.thicknessSlider];
    [self updateThicknessLabel];

    self.status = [[UILabel alloc] init];
    self.status.numberOfLines = 0;
    self.status.textColor = [UIColor whiteColor];
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.font = [UIFont systemFontOfSize:14];
    self.status.text = @"Chọn một ảnh để xem chiều sâu.";
    self.status.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.status];

    self.pickButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.pickButton setTitle:@"Chọn ảnh" forState:UIControlStateNormal];
    self.pickButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [self.pickButton addTarget:self action:@selector(pickImage) forControlEvents:UIControlEventTouchUpInside];
    self.pickButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.pickButton];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.renderer.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [self.renderer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.renderer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.renderer.bottomAnchor constraintEqualToAnchor:self.thicknessLabel.topAnchor constant:-8],

        [self.thicknessLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.thicknessLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.thicknessLabel.bottomAnchor constraintEqualToAnchor:self.thicknessSlider.topAnchor constant:-4],

        [self.thicknessSlider.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [self.thicknessSlider.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
        [self.thicknessSlider.bottomAnchor constraintEqualToAnchor:self.status.topAnchor constant:-8],

        [self.status.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.status.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.status.heightAnchor constraintGreaterThanOrEqualToConstant:36],
        [self.status.bottomAnchor constraintEqualToAnchor:self.pickButton.topAnchor constant:-4],

        [self.pickButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.pickButton.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-4],
        [self.pickButton.heightAnchor constraintEqualToConstant:44],
    ]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.renderer.clockSlot.bounds;
    if (CGRectIsEmpty(b)) return;

    CGFloat cw = b.size.width * 0.9;
    self.clockView.bounds = CGRectMake(0, 0, cw, kDWClockHeight);
    self.dateLabel.frame = CGRectMake(0, 0, cw, 30);
    self.timeLabel.frame = CGRectMake(0, 30, cw, 170);
    self.handle.frame = CGRectMake(cw - kDWHandleSize / 2.0, -kDWHandleSize / 2.0,
                                   kDWHandleSize, kDWHandleSize);

    if (!self.laidOut) {
        self.laidOut = YES;
        double nx = DWPrefDouble(@"clockX", 0.5);
        double ny = DWPrefDouble(@"clockY", 0.2);
        self.clockView.center = CGPointMake(b.size.width * nx, b.size.height * ny);
    }
}

#pragma mark - Đồng hồ: kéo để di chuyển

- (void)clockPanned:(UIPanGestureRecognizer *)g {
    UIView *host = self.renderer.clockSlot;
    CGPoint p = [g translationInView:host];
    CGPoint c = self.clockView.center;
    CGRect b = host.bounds;
    CGFloat hw = self.clockView.bounds.size.width / 2.0;
    CGFloat hh = self.clockView.bounds.size.height / 2.0;

    c.x = MAX(hw, MIN(b.size.width - hw, c.x + p.x));
    c.y = MAX(hh, MIN(b.size.height - hh, c.y + p.y));
    self.clockView.center = c;
    [g setTranslation:CGPointZero inView:host];

    if (g.state == UIGestureRecognizerStateEnded) {
        DWPrefSetDouble(@"clockX", c.x / b.size.width);
        DWPrefSetDouble(@"clockY", c.y / b.size.height);
    }
}

#pragma mark - Góc kéo: lên xuống để chỉnh độ dày

- (void)handlePanned:(UIPanGestureRecognizer *)g {
    UIView *host = self.renderer.clockSlot;
    if (g.state == UIGestureRecognizerStateBegan) {
        self.handleStartValue = self.thicknessSlider.value;
    }
    CGPoint p = [g translationInView:host];
    // Kéo lên 150pt = tăng hết thanh (+1), kéo xuống = giảm
    float value = (float)(self.handleStartValue - p.y / 150.0);
    value = MAX(self.thicknessSlider.minimumValue, MIN(self.thicknessSlider.maximumValue, value));
    self.thicknessSlider.value = value;
    [self thicknessChanged:self.thicknessSlider];

    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        DWPrefSetDouble(@"subjectThickness", self.thicknessSlider.value);
    }
}

- (void)thicknessChanged:(UISlider *)slider {
    [self updateThicknessLabel];
    DWPrefSetDouble(@"subjectThickness", slider.value);
    [self applySubject];
}

- (void)updateThicknessLabel {
    self.thicknessLabel.text = [NSString stringWithFormat:@"Độ dày chủ thể: %+.2f", self.thicknessSlider.value];
}

#pragma mark - Chọn ảnh và tách chủ thể

- (void)applySubject {
    if (!self.displayImage || !self.displayMask) return;
    UIImage *cutout = [DWDepthEngine cutoutFromImage:self.displayImage
                                                mask:self.displayMask
                                           thickness:self.thicknessSlider.value];
    [self.renderer setBackground:self.displayImage subject:cutout];
}

- (void)pickImage {
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) {
        self.status.text = @"Thiết bị không cho phép mở thư viện ảnh.";
        return;
    }
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    UIImage *original = info[UIImagePickerControllerOriginalImage];
    if (!original) return;

    // Ảnh hiển thị và mask đều thu xuống để kéo mượt
    CGFloat s = MIN(1.0, kDWPreviewMaxSide / MAX(original.size.width, original.size.height));
    CGSize small = CGSizeMake(MAX(1, floor(original.size.width * s)), MAX(1, floor(original.size.height * s)));
    self.displayImage = DWScaledImage(original, small);
    self.displayMask = nil;
    [self.renderer setBackground:self.displayImage subject:nil];
    self.status.text = @"Đang tách chủ thể...";

    NSData *raw = UIImagePNGRepresentation(original);
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    [[DWDepthEngine shared] subjectMaskForImage:original data:raw completion:^(UIImage *mask) {
        CFAbsoluteTime dt = CFAbsoluteTimeGetCurrent() - t0;
        if (!mask) {
            self.status.text = @"Không tách được chủ thể trong ảnh này.";
            return;
        }
        self.displayMask = DWScaledImage(mask, small);
        double cov = [DWDepthEngine coverageOfMask:self.displayMask];
        [self applySubject];
        if (cov < 0.01) {
            self.status.text = [NSString stringWithFormat:@"Mask gần như rỗng (%.1f%%), không có chủ thể để tách. Thử ảnh khác có vật nổi rõ.", cov * 100];
        } else if (cov > 0.95) {
            self.status.text = [NSString stringWithFormat:@"Mask phủ gần hết ảnh (%.0f%%), hiệu ứng sẽ yếu. Thử ảnh khác.", cov * 100];
        } else {
            self.status.text = [NSString stringWithFormat:@"Tách xong trong %.1f giây, chủ thể chiếm %.0f%% ảnh. Kéo đồng hồ để di chuyển, kéo góc trắng lên xuống để chỉnh độ dày.", dt, cov * 100];
        }
    }];
}

@end
