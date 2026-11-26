#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DW_PREFS_SUITE  @"com.dj.depthwallpaper"
#define DW_RELOAD_NOTE  "com.dj.depthwallpaper/reload"

BOOL   DWPrefBool(NSString *key, BOOL defaultValue);
double DWPrefDouble(NSString *key, double defaultValue);
void   DWPrefSetDouble(NSString *key, double value);
/// Xóa cache và đồng bộ lại từ đĩa. Gọi khi nhận thông báo reload hoặc sau khi ghi.
void   DWPrefsInvalidate(void);

#ifdef __cplusplus
}
#endif
