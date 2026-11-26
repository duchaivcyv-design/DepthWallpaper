TARGET = iphone:clang:16.5:16.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DepthWallpaper
DepthWallpaper_FILES = Tweak.xm $(wildcard Sources/*.m)
DepthWallpaper_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
# V2: thêm CoreMotion (parallax bằng accelerometer) và CoreVideo (CVPixelBuffer cho model).
DepthWallpaper_FRAMEWORKS = UIKit Vision CoreImage CoreML QuartzCore CoreMotion CoreVideo
include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += Prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
