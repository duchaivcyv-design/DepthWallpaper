TARGET := iphone:clang:latest:16.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DepthWallpaper

DepthWallpaper_FILES = Tweak.xm $(wildcard Sources/*.m)
DepthWallpaper_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
DepthWallpaper_FRAMEWORKS = UIKit Vision CoreImage QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += Prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
