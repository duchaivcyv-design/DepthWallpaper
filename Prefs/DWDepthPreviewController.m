#import "DWDepthPreviewController.h"
#import "../Sources/DWDepthEngine.h"
#import <PhotosUI/PhotosUI.h>

@interface DWDepthPreviewController () <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) UIImageView *backView;
@property (nonatomic, strong) UIImageView *subjectView;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UIButton *pickButton;
@end

@implementation DWDepthPreviewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Xem thử chiều sâu";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.backView = [[UIImageView alloc] init];
    self.subjectView = [[UIImageView alloc] init];
    for (UIImageView *v in @[self.backView, self.subjectView]) {
        v.contentMode = UIViewContentModeScaleAspectFit;
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:v];
    }
    self.subjectView.hidden = YES;

    self.status = [[UILabel alloc] init];
    self.status.numberOfLines = 0;
    self.status.textAlignment = NSTextAlignmentCenter;
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
        [self.backView.topAnchor constraintEqualToAnchor:g.topAnchor constant:12],
        [self.backView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.backView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.backView.bottomAnchor constraintEqualToAnchor:self.status.topAnchor constant:-12],

        [self.subjectView.topAnchor constraintEqualToAnchor:self.backView.topAnchor],
        [self.subjectView.leadingAnchor constraintEqualToAnchor:self.backView.leadingAnchor],
        [self.subjectView.trailingAnchor constraintEqualToAnchor:self.backView.trailingAnchor],
        [self.subjectView.bottomAnchor constraintEqualToAnchor:self.backView.bottomAnchor],

        [self.status.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.status.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.status.bottomAnchor constraintEqualToAnchor:self.pickButton.topAnchor constant:-12],

        [self.pickButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.pickButton.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-16],
    ]];
}

- (void)pickImage {
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

    self.backView.image = image;
    self.subjectView.hidden = YES;
    self.status.text = @"Đang tách chủ thể...";

    NSData *raw = UIImagePNGRepresentation(image);
    [[DWDepthEngine shared] subjectMaskForImage:image data:raw completion:^(UIImage *mask) {
        if (!mask) {
            self.status.text = @"Không tìm thấy chủ thể trong ảnh này. Ảnh vẫn hiển thị bình thường.";
            return;
        }
        UIImage *cutout = [DWDepthEngine cutoutFromImage:image mask:mask];
        self.subjectView.image = cutout;
        self.subjectView.hidden = (cutout == nil);
        self.status.text = cutout ? @"Đã tách chủ thể. Lớp trên là chủ thể, đồng hồ sẽ nằm giữa."
                                  : @"Tách chủ thể thất bại.";
    }];
}

@end
