#import "DWModelSegmenter.h"
#import "DWPrefs.h"
#import <CoreML/CoreML.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <dlfcn.h>

// Model U²-Net (Apache-2.0), input RGB 320x320, output tên "1959".
// Spec khai output Array(1,320,320) (rank 3) nhưng mạng thực tế trả [1,1,320,320] (rank 4);
// VNCoreMLTransform kiểm tra shape và báo "must be rank 3, got rank 4" -> request fail.
// Sửa v2: bỏ Vision, gọi thẳng MLModel predictionFromFeatures; CoreML không validate
// shape output như Vision nên chạy được, rồi tự đọc MLMultiArray (rank 4 đã hỗ trợ).

static NSString *gLastStatus = @"chưa thử";

static NSString *DWShortText(NSString *s) {
    if (!s) return @"(không mô tả)";
    return s.length > 180 ? [s substringToIndex:180] : s;
}

// <root>/Library/MobileSubstrate/DynamicLibraries/<tweak>.dylib -> <root>/Library/Application Support/DepthWallpaper
static NSArray<NSString *> *DWModelDirectories(void) {
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    Dl_info info = {0};
    if (dladdr((const void *)&DWModelDirectories, &info) && info.dli_fname) {
        NSString *p = [NSString stringWithUTF8String:info.dli_fname].stringByDeletingLastPathComponent; // DynamicLibraries
        p = p.stringByDeletingLastPathComponent; // MobileSubstrate
        p = p.stringByDeletingLastPathComponent; // Library
        NSString *root = p.stringByDeletingLastPathComponent;
        if (root.length) {
            [dirs addObject:[root stringByAppendingPathComponent:@"/Library/Application Support/DepthWallpaper"]];
        }
    }
    [dirs addObject:@"/var/jb/Library/Application Support/DepthWallpaper"]; // rootless Dopamine
    [dirs addObject:@"/Library/Application Support/DepthWallpaper"];       // rootful (dự phòng)
    return dirs;
}

static NSString *DWExistingRawModelPath(NSString **outCompiledDir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in DWModelDirectories()) {
        NSString *compiled = [dir stringByAppendingPathComponent:@"DWSubject.mlmodelc"];
        if ([fm fileExistsAtPath:compiled]) {
            if (outCompiledDir) *outCompiledDir = compiled;
            return nil;
        }
        NSString *raw = [dir stringByAppendingPathComponent:@"DWSubject.mlmodel"];
        if ([fm fileExistsAtPath:raw]) return raw;
    }
    return nil;
}

static CIContext *DWModelCIContext(void) {
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    });
    return ctx;
}

@implementation DWModelSegmenter

// Biên dịch .mlmodel trên máy (lần đầu) rồi giữ bản .mlmodelc trong Caches
+ (nullable NSURL *)compiledModelURL {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *compiledDir = nil;
    NSString *rawPath = DWExistingRawModelPath(&compiledDir);
    if (compiledDir) { gLastStatus = @"dùng model .mlmodelc có sẵn"; return [NSURL fileURLWithPath:compiledDir]; }
    if (!rawPath) { gLastStatus = @"không có file model"; return nil; }
    NSURL *caches = [[fm URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *dir = [caches URLByAppendingPathComponent:@"DepthWallpaper" isDirectory:YES];
    [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *dest = [dir URLByAppendingPathComponent:@"DWSubject.mlmodelc" isDirectory:YES];
    if ([fm fileExistsAtPath:dest.path]) return dest;
    NSError *err = nil;
    NSURL *tmp = [MLModel compileModelAtURL:[NSURL fileURLWithPath:rawPath] error:&err];
    if (!tmp) { gLastStatus = [NSString stringWithFormat:@"biên dịch lỗi: %@", DWShortText(err.description)]; return nil; }
    [fm removeItemAtURL:dest error:nil];
    if (![fm moveItemAtURL:tmp toURL:dest error:&err]) {
        gLastStatus = [NSString stringWithFormat:@"move lỗi: %@", DWShortText(err.description)]; return nil;
    }
    return dest;
}

+ (nullable MLModel *)loadedMLModel {
    static MLModel *ml;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [self compiledModelURL];
        if (!url) return;
        NSError *err = nil;
        ml = [MLModel modelWithContentsOfURL:url error:&err];
        gLastStatus = ml ? @"đã nạp model"
                         : [NSString stringWithFormat:@"nạp MLModel lỗi: %@", DWShortText(err.description)];
    });
    return ml;
}

+ (NSString *)lastStatus {
    return gLastStatus;
}

+ (BOOL)isModelAvailable {
    return [self loadedMLModel] != nil;
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

// Chuyển MLMultiArray đầu ra thành mask gray nhị phân (255 = chủ thể).
// - Probability [1,H,W] / [1,1,H,W]: pixel = 255 nếu xác suất >= 0.5.
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
    MLModel *ml = [self loadedMLModel];
    if (!ml || !image) return NULL;
    const NSInteger SZ = 320;
    CVPixelBufferRef pb = NULL;
    CVReturn cv = CVPixelBufferCreate(kCFAllocatorDefault, SZ, SZ, kCVPixelFormatType_32BGRA, NULL, &pb);
    if (cv != kCVReturnSuccess || !pb) { gLastStatus = @"không tạo được pixel buffer 320"; return NULL; }
    @autoreleasepool {
        CIImage *ci = [CIImage imageWithCGImage:image];
        CGFloat iw = (CGFloat)CGImageGetWidth(image);
        CGFloat ih = (CGFloat)CGImageGetHeight(image);
        // ScaleFill: phóng to vừa khung 320x320 rồi cắt giữa, giữ tỷ lệ chủ thể.
        CGFloat s = MAX(SZ / MAX(1.0, iw), SZ / MAX(1.0, ih));
        CGAffineTransform t = CGAffineTransformMakeTranslation((SZ - iw * s) / 2.0, (SZ - ih * s) / 2.0);
        t = CGAffineTransformScale(t, s, s);
        ci = [ci imageByApplyingTransform:t];
        CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
        NSError *renderErr = nil;
        [DWModelCIContext() render:ci toCVPixelBuffer:pb bounds:CGRectMake(0, 0, SZ, SZ)
                        colorSpace:rgb error:&renderErr];
        CGColorSpaceRelease(rgb);

        MLFeatureValue *fv = [MLFeatureValue featureValueWithPixelBuffer:pb];
        MLMutableDictionaryFeatureProvider *provider =
            [[MLMutableDictionaryFeatureProvider alloc] initWithDictionary:@{ @"input.1": fv }];
        NSError *err = nil;
        id<MLFeatureProvider> out = [ml predictionFromFeatures:provider error:&err];
        if (!out) {
            gLastStatus = [NSString stringWithFormat:@"suy luận lỗi: %@",
                                                    DWShortText(err.localizedDescription ?: err.description)];
            CVPixelBufferRelease(pb);
            return NULL;
        }
        MLMultiArray *arr = nil;
        MLFeatureValue *ov = [out featureValueForName:@"1959"];
        if (ov.multiArrayValue) {
            arr = ov.multiArrayValue;
        } else {
            for (NSString *name in out.featureNames) {
                MLFeatureValue *v = [out featureValueForName:name];
                if (v.multiArrayValue) { arr = v.multiArrayValue; break; }
            }
        }
        if (!arr) {
            gLastStatus = @"model không trả multiArray";
            CVPixelBufferRelease(pb);
            return NULL;
        }
        NSInteger cls = (NSInteger)DWPrefDouble(@"segClass", 15);
        CGImageRef mask = DWMaskFromMultiArray(arr, cls);
        CVPixelBufferRelease(pb);
        if (mask) {
            gLastStatus = @"model OK (dự luận trực tiếp)";
        } else {
            gLastStatus = @"model ra mask rỗng";
        }
        return mask;
    }
}

@end
