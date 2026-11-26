#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Chạy model Core ML segmentation do người dùng cung cấp tại
/// /Library/Application Support/DepthWallpaper/DWSubject.mlmodelc
/// Model phải có đầu ra là ảnh (pixel buffer), trắng = chủ thể.
@interface DWModelSegmenter : NSObject

/// Trả về CGImage grayscale cùng kích thước ảnh đầu vào, hoặc NULL nếu không có model / lỗi.
/// Caller tự CGImageRelease kết quả.
+ (nullable CGImageRef)maskForCGImage:(CGImageRef)image;

/// YES nếu file model tồn tại và nạp được.
+ (BOOL)isModelAvailable;

@end

NS_ASSUME_NONNULL_END
