#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DWDepthEngine : NSObject

+ (instancetype)shared;

/// Tạo mask chủ thể (trắng = chủ thể). Callback trên main thread.
/// Có cache PNG theo SHA256 của dữ liệu ảnh trong Library/Caches/DepthWallpaper.
- (void)subjectMaskForImage:(UIImage *)image
                       data:(NSData *)data
                 completion:(void (^)(UIImage * _Nullable mask))completion;

/// Cắt chủ thể ra PNG có alpha bằng mask.
+ (UIImage * _Nullable)cutoutFromImage:(UIImage *)image mask:(UIImage *)mask;

@end

NS_ASSUME_NONNULL_END
