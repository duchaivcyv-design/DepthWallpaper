#import <UIKit/UIKit.h>

@interface DWDepthEngine : NSObject

+ (instancetype)shared;

/// Tạo mask chủ thể (trắng = chủ thể). Callback trên main thread.
/// Ảnh được thu nhỏ còn tối đa 1024px để tách nhanh. Có cache PNG theo SHA256 dữ liệu ảnh.
- (void)subjectMaskForImage:(UIImage *)image
                       data:(NSData *)data
                 completion:(void (^)(UIImage * _Nullable mask))completion;

/// Cắt chủ thể ra PNG có alpha bằng mask.
+ (UIImage * _Nullable)cutoutFromImage:(UIImage *)image mask:(UIImage *)mask;

@end
