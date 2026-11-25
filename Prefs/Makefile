include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = DepthWallpaperPrefs
DepthWallpaperPrefs_FILES = DWRootListController.m DWDepthPreviewController.m ../Sources/DWPrefs.m ../Sources/DWClassResolver.m ../Sources/DWDepthEngine.m ../Sources/DWRenderer.m
DepthWallpaperPrefs_RESOURCE_DIRS = Resources
DepthWallpaperPrefs_INSTALL_PATH = /Library/PreferenceBundles
DepthWallpaperPrefs_FRAMEWORKS = UIKit Vision CoreImage QuartzCore
DepthWallpaperPrefs_PRIVATE_FRAMEWORKS = Preferences
DepthWallpaperPrefs_CFLAGS = -fobjc-arc -I.. -I../Sources -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/bundle.mk
