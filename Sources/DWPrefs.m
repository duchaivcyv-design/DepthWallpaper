#import "DWPrefs.h"

static NSString *const kDWSuite = @"com.dj.depthwallpaper";

BOOL DWPrefBool(NSString *key, BOOL defaultValue) {
    static NSUserDefaults *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        defaults = [[NSUserDefaults alloc] initWithSuiteName:kDWSuite];
    });
    id value = [defaults objectForKey:key];
    return value ? [defaults boolForKey:key] : defaultValue;
}
