export THEOS_PACKAGE_SCHEME = roothide

TARGET := iphone:clang:latest:15.0
# A12X 是 legacy arm64e：同时产出 arm64 + arm64e，避免加载器按架构跳过
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Pin120

Pin120_FILES = Tweak.x
Pin120_CFLAGS = -fobjc-arc
Pin120_FRAMEWORKS = UIKit QuartzCore Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
