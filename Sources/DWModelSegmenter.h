#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
NS_ASSUME_NONNULL_BEGIN
/// Model phân đoạn U²-Net (Core ML) cho chủ thể màn khóa.
/// Sửa v2: gọi thẳng `MLModel predictionFromFeatures:` (bỏ `VNCoreMLRequest`) vì spec
/// khai báo output rank 3 trong khi mạng thực tế trả rank 4 -> Vision từ chối suy luận,
/// model không bao giờ chạy và rơi xuống saliency (vệt xám trên mặt).
@interface DWModelSegmenter : NSObject
/// Trả về mask gray 320x320 (255 = chủ thể) hoặc NULL nếu không có model / lỗi.
/// Caller tự CGImageRelease kết quả; DWDepthEngine phóng to về kích thước ảnh thật.
+ (nullable CGImageRef)maskForCGImage:(CGImageRef)image;
/// YES nếu file model tồn tại và nạp được.
+ (BOOL)isModelAvailable;
/// Trạng thái nạp / suy luận gần nhất, dùng để ghi log.
+ (NSString *)lastStatus;
@end
NS_ASSUME_NONNULL_END
