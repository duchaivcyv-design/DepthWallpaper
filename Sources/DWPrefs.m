#import "DWPrefs.h"

// Đọc trực tiếp từ domain plist mỗi lần gọi (không cache), để công tắc có tác dụng ngay.
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
