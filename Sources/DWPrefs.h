#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DW_PREFS_SUITE  @"com.dj.depthwallpaper"
#define DW_RELOAD_NOTE  "com.dj.depthwallpaper/reload"

BOOL DWPrefBool(NSString *key, BOOL defaultValue);

#ifdef __cplusplus
}
#endif
