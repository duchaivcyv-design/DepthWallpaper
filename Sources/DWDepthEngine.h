#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DWDepthEngine : NSObject

+ (instancetype)shared;

/// Tạo mask chủ thể (trắng = chủ thể). Callback trên main thread, mask có thể là nil.
/// Ảnh được thu nhỏ còn tối đa 1024px để tách nhanh. Có cache PNG theo SHA256 dữ liệu ảnh.
- (void)subjectMaskForImage:(UIImage *)image
                       data:(NSData *)data
                 completion:(void (^)(UIImage * _Nullable mask))completion;

/// Cắt chủ thể ra PNG có alpha bằng mask. Trả về nil nếu thất bại.
+ (nullable UIImage *)cutoutFromImage:(UIImage *)image mask:(UIImage *)mask;

/// Cắt có độ dày chủ thể. thickness trong [-1, 1]: >0 làm dày ra (dilate), <0 làm mỏng lại (erode).
+ (nullable UIImage *)cutoutFromImage:(UIImage *)image
                                 mask:(UIImage *)mask
                            thickness:(double)thickness;

@end

NS_ASSUME_NONNULL_END
