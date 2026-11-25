#import <UIKit/UIKit.h>

/// Ba lớp: nền (dưới) -> vùng đồng hồ (giữa) -> chủ thể cắt sẵn (trên cùng).
@interface DWRenderer : UIView

@property (nonatomic, strong, readonly) UIView *clockSlot;

- (void)setBackground:(UIImage *)background subject:(UIImage *)subject;
- (void)setClockPushedDown:(BOOL)down;

@end
