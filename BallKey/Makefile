export THEOS_PACKAGE_SCHEME = roothide

TARGET := iphone:clang:latest:15.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += Engine
SUBPROJECTS += Overlay

include $(THEOS)/makefiles/aggregate.mk
