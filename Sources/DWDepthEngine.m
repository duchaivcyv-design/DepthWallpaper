#import "DWDepthEngine.h"
#import <Vision/Vision.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#import "DWModelSegmenter.h"

static const CGFloat kDWMaxSide = 1024.0;
// Tăng số này mỗi khi đổi thuật toán mask, để bỏ cache mask cũ.
// v19: thêm nhị phân hoá mask + cache cutout; model gọi trực tiếp MLModel.
static NSString *const kDWAlgoVersion = @"v19";
static NSString *gMaskSource = @"chưa có";
static const double kDWMinCoverage = 0.005;

// Dùng chung một CIContext (GPU) thay vì tạo mới mỗi lần -> giảm áp lực bộ nhớ,
// tránh jetsam trên máy 2GB (iPhone 8, iOS 16.7.16).
static CIContext *DWSharedCIContext(void) {
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    });
    return ctx;
}

// Nhị phân hoá mask: mọi pixel < threshold thành 0, >= threshold thành 255.
// Đây là gốc lỗi "vệt xám giữa mặt": saliency/nhiều mask trả giá trị mềm (xám 50..200),
// CIMaskToAlpha dùng luminance làm alpha -> chủ thể trong suốt 30..70%, nhìn như đốm xám.
// openRadius > 0: mở hình thái (Minimum rồi Maximum) xoá chấm nhiễu rời rạc.
static CGImageRef DWBinarizeMask(CGImageRef src, uint8_t threshold, CGFloat openRadius) {
    if (!src) return NULL;
    size_t W = CGImageGetWidth(src), H = CGImageGetHeight(src);
    if (W == 0 || H == 0) return NULL;
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef bctx = CGBitmapContextCreate(NULL, W, H, 8, W, gray, kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!bctx) return NULL;
    CGContextDrawImage(bctx, CGRectMake(0, 0, W, H), src);
    uint8_t *pix = (uint8_t *)CGBitmapContextGetData(bctx);
    for (size_t i = 0; i < W * H; i++) pix[i] = pix[i] >= threshold ? 255 : 0;
    CGImageRef bin = CGBitmapContextCreateImage(bctx);
    CGContextRelease(bctx);
    if (openRadius > 0.5 && bin) {
        CIImage *m = [CIImage imageWithCGImage:bin];
        CIFilter *mn = [CIFilter filterWithName:@"CIMorphologyMinimum"];
        [mn setValue:m forKey:kCIInputImageKey];
        [mn setValue:@(openRadius) forKey:kCIInputRadiusKey];
        CIFilter *mx = [CIFilter filterWithName:@"CIMorphologyMaximum"];
        [mx setValue:mn.outputImage forKey:kCIInputImageKey];
        [mx setValue:@(openRadius) forKey:kCIInputRadiusKey];
        CGImageRef opened = [DWSharedCIContext() createCGImage:mx.outputImage fromRect:mx.outputImage.extent];
        CGImageRelease(bin);
        bin = opened;
    }
    return bin;
}

@interface DWDepthEngine (Internal)
+ (double)coverageOfCGImage:(CGImageRef)m;
@end

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

#pragma mark - Tiện ích CGImage
// Tỉ lệ pixel sáng (>127) khi lấy mẫu 128x128
+ (double)coverageOfCGImage:(CGImageRef)m {
    if (!m) return 0.0;
    const size_t n = 128;
    uint8_t *buf = calloc(n * n, 1);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(buf, n, n, 8, n, gray, kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!ctx) { free(buf); return 0.0; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, n, n), m);
    CGContextRelease(ctx);
    size_t on = 0;
    for (size_t i = 0; i < n * n; i++) if (buf[i] > 127) on++;
    free(buf);
    return (double)on / (double)(n * n);
}

+ (CGImageRef)grayCGImageFromCIImage:(CIImage *)ci {
    return [DWSharedCIContext() createCGImage:ci fromRect:ci.extent];
}

#pragma mark - Các bước tách mask (trả về CGImage grayscale, trắng = chủ thể; caller tự release)
// iOS 17+: tách mọi vật thể nổi bật. Runtime lookup vì SDK 16.5 chưa khai báo class này.
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
    CGImageRef out = [self grayCGImageFromCIImage:ci];
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
        return [self grayCGImageFromCIImage:ci];
    }
    return NULL;
}

// iOS 13+: heatmap saliency. Ngưỡng ở `t` nhân với giá trị đỉnh.
// Output là heatmap mềm; cuối pipeline sẽ được DWBinarizeMask -> không còn vệt xám.
+ (CGImageRef)maskWithSaliency:(CGImageRef)cg threshold:(double)t {
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
    VNGenerateAttentionBasedSaliencyImageRequest *req = [VNGenerateAttentionBasedSaliencyImageRequest new];
    if (![handler performRequests:@[req] error:nil]) return NULL;
    CVPixelBufferRef pb = req.results.firstObject.pixelBuffer;
    if (!pb) return NULL;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
    CIContext *ctx = DWSharedCIContext();
    CIFilter *maxF = [CIFilter filterWithName:@"CIAreaMaximum"];
    [maxF setValue:ci forKey:kCIInputImageKey];
    [maxF setValue:[CIVector vectorWithCGRect:ci.extent] forKey:kCIInputExtentKey];
    CIImage *maxImg = maxF.outputImage;
    if (!maxImg) return NULL;
    uint8_t px[4] = {0, 0, 0, 0};
    [ctx render:maxImg toBitmap:px rowBytes:4 bounds:CGRectMake(0, 0, 1, 1)
         format:kCIFormatRGBA8 colorSpace:nil];
    double peakByte = MAX(1.0, (double)MAX(px[0], MAX(px[1], px[2])));
    double s = 20.0 * 255.0 / peakByte;
    double b = 0.5 - 20.0 * t;
    CIFilter *f = [CIFilter filterWithName:@"CIColorMatrix"];
    [f setValue:ci forKey:kCIInputImageKey];
    [f setValue:[CIVector vectorWithX:s Y:0 Z:0 W:0] forKey:@"inputRVector"];
    [f setValue:[CIVector vectorWithX:s Y:0 Z:0 W:0] forKey:@"inputGVector"];
    [f setValue:[CIVector vectorWithX:s Y:0 Z:0 W:0] forKey:@"inputBVector"];
    [f setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:0] forKey:@"inputAVector"];
    [f setValue:[CIVector vectorWithX:b Y:b Z:b W:1] forKey:@"inputBiasVector"];
    CIImage *out = f.outputImage;
    if (!out) return NULL;
    return [ctx createCGImage:out fromRect:ci.extent];
}

// iOS 13+: hình chữ nhật bao quanh vật nổi bật. Dùng khi heatmap không ra gì.
+ (CGImageRef)maskWithObjectness:(CGImageRef)cg {
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
    VNGenerateObjectnessBasedSaliencyImageRequest *req = [VNGenerateObjectnessBasedSaliencyImageRequest new];
    if (![handler performRequests:@[req] error:nil]) return NULL;
    VNSaliencyImageObservation *obs = req.results.firstObject;
    NSArray<VNRectangleObservation *> *objs = obs.salientObjects;
    if (objs.count == 0) return NULL;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, gray, kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    if (!ctx) return NULL;
    CGContextSetGrayFillColor(ctx, 0.0, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    CGContextSetGrayFillColor(ctx, 1.0, 1.0);
    for (VNRectangleObservation *o in objs) {
        CGRect r = o.boundingBox;
        CGContextFillRect(ctx, CGRectMake(r.origin.x * w, r.origin.y * h,
                                          r.size.width * w, r.size.height * h));
    }
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;
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

// Tính mask đầy đủ kích thước ảnh gốc, có chuỗi fallback
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
    gMaskSource = @"không có";
    CGImageRef maskSmall = NULL;
    if (@available(iOS 17.0, *)) {
        maskSmall = [self maskWithInstanceMask:small];
        if (maskSmall) gMaskSource = @"instance";
        if (maskSmall && [self coverageOfCGImage:maskSmall] < kDWMinCoverage) {
            CGImageRelease(maskSmall); maskSmall = NULL;
        }
    }
    if (!maskSmall) {
        maskSmall = [DWModelSegmenter maskForCGImage:small];
        if (maskSmall) gMaskSource = @"model";
        if (maskSmall && [self coverageOfCGImage:maskSmall] < kDWMinCoverage) {
            CGImageRelease(maskSmall); maskSmall = NULL;
        }
    }
    if (!maskSmall) {
        maskSmall = [self maskWithPersonSegmentation:small];
        if (maskSmall) gMaskSource = @"person";
        if (maskSmall && [self coverageOfCGImage:maskSmall] < kDWMinCoverage) {
            CGImageRelease(maskSmall); maskSmall = NULL;
        }
    }
    if (!maskSmall) {
        maskSmall = [self maskWithSaliency:small threshold:0.3];
        if (maskSmall) gMaskSource = @"saliency";
        if (maskSmall && [self coverageOfCGImage:maskSmall] < kDWMinCoverage) {
            CGImageRelease(maskSmall); maskSmall = NULL;
        }
    }
    if (!maskSmall) {
        CGImageRef box = [self maskWithObjectness:small];
        CGImageRef sal = [self maskWithSaliency:small threshold:0.1];
        if (box && sal) {
            CIImage *cb = [CIImage imageWithCGImage:box];
            CIImage *cs = [CIImage imageWithCGImage:sal];
            CIFilter *mul = [CIFilter filterWithName:@"CIMultiplyCompositing"];
            [mul setValue:cb forKey:kCIInputImageKey];
            [mul setValue:cs forKey:kCIInputBackgroundImageKey];
            CIImage *prod = mul.outputImage;
            if (prod) {
                CGImageRef pm = [DWSharedCIContext() createCGImage:prod fromRect:cb.extent];
                if (pm && [self coverageOfCGImage:pm] >= kDWMinCoverage) {
                    maskSmall = pm;
                } else if (pm) {
                    CGImageRelease(pm);
                }
            }
        }
        if (box) CGImageRelease(box);
        if (sal) CGImageRelease(sal);
    }
    CGImageRelease(small);
    if (!maskSmall) return nil;

    // V2: mọi nguồn mask đều phải nhị phân hoá trước khi lên màn hình -> hết vệt xám mềm.
    CGImageRef bin = DWBinarizeMask(maskSmall, 128, 1.0);
    CGImageRelease(maskSmall);
    maskSmall = bin;
    if (!maskSmall) return nil;

    CIImage *m = [CIImage imageWithCGImage:maskSmall];
    CGImageRelease(maskSmall);
    CGFloat sx = (CGFloat)W / m.extent.size.width;
    CGFloat sy = (CGFloat)H / m.extent.size.height;
    m = [m imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
    CGImageRef out = [DWSharedCIContext() createCGImage:m fromRect:CGRectMake(0, 0, W, H)];
    if (!out) return nil;
    UIImage *img = [UIImage imageWithCGImage:out];
    CGImageRelease(out);
    return img;
}

+ (NSString *)lastMaskSource {
    return gMaskSource;
}

+ (double)coverageOfMask:(UIImage *)mask {
    return mask.CGImage ? [self coverageOfCGImage:mask.CGImage] : 0.0;
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
        @autoreleasepool {
            UIImage *result = [DWDepthEngine computeMaskForImage:image];
            if (result) {
                NSData *png = UIImagePNGRepresentation(result);
                [png writeToURL:file atomically:YES];
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    });
}

// V2: mask + cắt chủ thể cùng trên luồng nền; cache cả cutout để lần sau hiện tức thì,
// không tái tính trên main thread (nguyên nhân đơ vài giây khi thoát Notification Center).
- (void)subjectCutoutForImage:(UIImage *)image
                         data:(NSData *)data
                    thickness:(double)thickness
                   completion:(void (^)(UIImage * _Nullable))completion {
    NSString *hashKey = [DWDepthEngine keyForData:data];
    NSURL *maskFile = [[DWDepthEngine cacheDirectory] URLByAppendingPathComponent:
                       [NSString stringWithFormat:@"%@-%@.png", kDWAlgoVersion, hashKey]];
    NSURL *cutFile = [[DWDepthEngine cacheDirectory] URLByAppendingPathComponent:
                      [NSString stringWithFormat:@"%@-cut-%.3f-%@.png", kDWAlgoVersion, thickness, hashKey]];
    UIImage *cachedCut = [UIImage imageWithContentsOfFile:cutFile.path];
    if (cachedCut) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cachedCut); });
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            UIImage *mask = [UIImage imageWithContentsOfFile:maskFile.path];
            if (!mask) {
                mask = [DWDepthEngine computeMaskForImage:image];
                if (mask) {
                    NSData *png = UIImagePNGRepresentation(mask);
                    [png writeToURL:maskFile atomically:YES];
                }
            }
            UIImage *cut = nil;
            if (mask) {
                cut = [DWDepthEngine cutoutFromImage:image mask:mask thickness:thickness];
            }
            if (cut) {
                NSData *png = UIImagePNGRepresentation(cut);
                [png writeToURL:cutFile atomically:YES];
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(cut); });
        }
    });
}

+ (UIImage *)cutoutFromImage:(UIImage *)image mask:(UIImage *)mask {
    return [self cutoutFromImage:image mask:mask thickness:0.0];
}

+ (UIImage *)cutoutFromImage:(UIImage *)image mask:(UIImage *)mask thickness:(double)thickness {
    if (!image.CGImage || !mask.CGImage) return nil;
    // Nhị phân hoá cả mask dùng cho cắt: chặn mọi alpha xám còn sót ở biên.
    CGImageRef binMask = DWBinarizeMask(mask.CGImage, 128, 0.0);
    if (!binMask) return nil;
    CIImage *src = [CIImage imageWithCGImage:image.CGImage];
    CIImage *m = [CIImage imageWithCGImage:binMask];
    CGImageRelease(binMask);
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
    CGImageRef out = [DWSharedCIContext() createCGImage:blend.outputImage fromRect:extent];
    if (!out) return nil;
    UIImage *img = [UIImage imageWithCGImage:out scale:image.scale orientation:UIImageOrientationUp];
    CGImageRelease(out);
    return img;
}

@end
