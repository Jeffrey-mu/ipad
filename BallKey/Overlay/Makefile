export THEOS_PACKAGE_SCHEME = roothide

TARGET := iphone:clang:latest:15.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BallKeyOverlay

BallKeyOverlay_FILES = Tweak.x
BallKeyOverlay_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/common -I$(THEOS_PROJECT_DIR)/../common -I$(THEOS)/vendor/include
BallKeyOverlay_FRAMEWORKS = Foundation UIKit CoreGraphics IOKit

include $(THEOS_MAKE_PATH)/tweak.mk
