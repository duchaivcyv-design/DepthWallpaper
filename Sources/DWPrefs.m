#import "DWPrefs.h"

// Cache trong bộ nhớ: không đọc đĩa trên đường nóng (layoutSubviews, gesture).
static NSMutableDictionary *gPrefsCache;

static NSMutableDictionary *DWCache(void) {
    if (!gPrefsCache) gPrefsCache = [NSMutableDictionary dictionary];
    return gPrefsCache;
}

static id DWValueForKey(NSString *key) {
    @synchronized (gPrefsCache) {
        NSMutableDictionary *c = DWCache();
        id cached = c[key];
        if (cached) return cached == [NSNull null] ? nil : cached;
        CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)DW_PREFS_SUITE);
        id obj = v ? [(__bridge id)v copy] : nil;
        if (v) CFRelease(v);
        c[key] = obj ? obj : [NSNull null];
        return obj;
    }
}

void DWPrefsInvalidate(void) {
    @synchronized (gPrefsCache) {
        gPrefsCache = [NSMutableDictionary dictionary];
    }
    CFPreferencesAppSynchronize((__bridge CFStringRef)DW_PREFS_SUITE);
}

BOOL DWPrefBool(NSString *key, BOOL defaultValue) {
    id v = DWValueForKey(key);
    if (!v) return defaultValue;
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    return defaultValue;
}

double DWPrefDouble(NSString *key, double defaultValue) {
    id v = DWValueForKey(key);
    if (!v) return defaultValue;
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    return defaultValue;
}

void DWPrefSetDouble(NSString *key, double value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@(value),
                             (__bridge CFStringRef)DW_PREFS_SUITE);
    CFPreferencesAppSynchronize((__bridge CFStringRef)DW_PREFS_SUITE);
    @synchronized (gPrefsCache) {
        DWCache()[key] = @(value);
    }
}
