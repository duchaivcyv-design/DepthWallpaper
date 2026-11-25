#import "DWClassResolver.h"
#import "DWPrefs.h"
#import <objc/runtime.h>

static NSString *const kDWLogDir = @"/var/mobile/Library/Logs/DepthWallpaper";
static NSMutableArray<NSString *> *gResolvedLines;

static NSString *DWProcessName(void) {
    return [[NSProcessInfo processInfo] processName];
}

static NSString *DWIOSVersion(void) {
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    return [NSString stringWithFormat:@"%ld.%ld.%ld", (long)v.majorVersion,
            (long)v.minorVersion, (long)v.patchVersion];
}

static void DWEnsureLogDir(void) {
    [[NSFileManager defaultManager] createDirectoryAtPath:kDWLogDir
                              withIntermediateDirectories:YES attributes:nil error:nil];
}

static void DWAppendResolved(NSString *line) {
    NSLog(@"[DepthWallpaper] %@", line);
    if (!gResolvedLines) gResolvedLines = [NSMutableArray array];
    [gResolvedLines addObject:line];
    DWEnsureLogDir();
    NSString *path = [kDWLogDir stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"resolved-%@.txt", DWProcessName()]];
    NSString *all = [[gResolvedLines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    [all writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

Class DWFindClass(NSArray<NSString *> *exactNames,
                  NSString *mustContain,
                  NSString *selectorName,
                  Class baseClass,
                  NSString *hookLabel) {
    Class found = Nil;
    NSString *how = @"none";

    for (NSString *name in exactNames) {
        Class c = NSClassFromString(name);
        if (c && (!selectorName || class_getInstanceMethod(c, NSSelectorFromString(selectorName)))) {
            found = c;
            how = [NSString stringWithFormat:@"exact:%@", name];
            break;
        }
    }

    if (!found && mustContain.length) {
        unsigned int count = 0;
        Class *list = objc_copyClassList(&count);
        NSMutableArray<NSString *> *matches = [NSMutableArray array];
        for (unsigned int i = 0; i < count; i++) {
            Class c = list[i];
            NSString *name = NSStringFromClass(c);
            if ([name rangeOfString:mustContain].location == NSNotFound) continue;
            if (baseClass && ![c isSubclassOfClass:baseClass]) continue;
            if (selectorName && !class_getInstanceMethod(c, NSSelectorFromString(selectorName))) continue;
            [matches addObject:name];
        }
        free(list);

        [matches sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            if (a.length != b.length) return a.length < b.length ? NSOrderedAscending : NSOrderedDescending;
            return [a compare:b];
        }];
        if (matches.count) {
            found = NSClassFromString(matches.firstObject);
            how = [NSString stringWithFormat:@"scan:%@ (candidates: %@)", matches.firstObject,
                   [matches componentsJoinedByString:@", "]];
        }
    }

    DWAppendResolved([NSString stringWithFormat:@"[iOS %@][%@] %@ -> %@ | %@",
                      DWIOSVersion(), DWProcessName(), hookLabel,
                      found ? NSStringFromClass(found) : @"NOT FOUND", how]);
    return found;
}

void DWDumpRelevantClassesOnce(void) {
    if (!DWPrefBool(@"dumpClasses", YES)) return;

    NSString *path = [kDWLogDir stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"classes-%@-%@.txt", DWProcessName(), DWIOSVersion()]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return;

    DWEnsureLogDir();

    NSArray<NSString *> *keywords = @[@"Wallpaper", @"DateView", @"NotificationCenter", @"NCNotification",
                                      @"Legibility", @"LockScreen", @"CoverSheet", @"Dock", @"SBHome",
                                      @"Poster", @"Depth", @"Editor", @"Parallax", @"Zoom"];

    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"iOS %@", DWIOSVersion()]];
    [lines addObject:[NSString stringWithFormat:@"process %@", DWProcessName()]];

    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(list[i]);
        for (NSString *kw in keywords) {
            if ([name rangeOfString:kw].location != NSNotFound) {
                [lines addObject:name];
                break;
            }
        }
    }
    free(list);

    [lines sortUsingSelector:@selector(compare:)];
    [[lines componentsJoinedByString:@"\n"] writeToFile:path atomically:YES
                                               encoding:NSUTF8StringEncoding error:nil];
}
