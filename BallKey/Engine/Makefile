export THEOS_PACKAGE_SCHEME = roothide

TARGET := iphone:clang:latest:15.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BallKeyEngine

BallKeyEngine_FILES = Tweak.x
BallKeyEngine_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/common -I$(THEOS_PROJECT_DIR)/../common -I$(THEOS)/vendor/include
BallKeyEngine_FRAMEWORKS = Foundation CoreGraphics IOKit

include $(THEOS_MAKE_PATH)/tweak.mk
