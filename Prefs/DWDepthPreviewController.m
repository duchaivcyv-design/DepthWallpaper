#import "DWDepthPreviewController.h"
#import "../Sources/DWDepthEngine.h"
#import "../Sources/DWRenderer.h"

@interface DWDepthPreviewController () <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) DWRenderer *renderer;
@property (nonatomic, strong) UILabel *clockLabel;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UIButton *pickButton;
@end

@implementation DWDepthPreviewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Xem thử chiều sâu";
    self.view.backgroundColor = [UIColor blackColor];

    self.renderer = [[DWRenderer alloc] initWithFrame:CGRectZero];
    self.renderer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.renderer];

    self.clockLabel = [[UILabel alloc] init];
    self.clockLabel.text = @"09:41";
    self.clockLabel.textColor = [UIColor whiteColor];
    self.clockLabel.textAlignment = NSTextAlignmentCenter;
    self.clockLabel.font = [UIFont systemFontOfSize:110 weight:UIFontWeightUltraLight];
    self.clockLabel.adjustsFontSizeToFitWidth = YES;
    self.clockLabel.minimumScaleFactor = 0.3;
    [self.renderer.clockSlot addSubview:self.clockLabel];

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
        [self.renderer.bottomAnchor constraintEqualToAnchor:self.status.topAnchor constant:-10],

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
    CGFloat w = b.size.width;
    self.clockLabel.frame = CGRectMake(0, b.size.height * 0.16, w, 130);
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
    UIImage *image = info[UIImagePickerControllerOriginalImage];
    if (!image) return;

    [self.renderer setBackground:image subject:nil];
    [self.renderer setClockPushedDown:NO];
    self.status.text = @"Đang tách chủ thể...";

    NSData *raw = UIImagePNGRepresentation(image);
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    [[DWDepthEngine shared] subjectMaskForImage:image data:raw completion:^(UIImage *mask) {
        CFAbsoluteTime dt = CFAbsoluteTimeGetCurrent() - t0;
        if (!mask) {
            self.status.text = @"Không tách được chủ thể trong ảnh này.";
            return;
        }
        UIImage *cutout = [DWDepthEngine cutoutFromImage:image mask:mask];
        [self.renderer setBackground:image subject:cutout];
        [self.renderer setClockPushedDown:YES];
        self.status.text = [NSString stringWithFormat:@"Đã tách chủ thể trong %.1f giây. Đồng hồ nằm giữa nền và chủ thể.", dt];
    }];
}

@end
