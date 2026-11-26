#import "DWModelSegmenter.h"
#import <Vision/Vision.h>
#import <CoreML/CoreML.h>

static NSString *const kDWModelPath = @"/Library/Application Support/DepthWallpaper/DWSubject.mlmodelc";

@implementation DWModelSegmenter

+ (nullable VNCoreMLModel *)loadedModel {
    static VNCoreMLModel *model;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [NSURL fileURLWithPath:kDWModelPath];
        if (![[NSFileManager defaultManager] fileExistsAtPath:kDWModelPath]) return;
        NSError *err = nil;
        MLModel *ml = [MLModel modelWithContentsOfURL:url error:&err];
        if (!ml) return;
        model = [VNCoreMLModel modelForMLModel:ml error:&err];
    });
    return model;
}

+ (BOOL)isModelAvailable {
    return [self loadedModel] != nil;
}

+ (nullable CGImageRef)maskForCGImage:(CGImageRef)image {
    VNCoreMLModel *model = [self loadedModel];
    if (!model || !image) return NULL;

    VNCoreMLRequest *req = [[VNCoreMLRequest alloc] initWithModel:model];
    req.imageCropAndScaleOption = VNImageCropAndScaleOptionScaleFill;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    if (![handler performRequests:@[req] error:nil]) return NULL;

    VNPixelBufferObservation *obs = nil;
    for (id r in req.results) {
        if ([r isKindOfClass:[VNPixelBufferObservation class]]) { obs = r; break; }
    }
    if (!obs) return NULL;

    CIImage *ci = [CIImage imageWithCVPixelBuffer:obs.pixelBuffer];
    // Đưa mask về đúng kích thước ảnh đầu vào
    size_t W = CGImageGetWidth(image), H = CGImageGetHeight(image);
    CGFloat sx = (CGFloat)W / ci.extent.size.width;
    CGFloat sy = (CGFloat)H / ci.extent.size.height;
    ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
    return [[CIContext contextWithOptions:nil] createCGImage:ci fromRect:CGRectMake(0, 0, W, H)];
}

@end
