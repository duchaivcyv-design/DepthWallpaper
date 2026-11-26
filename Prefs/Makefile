include $(THEOS)/makefiles/common.mk
BUNDLE_NAME = DepthWallpaperPrefs
DepthWallpaperPrefs_FILES = DWRootListController.m DWDepthPreviewController.m ../Sources/DWDepthEngine.m ../Sources/DWRenderer.m ../Sources/DWPrefs.m ../Sources/DWModelSegmenter.m
DepthWallpaperPrefs_RESOURCE_DIRS = Resources
DepthWallpaperPrefs_INSTALL_PATH = /Library/PreferenceBundles
DepthWallpaperPrefs_FRAMEWORKS = UIKit Vision CoreImage CoreML QuartzCore CoreVideo
DepthWallpaperPrefs_PRIVATE_FRAMEWORKS = Preferences
DepthWallpaperPrefs_CFLAGS = -fobjc-arc -I../Sources -Wno-deprecated-declarations
include $(THEOS_MAKE_PATH)/bundle.mk
