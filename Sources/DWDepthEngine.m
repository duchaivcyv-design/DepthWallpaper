#import "DWDepthEngine.h"
#import <Vision/Vision.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>

static const CGFloat kDWMaxSide = 1024.0;
// Tăng số này mỗi khi đổi thuật toán mask, để bỏ cache mask cũ.
static NSString *const kDWAlgoVersion = @"v8";

@implementation DWDepthEngine

+ (instancetype)shared {
    static DWDepthEngine *engine;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ engine = [DWDepthEngine new]; });
    return engine;
}

+ (NSURL *)cacheDirectory {
    NSURL *caches = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                             inDomains:NSUserDomainMask] firstObject];
    NSURL *dir = [caches URLByAppendingPathComponent:@"DepthWallpaper" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir
                             withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

+ (NSString *)keyForData:(NSData *)data {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *s = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [s appendFormat:@"%02x", digest[i]];
    }
    return s;
}

#pragma mark - Các bước tách mask (trả về CGImage grayscale, trắng = chủ thể; caller tự release)

// iOS 17+: tách mọi vật thể nổi bật. Dùng runtime lookup vì SDK 16.5 chưa khai báo class này.
+ (CGImageRef)maskWithInstanceMask:(CGImageRef)cg {
    Class reqCls = NSClassFromString(@"VNGenerateForegroundInstanceMaskRequest");
    if (!reqCls) return NULL;

    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
    id req = [[reqCls alloc] init];
    if (![handler performRequests:@[req] error:nil]) return NULL;

    NSArray *results = [req valueForKey:@"results"];
    id obs = results.firstObject;
    if (!obs) return NULL;

    SEL genSel = NSSelectorFromString(@"generateScaledMaskForImageForInstances:fromRequestHandler:error:");
    if (![obs respondsToSelector:genSel]) return NULL;
    NSIndexSet *allInstances = [obs valueForKey:@"allInstances"];
    if (!allInstances) return NULL;

    NSError *err = nil;
    CVPixelBufferRef pb = ((CVPixelBufferRef (*)(id, SEL, NSIndexSet *, id, NSError **))objc_msgSend)(
        obs, genSel, allInstances, handler, &err);
    if (!pb) return NULL;

    CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
    CGImageRef out = [[CIContext contextWithOptions:nil] createCGImage:ci fromRect:ci.extent];
    CVPixelBufferRelease(pb);
    return out;
}

// iOS 15+: người
+ (CGImageRef)maskWithPersonSegmentation:(CGImageRef)cg {
    if (@available(iOS 15.0, *)) {
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
        VNGeneratePersonSegmentationRequest *req = [VNGeneratePersonSegmentationRequest new];
        req.qualityLevel = VNGeneratePersonSegmentationRequestQualityLevelBalanced;
        if (![handler performRequests:@[req] error:nil]) return NULL;
        CVPixelBufferRef pb = req.results.firstObject.pixelBuffer;
        if (!pb) return NULL;
        CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
        return [[CIContext contextWithOptions:nil] createCGImage:ci fromRect:ci.extent];
    }
    return NULL;
}

// iOS 13+: vùng nổi bật theo saliency, dùng cho ảnh không có người
+ (CGImageRef)maskWithSaliency:(CGImageRef)cg {
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
    VNGenerateAttentionBasedSaliencyImageRequest *req = [VNGenerateAttentionBasedSaliencyImageRequest new];
    if (![handler performRequests:@[req] error:nil]) return NULL;
    CVPixelBufferRef pb = req.results.firstObject.pixelBuffer;
    if (!pb) return NULL;

    CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
    CIContext *ctx = [CIContext contextWithOptions:nil];

    // Lấy giá trị lớn nhất của heatmap
    CIFilter *maxF = [CIFilter filterWithName:@"CIAreaMaximum"];
    [maxF setValue:ci forKey:kCIInputImageKey];
    [maxF setValue:[CIVector vectorWithCGRect:ci.extent] forKey:kCIInputExtentKey];
    CIImage *maxImg = maxF.outputImage;
    if (!maxImg) return NULL;
    uint8_t px[4] = {0, 0, 0, 0};
    [ctx render:maxImg toBitmap:px rowBytes:4 bounds:CGRectMake(0, 0, 1, 1)
         format:kCIFormatRGBA8 colorSpace:nil];
    double peak = MAX(1.0, (double)MAX(px[0], MAX(px[1], px[2])));

    // Chuẩn hoá về [0,1] theo peak, rồi ngưỡng 50% (contrast mạnh quanh 0.5)
    CGFloat k = (CGFloat)(255.0 / peak);
    CIFilter *norm = [CIFilter filterWithName:@"CIColorMatrix"];
    [norm setValue:ci forKey:kCIInputImageKey];
    [norm setValue:[CIVector vectorWithX:k Y:0 Z:0 W:0] forKey:@"inputRVector"];
    [norm setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:0] forKey:@"inputGVector"];
    [norm setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:0] forKey:@"inputBVector"];
    [norm setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:1] forKey:@"inputAVector"];
    [norm setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:0] forKey:@"inputBiasVector"];
    CIImage *scaled = norm.outputImage ?: ci;

    CIFilter *thr = [CIFilter filterWithName:@"CIColorControls"];
    [thr setValue:scaled forKey:kCIInputImageKey];
    [thr setValue:@(6.0) forKey:kCIInputContrastKey];
    CIImage *boosted = thr.outputImage ?: scaled;
    return [ctx createCGImage:boosted fromRect:boosted.extent];
}

// Thu nhỏ ảnh để tách nhanh
+ (CGImageRef)downscaledCGImage:(CGImageRef)src width:(size_t)w height:(size_t)h {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), src);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;
}

// Tính mask đầy đủ kích thước ảnh gốc
+ (UIImage *)computeMaskForImage:(UIImage *)image {
    CGImageRef full = image.CGImage;
    if (!full) return nil;

    size_t W = CGImageGetWidth(full);
    size_t H = CGImageGetHeight(full);
    if (W == 0 || H == 0) return nil;

    CGFloat scale = MIN(1.0, kDWMaxSide / MAX((CGFloat)W, (CGFloat)H));
    size_t w = MAX((size_t)1, (size_t)(W * scale));
    size_t h = MAX((size_t)1, (size_t)(H * scale));

    CGImageRef small = [self downscaledCGImage:full width:w height:h];
    if (!small) return nil;

    CGImageRef maskSmall = NULL;
    if (@available(iOS 17.0, *)) {
        maskSmall = [self maskWithInstanceMask:small];
    }
    if (!maskSmall) maskSmall = [self maskWithPersonSegmentation:small];
    if (!maskSmall) maskSmall = [self maskWithSaliency:small];
    CGImageRelease(small);
    if (!maskSmall) return nil;

    CIImage *m = [CIImage imageWithCGImage:maskSmall];
    CGImageRelease(maskSmall);
    CGFloat sx = (CGFloat)W / m.extent.size.width;
    CGFloat sy = (CGFloat)H / m.extent.size.height;
    m = [m imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];

    CGImageRef out = [[CIContext contextWithOptions:nil] createCGImage:m
                                                              fromRect:CGRectMake(0, 0, W, H)];
    if (!out) return nil;
    UIImage *img = [UIImage imageWithCGImage:out];
    CGImageRelease(out);
    return img;
}

- (void)subjectMaskForImage:(UIImage *)image
                       data:(NSData *)data
                 completion:(void (^)(UIImage * _Nullable))completion {
    NSString *key = [NSString stringWithFormat:@"%@-%@", kDWAlgoVersion, [DWDepthEngine keyForData:data]];
    NSURL *file = [[DWDepthEngine cacheDirectory] URLByAppendingPathComponent:
                   [key stringByAppendingString:@".png"]];

    UIImage *cached = [UIImage imageWithContentsOfFile:file.path];
    if (cached) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *result = [DWDepthEngine computeMaskForImage:image];
        if (result) {
            NSData *png = UIImagePNGRepresentation(result);
            [png writeToURL:file atomically:YES];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
    });
}

+ (UIImage *)cutoutFromImage:(UIImage *)image mask:(UIImage *)mask {
    return [self cutoutFromImage:image mask:mask thickness:0.0];
}

+ (double)coverageOfMask:(UIImage *)mask {
    if (!mask.CGImage) return 0.0;
    const size_t n = 64;
    uint8_t *buf = calloc(n * n, 1);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(buf, n, n, 8, n, gray, kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!ctx) { free(buf); return 0.0; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, n, n), mask.CGImage);
    CGContextRelease(ctx);
    size_t on = 0;
    for (size_t i = 0; i < n * n; i++) if (buf[i] > 127) on++;
    free(buf);
    return (double)on / (double)(n * n);
}

+ (UIImage *)cutoutFromImage:(UIImage *)image mask:(UIImage *)mask thickness:(double)thickness {
    if (!image.CGImage || !mask.CGImage) return nil;

    CIImage *src = [CIImage imageWithCGImage:image.CGImage];
    CIImage *m = [CIImage imageWithCGImage:mask.CGImage];
    CGRect extent = src.extent;

    double t = MAX(-1.0, MIN(1.0, thickness));
    CGFloat radius = (CGFloat)fabs(t) * 12.0;
    if (radius >= 0.5) {
        NSString *filter = (t > 0) ? @"CIMorphologyMaximum" : @"CIMorphologyMinimum";
        CIFilter *morph = [CIFilter filterWithName:filter];
        [morph setValue:m forKey:kCIInputImageKey];
        [morph setValue:@(radius) forKey:kCIInputRadiusKey];
        if (morph.outputImage) m = [morph.outputImage imageByCroppingToRect:extent];
    }

    m = [m imageByApplyingFilter:@"CIMaskToAlpha"];

    CIFilter *blend = [CIFilter filterWithName:@"CIBlendWithMask"];
    [blend setValue:src forKey:kCIInputImageKey];
    [blend setValue:[CIImage emptyImage] forKey:kCIInputBackgroundImageKey];
    [blend setValue:m forKey:kCIInputMaskImageKey];
    if (!blend.outputImage) return nil;

    CGImageRef out = [[CIContext contextWithOptions:nil] createCGImage:blend.outputImage
                                                              fromRect:extent];
    if (!out) return nil;
    UIImage *img = [UIImage imageWithCGImage:out scale:image.scale orientation:UIImageOrientationUp];
    CGImageRelease(out);
    return img;
}

@end
