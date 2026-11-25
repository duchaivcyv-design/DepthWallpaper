#import "DWPrefs.h"

// Đọc trực tiếp từ domain plist mỗi lần gọi (không cache), để công tắc và slider có tác dụng ngay.
BOOL DWPrefBool(NSString *key, BOOL defaultValue) {
    CFStringRef suite = (__bridge CFStringRef)DW_PREFS_SUITE;
    CFPreferencesAppSynchronize(suite);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, suite);
    if (!value) return defaultValue;

    BOOL result = defaultValue;
    CFTypeID type = CFGetTypeID(value);
    if (type == CFBooleanGetTypeID()) {
        result = CFBooleanGetValue((CFBooleanRef)value);
    } else if (type == CFNumberGetTypeID()) {
        int n = 0;
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &n);
        result = (n != 0);
    }
    CFRelease(value);
    return result;
}

double DWPrefDouble(NSString *key, double defaultValue) {
    CFStringRef suite = (__bridge CFStringRef)DW_PREFS_SUITE;
    CFPreferencesAppSynchronize(suite);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, suite);
    if (!value) return defaultValue;

    double result = defaultValue;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &result);
    }
    CFRelease(value);
    return result;
}

void DWPrefSetDouble(NSString *key, double value) {
    CFStringRef suite = (__bridge CFStringRef)DW_PREFS_SUITE;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)@(value), suite);
    CFPreferencesAppSynchronize(suite);
}
