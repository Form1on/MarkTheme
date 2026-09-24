ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:17.0
THEOS_PACKAGE_SCHEME = rootless
PACKAGE_VERSION = 0.1.0
FINALPACKAGE = 1

# The report separately reads the installed Runtime build (possibly 204).
MARKTHEME_RUNTIME_BUILD_NUMBER := $(shell sed -n 's/^MARKTHEME_RUNTIME_BUILD_NUMBER := //p' ../../Config.mk)

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MarkThemeABIProbe
MarkThemeABIProbe_FILES = Probe.m ../../iconservice/MTIconServiceABIDiagnostics.m
MarkThemeABIProbe_FRAMEWORKS = Foundation
MarkThemeABIProbe_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -I../../iconservice -DMARKTHEME_RUNTIME_BUILD_NUMBER=$(MARKTHEME_RUNTIME_BUILD_NUMBER)
# Introspection only; no hooking library is needed.
MarkThemeABIProbe_LIBRARIES =
# Never ship the old arm64e ABI in an iOS 17+ system daemon.
MarkThemeABIProbe_LDFLAGS = -Wl,-fatal_warnings

include $(THEOS_MAKE_PATH)/tweak.mk
