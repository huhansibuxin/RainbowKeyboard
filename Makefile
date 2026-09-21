TARGET := iphone:clang:latest:15.0
ARCHS ?= arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := RainbowKeyboard
RainbowKeyboard_FILES := Tweak.xm RainbowEffectView.m RKNeonPress.m RKKeyboardGeometry.m RKBlackBitmap.m CandidateGradient.xm PureBlackKeyboard.xm
RainbowKeyboard_CFLAGS := -fobjc-arc -Wno-deprecated-declarations
RainbowKeyboard_FRAMEWORKS := UIKit QuartzCore CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += RainbowKeyboardPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-stage::
	$(ECHO_NOTHING)find "$(THEOS_STAGING_DIR)" -type f -name '*.plist' -exec chmod 644 {} \;$(ECHO_END)
	$(ECHO_NOTHING)find "$(THEOS_STAGING_DIR)" \( -name '._*' -o -name '.DS_Store' \) -delete$(ECHO_END)
	$(ECHO_NOTHING)find "$(THEOS_STAGING_DIR)" -type f -size 1c -name '1' -delete$(ECHO_END)
