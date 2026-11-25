#import "DWRenderer.h"

@interface DWRenderer ()
@property (nonatomic, strong) UIImageView *backgroundView;
@property (nonatomic, strong) UIImageView *subjectView;
@property (nonatomic, strong, readwrite) UIView *clockSlot;
@end

@implementation DWRenderer

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = YES;
        self.backgroundColor = [UIColor blackColor];
        self.userInteractionEnabled = NO;

        UIViewAutoresizing fill = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _backgroundView = [[UIImageView alloc] initWithFrame:self.bounds];
        _backgroundView.contentMode = UIViewContentModeScaleAspectFill;
        _backgroundView.autoresizingMask = fill;

        _clockSlot = [[UIView alloc] initWithFrame:self.bounds];
        _clockSlot.autoresizingMask = fill;
        _clockSlot.userInteractionEnabled = NO;

        _subjectView = [[UIImageView alloc] initWithFrame:self.bounds];
        _subjectView.contentMode = UIViewContentModeScaleAspectFill;
        _subjectView.autoresizingMask = fill;
        _subjectView.userInteractionEnabled = NO;
        _subjectView.hidden = YES;

        [self addSubview:_backgroundView];
        [self addSubview:_clockSlot];
        [self addSubview:_subjectView];
    }
    return self;
}

- (void)setBackground:(UIImage *)background subject:(UIImage *)subject {
    self.backgroundView.image = background;
    self.subjectView.image = subject;
    self.subjectView.hidden = (subject == nil);
}

- (void)setClockPushedDown:(BOOL)down {
    CGFloat dy = down ? self.bounds.size.height * 0.12 : 0.0;
    [UIView animateWithDuration:0.55
                          delay:0
         usingSpringWithDamping:0.82
          initialSpringVelocity:0.2
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.clockSlot.transform = CGAffineTransformMakeTranslation(0, dy);
    } completion:nil];
}

@end
