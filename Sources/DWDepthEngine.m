#import "DWDepthEngine.h"
#import <Vision/Vision.h>
#import <CommonCrypto/CommonDigest.h>

@implementation DWDepthEngine

+ (instancetype)shared {
    static DWDepthEngine *engine;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ engine = [DWDepthEngine new]; });
    return engine;
}

- (NSURL *)cacheDirectory {
    NSURL *caches = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                             inDomains:NSUserDomainMask] firstObject];
    NSURL *dir = [caches URLByAppendingPathComponent:@"DepthWallpaper" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir
                             withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSString *)keyForData:(NSData *)data {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *s = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [s appendFormat:@"%02x", digest[i]];
    }
    return s;
}

- (void)subjectMaskForImage:(UIImage *)image
                       data:(NSData *)data
                 completion:(void (^)(UIImage *))completion {
    NSURL *file = [[self cacheDirectory] URLByAppendingPathComponent:
                   [[self keyForData:data] stringByAppendingString:@".png"]];

    UIImage *cached = [UIImage imageWithContentsOfFile:file.path];
    if (cached) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
        return;
    }

    CGImageRef cg = image.CGImage;
    if (!cg) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
        CVPixelBufferRef maskBuffer = NULL;
        BOOL owned = NO;
        BOOL handled = NO;

#if defined(__IPHONE_17_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_17_0
        if (@available(iOS 17.0, *)) {
            VNGenerateForegroundInstanceMaskRequest *req = [VNGenerateForegroundInstanceMaskRequest new];
            NSError *err = nil;
            if ([handler performRequests:@[req] error:&err]) {
                VNInstanceMaskObservation *obs = req.results.firstObject;
                if (obs) {
                    maskBuffer = [obs generateScaledMaskForImageForInstances:obs.allInstances
                                                          fromRequestHandler:handler
                                                                       error:&err];
                    owned = (maskBuffer != NULL);
                }
            }
            handled = YES;
        }
#endif

        if (!handled) {
            VNGeneratePersonSegmentationRequest *req = [VNGeneratePersonSegmentationRequest new];
            req.qualityLevel = VNGeneratePersonSegmentationRequestQualityLevelAccurate;
            NSError *err = nil;
            if ([handler performRequests:@[req] error:&err]) {
                VNPixelBufferObservation *obs = req.results.firstObject;
                maskBuffer = obs.pixelBuffer; // không sở hữu
            }
        }

        UIImage *result = nil;
        if (maskBuffer) {
            CIImage *ci = [CIImage imageWithCVPixelBuffer:maskBuffer];
            CGFloat sx = (CGFloat)CGImageGetWidth(cg) / ci.extent.size.width;
            CGFloat sy = (CGFloat)CGImageGetHeight(cg) / ci.extent.size.height;
            ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];

            CIContext *ctx = [CIContext contextWithOptions:nil];
            CGImageRef out = [ctx createCGImage:ci fromRect:ci.extent];
            if (out) {
                result = [UIImage imageWithCGImage:out];
                CGImageRelease(out);
                NSData *png = UIImagePNGRepresentation(result);
                [png writeToURL:file atomically:YES];
            }
            if (owned) CVPixelBufferRelease(maskBuffer);
        }

        dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
    });
}

+ (UIImage *)cutoutFromImage:(UIImage *)image mask:(UIImage *)mask {
    if (!image.CGImage || !mask.CGImage) return nil;

    CIImage *src = [CIImage imageWithCGImage:image.CGImage];
    CIImage *m = [[CIImage imageWithCGImage:mask.CGImage] imageByApplyingFilter:@"CIMaskToAlpha"];

    CIFilter *blend = [CIFilter filterWithName:@"CIBlendWithMask"];
    [blend setValue:src forKey:kCIInputImageKey];
    [blend setValue:[CIImage emptyImage] forKey:kCIInputBackgroundImageKey];
    [blend setValue:m forKey:kCIInputMaskImageKey];

    CIContext *ctx = [CIContext contextWithOptions:nil];
    CGImageRef out = [ctx createCGImage:blend.outputImage fromRect:src.extent];
    if (!out) return nil;
    UIImage *img = [UIImage imageWithCGImage:out scale:image.scale orientation:UIImageOrientationUp];
    CGImageRelease(out);
    return img;
}

@end
