#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Chạy model Core ML segmentation DWSubject.mlmodel. Đường dẫn được dò động:
/// cùng cây với dylib (<root>/Library/Application Support/DepthWallpaper),
/// /var/jb/Library/Application Support/DepthWallpaper, hoặc /Library/... (rootful).
/// Model phải trả về ảnh (pixel buffer) hoặc MLMultiArray xác suất [1,H,W], trắng = chủ thể.
@interface DWModelSegmenter : NSObject

/// Trả về CGImage grayscale cùng kích thước ảnh đầu vào, hoặc NULL nếu không có model / lỗi.
/// Caller tự CGImageRelease kết quả.
+ (nullable CGImageRef)maskForCGImage:(CGImageRef)image;

/// YES nếu file model tồn tại và nạp được.
+ (BOOL)isModelAvailable;

/// Trạng thái nạp model gần nhất, dùng để ghi log.
+ (NSString *)lastStatus;

@end

NS_ASSUME_NONNULL_END
