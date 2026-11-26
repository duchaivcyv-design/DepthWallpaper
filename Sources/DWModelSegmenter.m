#import "DWModelSegmenter.h"
#import "DWPrefs.h"
#import <Vision/Vision.h>
#import <CoreML/CoreML.h>

// Model U²-Net (Apache-2.0) đã chuyển sang Core ML bằng tools/convert_u2net.py.
// Đầu ra: MLMultiArray [1,1,320,320] là xác suất chủ thể.
static NSString *const kDWModelPath = @"/Library/Application Support/DepthWallpaper/DWSubject.mlmodel";

@implementation DWModelSegmenter

// Biên dịch .mlmodel trên máy (lần đầu) rồi giữ bản .mlmodelc trong Caches
+ (nullable NSURL *)compiledModelURL {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kDWModelPath]) return nil;

    NSURL *caches = [[fm URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *dir = [caches URLByAppendingPathComponent:@"DepthWallpaper" isDirectory:YES];
    [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *dest = [dir URLByAppendingPathComponent:@"DWSubject.mlmodelc" isDirectory:YES];
    if ([fm fileExistsAtPath:dest.path]) return dest;

    NSError *err = nil;
    NSURL *tmp = [MLModel compileModelAtURL:[NSURL fileURLWithPath:kDWModelPath] error:&err];
    if (!tmp) return nil;
    [fm removeItemAtURL:dest error:nil];
    if (![fm moveItemAtURL:tmp toURL:dest error:&err]) return nil;
    return dest;
}

+ (nullable VNCoreMLModel *)loadedModel {
    static VNCoreMLModel *model;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [self compiledModelURL];
        if (!url) return;
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

static double DWValueAt(MLMultiArray *arr, NSInteger linear) {
    if (arr.dataType == MLMultiArrayDataTypeFloat32) {
        return ((const float *)arr.dataPointer)[linear];
    }
    if (arr.dataType == MLMultiArrayDataTypeInt32) {
        return (double)((const int32_t *)arr.dataPointer)[linear];
    }
    if (arr.dataType == MLMultiArrayDataTypeDouble) {
        return ((const double *)arr.dataPointer)[linear];
    }
    return 0.0;
}

// Chuyển MLMultiArray đầu ra thành mask gray (255 = chủ thể).
// - Xác suất 1 kênh (U²-Net): pixel = 255 nếu xác suất >= 0.5.
// - Nhãn lớp [H,W]: pixel = 255 nếu nhãn == cls.
// - Nhiều kênh [C,H,W]: argmax rồi so với cls.
static CGImageRef DWMaskFromMultiArray(MLMultiArray *arr, NSInteger cls) {
    NSArray<NSNumber *> *shape = arr.shape;
    NSInteger H = 0, W = 0, C = 1;
    BOOL probability = NO;
    if (shape.count == 2) {
        H = shape[0].integerValue; W = shape[1].integerValue;
    } else if (shape.count == 3) {
        C = shape[0].integerValue; H = shape[1].integerValue; W = shape[2].integerValue;
        probability = (C == 1);
    } else if (shape.count == 4) {
        C = shape[1].integerValue; H = shape[2].integerValue; W = shape[3].integerValue;
        probability = (C == 1);
    } else {
        return NULL;
    }
    if (H <= 0 || W <= 0) return NULL;

    uint8_t *buf = calloc((size_t)(H * W), 1);
    for (NSInteger y = 0; y < H; y++) {
        for (NSInteger x = 0; x < W; x++) {
            NSInteger idx = y * W + x;
            BOOL on = NO;
            if (probability) {
                on = DWValueAt(arr, idx) >= 0.5;
            } else if (C == 1) {
                on = ((NSInteger)llround(DWValueAt(arr, idx)) == cls);
            } else {
                double best = -INFINITY; NSInteger bestC = 0;
                for (NSInteger c = 0; c < C; c++) {
                    double v = DWValueAt(arr, c * H * W + idx);
                    if (v > best) { best = v; bestC = c; }
                }
                on = (bestC == cls);
            }
            buf[idx] = on ? 255 : 0;
        }
    }

    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(buf, (size_t)W, (size_t)H, 8, (size_t)W, gray,
                                             kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    CGImageRef out = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (ctx) CGContextRelease(ctx);
    free(buf);
    return out;
}

+ (nullable CGImageRef)maskForCGImage:(CGImageRef)image {
    VNCoreMLModel *model = [self loadedModel];
    if (!model || !image) return NULL;

    VNCoreMLRequest *req = [[VNCoreMLRequest alloc] initWithModel:model];
    req.imageCropAndScaleOption = VNImageCropAndScaleOptionScaleFill;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    if (![handler performRequests:@[req] error:nil]) return NULL;

    size_t W = CGImageGetWidth(image), H = CGImageGetHeight(image);

    for (id r in req.results) {
        if ([r isKindOfClass:[VNPixelBufferObservation class]]) {
            CIImage *ci = [CIImage imageWithCVPixelBuffer:((VNPixelBufferObservation *)r).pixelBuffer];
            CGFloat sx = (CGFloat)W / ci.extent.size.width;
            CGFloat sy = (CGFloat)H / ci.extent.size.height;
            ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
            return [[CIContext contextWithOptions:nil] createCGImage:ci fromRect:CGRectMake(0, 0, W, H)];
        }
    }

    NSInteger cls = (NSInteger)DWPrefDouble(@"segClass", 15);
    for (id r in req.results) {
        if ([r isKindOfClass:[VNCoreMLFeatureValueObservation class]]) {
            MLMultiArray *arr = ((VNCoreMLFeatureValueObservation *)r).featureValue.multiArrayValue;
            if (!arr) continue;
            CGImageRef small = DWMaskFromMultiArray(arr, cls);
            if (!small) continue;
            CIImage *ci = [CIImage imageWithCGImage:small];
            CGImageRelease(small);
            CGFloat sx = (CGFloat)W / ci.extent.size.width;
            CGFloat sy = (CGFloat)H / ci.extent.size.height;
            ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
            return [[CIContext contextWithOptions:nil] createCGImage:ci fromRect:CGRectMake(0, 0, W, H)];
        }
    }
    return NULL;
}

@end
