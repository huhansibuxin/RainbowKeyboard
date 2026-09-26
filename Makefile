TARGET := iphone:clang:latest:15.0
# A12+ devices (e.g. iPhone 14 Pro Max / A16) run Settings as an arm64e process;
# an arm64-only PreferenceBundle is rejected by dlopen_preflight with
# "incompatible architecture (have 'arm64', need 'arm64e')". Build arm64e.
ARCHS ?= arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := RainbowKeyboard
RainbowKeyboard_FILES := RKKeyboardHooks.xm Tweak.xm RainbowEffectView.m RKNeonPress.m RKThemeEngine.m RKKeyboardGeometry.m CandidateGradient.xm
# -Oz overrides Theos' default -Os (user CFLAGS are appended after OPTFLAG), and
# -dead_strip drops unreferenced code/data to keep the injected __TEXT segment small.
RainbowKeyboard_CFLAGS := -fobjc-arc -Wno-deprecated-declarations -Oz
RainbowKeyboard_LDFLAGS := -Wl,-dead_strip
RainbowKeyboard_FRAMEWORKS := UIKit QuartzCore CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += RainbowKeyboardPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-stage::
	$(ECHO_NOTHING)find "$(THEOS_STAGING_DIR)" -type f -name '*.plist' -exec chmod 644 {} \;$(ECHO_END)
	$(ECHO_NOTHING)find "$(THEOS_STAGING_DIR)" \( -name '._*' -o -name '.DS_Store' \) -delete$(ECHO_END)
	$(ECHO_NOTHING)find "$(THEOS_STAGING_DIR)" -type f -size 1c -name '1' -delete$(ECHO_END)
	$(ECHO_NOTHING)find "$(THEOS_STAGING_DIR)" \( -name '*.dylib' -o -path '*.bundle/*' \) -type f ! -name '*.plist' ! -name '*.png' ! -name '*.json' ! -name '*.strings' -exec ldid -S {} \;$(ECHO_END)
