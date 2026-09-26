#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "../RKPreferences.h"

static NSString * const kRKChangedNotification = @"com.minis.rainbowkeyboard.changed";

static NSDictionary *RKReadPreferences(void) {
    return RKReadStoredPreferences() ?: @{};
}

static void RKSaveAndNotify(NSMutableDictionary *values) {
    if (!values) return;
    uint64_t revision = RKPreferencesRevision(values) + 1;
    values[@"RKSettingsRevision"] = @(revision);
    if (!RKSavePreferences(values)) return;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          (__bridge CFStringRef)kRKChangedNotification,
                                          NULL, NULL, YES);
}

static void RKApplyPerformancePreset(NSMutableDictionary *values, NSInteger mode) {
    NSArray *profiles = @[
        // 省电
        @{@"Opacity":@0.42, @"Brightness":@0.80, @"Duration":@0.42,
          @"Spread":@1.50, @"Softness":@10, @"CoreStrength":@0.32,
          @"MaxEffects":@2, @"BackgroundFeedback":@NO, @"AmbientGlow":@NO,
          @"BackgroundStrength":@0.10},
        // 平衡
        @{@"Opacity":@0.65, @"Brightness":@0.95, @"Duration":@0.55,
          @"Spread":@2.00, @"Softness":@8, @"CoreStrength":@0.50,
          @"MaxEffects":@4, @"BackgroundFeedback":@YES, @"AmbientGlow":@YES,
          @"BackgroundStrength":@0.18},
        // 极致
        @{@"Opacity":@0.78, @"Brightness":@1.00, @"Duration":@0.45,
          @"Spread":@2.25, @"Softness":@7, @"CoreStrength":@0.62,
          @"MaxEffects":@6, @"BackgroundFeedback":@YES, @"AmbientGlow":@YES,
          @"BackgroundStrength":@0.24}
    ];
    if (mode >= 0 && mode < (NSInteger)profiles.count) {
        [values addEntriesFromDictionary:profiles[mode]];
        values[@"PerformanceMode"] = @(mode);
        values[@"Preset"] = @(mode);
    }
}

@interface RKBAdvancedListController : PSListController <UIColorPickerViewControllerDelegate>
@property(nonatomic, copy) NSString *editingColorKey;
@end

@interface RKBRootListController : PSListController <UIColorPickerViewControllerDelegate>
@property(nonatomic, copy) NSString *editingColorKey;
@end

@interface RKBCandidateListController : RKBRootListController
@end

@implementation RKBRootListController

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"RainbowKeyboard" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"彩虹键盘光效";
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSDictionary *values = RKReadPreferences();
    id value = key ? values[key] : nil;
    return value ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key || !value) return;

    NSMutableDictionary *values = [RKReadPreferences() mutableCopy] ?: [NSMutableDictionary dictionary];
    NSInteger number = [value integerValue];

    if ([key isEqualToString:@"PerformanceMode"]) {
        RKApplyPerformancePreset(values, number);
    } else if ([key isEqualToString:@"EffectStyle"] || [key isEqualToString:@"ColorMode"]) {
        values[key] = value;
        values[@"Theme"] = @0;
        values[@"Preset"] = @(-1);
    } else if ([key isEqualToString:@"Enabled"] || [key isEqualToString:@"CandidateGradient"]) {
        values[key] = @([value boolValue]);
    } else {
        values[key] = value;
    }

    RKSaveAndNotify(values);
    [self reloadSpecifiers];
}

- (void)saveSimpleValue:(id)value forKey:(NSString *)key {
    if (!key || !value) return;
    NSMutableDictionary *values = [RKReadPreferences() mutableCopy] ?: [NSMutableDictionary dictionary];
    values[key] = value;
    values[@"Preset"] = @(-1);
    RKSaveAndNotify(values);
    [self reloadSpecifiers];
}

- (void)chooseSimpleOptionForKey:(NSString *)key
                           title:(NSString *)title
                         options:(NSArray<NSString *> *)options
                          values:(NSArray<NSNumber *> *)values {
    NSInteger current = [RKReadPreferences()[key] integerValue];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:nil
                                                              preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < options.count && i < values.count; i++) {
        NSString *option = options[i];
        NSNumber *optionValue = values[i];
        NSString *buttonTitle = [optionValue integerValue] == current ? [NSString stringWithFormat:@"✓ %@", option] : option;
        [alert addAction:[UIAlertAction actionWithTitle:buttonTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self saveSimpleValue:optionValue forKey:key];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)chooseTheme {
    NSArray *titles = @[@"自定义", @"🌌 深空", @"💜 极夜紫", @"💙 赛博蓝", @"❤️ 赤焰", @"💚 极光", @"🌈 Rainbow", @"🧊 冰晶", @"🟣 Neon", @"⚡ Cyberpunk"];
    NSMutableArray *values = [NSMutableArray array];
    for (NSInteger i=0;i<(NSInteger)titles.count;i++) [values addObject:@(i)];
    [self chooseSimpleOptionForKey:@"Theme" title:@"键盘主题" options:titles values:values];
}
- (void)chooseCandidateGradientMode {
    [self chooseSimpleOptionForKey:@"CandidateGradientMode" title:@"候选栏渐变" options:@[@"关闭", @"静态渐变", @"流动渐变", @"呼吸渐变", @"彩虹渐变", @"跟随输入"] values:@[@0,@1,@2,@3,@4,@5]];
}

- (void)chooseEffectStyle {
    [self chooseSimpleOptionForKey:@"EffectStyle"
                             title:@"光效风格"
                           options:@[@"波纹", @"扩散", @"轻弹", @"流光底韵"]
                            values:@[@0, @1, @2, @3]];
}

- (void)chooseColorMode {
    [self chooseSimpleOptionForKey:@"ColorMode"
                             title:@"光效颜色"
                           options:@[@"彩虹", @"固定颜色", @"横向渐变"]
                            values:@[@0, @1, @2]];
}

- (void)choosePerformanceMode {
    NSInteger current = [RKReadPreferences()[@"PerformanceMode"] integerValue];
    if (!RKReadPreferences()[@"PerformanceMode"]) current = 1;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"性能模式"
                                                                     message:@"选择后会自动调整光效数量、持续时间和背景效果。"
                                                              preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *titles = @[@"省电", @"平衡", @"高性能"];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        NSString *name = titles[i];
        NSString *buttonTitle = i == current ? [NSString stringWithFormat:@"✓ %@", name] : name;
        [alert addAction:[UIAlertAction actionWithTitle:buttonTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSMutableDictionary *values = [RKReadPreferences() mutableCopy] ?: [NSMutableDictionary dictionary];
            RKApplyPerformancePreset(values, i);
            RKSaveAndNotify(values);
            [self reloadSpecifiers];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:@"Theme"]) {
        NSArray *titles = @[@"自定义", @"🌌 深空", @"💜 极夜紫", @"💙 赛博蓝", @"❤️ 赤焰", @"💚 极光", @"🌈 Rainbow", @"🧊 冰晶", @"🟣 Neon", @"⚡ Cyberpunk"];
        NSInteger value = [RKReadPreferences()[key] integerValue];
        cell.detailTextLabel.text = (value >= 0 && value < (NSInteger)titles.count) ? titles[value] : @"自定义";
    } else if ([key isEqualToString:@"CandidateGradientMode"]) {
        NSArray *titles = @[@"关闭", @"静态渐变", @"流动渐变", @"呼吸渐变", @"彩虹渐变", @"跟随输入"];
        NSInteger value = [RKReadPreferences()[key] integerValue];
        cell.detailTextLabel.text = (value >= 0 && value < (NSInteger)titles.count) ? titles[value] : @"静态渐变";
    } else if ([key isEqualToString:@"EffectStyle"]) {
        NSArray *titles = @[@"波纹", @"扩散", @"轻弹", @"流光底韵"];
        NSInteger value = [RKReadPreferences()[key] integerValue];
        cell.detailTextLabel.text = (value >= 0 && value < (NSInteger)titles.count) ? titles[value] : @"波纹";
    } else if ([key isEqualToString:@"ColorMode"]) {
        NSArray *titles = @[@"彩虹", @"固定颜色", @"横向渐变"];
        NSInteger value = [RKReadPreferences()[key] integerValue];
        cell.detailTextLabel.text = (value >= 0 && value < (NSInteger)titles.count) ? titles[value] : @"彩虹";
    } else if ([key isEqualToString:@"PerformanceMode"]) {
        NSArray *titles = @[@"省电", @"平衡", @"高性能"];
        NSInteger value = [RKReadPreferences()[key] integerValue];
        if (!RKReadPreferences()[key]) value = 1;
        cell.detailTextLabel.text = (value >= 0 && value < (NSInteger)titles.count) ? titles[value] : @"平衡";
    }
    return cell;
}


- (void)chooseCandidateColor:(NSString *)key {
    self.editingColorKey = key;
    UIColorPickerViewController *picker = [UIColorPickerViewController new];
    picker.delegate = self;
    picker.supportsAlpha = NO;

    NSDictionary *titles = @{
        @"CandidateStart": @"候选词起始颜色",
        @"CandidateEnd": @"候选词结束颜色"
    };
    picker.title = titles[key];

    id rgb = RKReadPreferences()[key];
    if ([rgb isKindOfClass:NSArray.class] && [rgb count] == 3) {
        picker.selectedColor = [UIColor colorWithRed:[rgb[0] doubleValue]
                                                 green:[rgb[1] doubleValue]
                                                  blue:[rgb[2] doubleValue]
                                                 alpha:1.0];
    }
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)chooseCandidateStart { [self chooseCandidateColor:@"CandidateStart"]; }
- (void)chooseCandidateEnd { [self chooseCandidateColor:@"CandidateEnd"]; }

- (void)saveCandidatePickerColor:(UIColor *)color {
    if (!color || !self.editingColorKey.length) return;
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) return;

    NSMutableDictionary *values = [RKReadPreferences() mutableCopy] ?: [NSMutableDictionary dictionary];
    values[self.editingColorKey] = @[@(r), @(g), @(b)];
    values[@"Preset"] = @(-1);
    RKSaveAndNotify(values);
}

- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)picker {
    [self saveCandidatePickerColor:picker.selectedColor];
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)picker {
    [self saveCandidatePickerColor:picker.selectedColor];
    self.editingColorKey = nil;
    [self reloadSpecifiers];
}

- (void)showCandidateSettings {
    RKBCandidateListController *controller = [RKBCandidateListController new];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)showAdvanced {
    RKBAdvancedListController *controller = [RKBAdvancedListController new];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)resetToDefaults {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"恢复默认设置"
                                                                    message:@"只恢复彩虹键盘的设置，不会删除插件。"
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"恢复默认" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSString *path = [[NSBundle bundleForClass:self.class] pathForResource:@"defaults" ofType:@"plist"];
        NSDictionary *defaults = path.length ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
        NSMutableDictionary *values = defaults ? [defaults mutableCopy] : [NSMutableDictionary dictionary];
        RKSaveAndNotify(values);
        [self reloadSpecifiers];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

@implementation RKBAdvancedListController

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *loaded = [[self loadSpecifiersFromPlistName:@"RainbowKeyboardAdvanced" target:self] mutableCopy];
        NSIndexSet *remove = [loaded indexesOfObjectsPassingTest:^BOOL(PSSpecifier *specifier, NSUInteger idx, BOOL *stop) {
            NSString *key = [specifier propertyForKey:@"key"];
            return [key isEqualToString:@"CandidateStart"] || [key isEqualToString:@"CandidateEnd"];
        }];
        if (remove.count) [loaded removeObjectsAtIndexes:remove];
        _specifiers = loaded;
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"高级设置";
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSDictionary *values = RKReadPreferences();
    return (key ? values[key] : nil) ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key || !value) return;
    NSMutableDictionary *values = [RKReadPreferences() mutableCopy] ?: [NSMutableDictionary dictionary];
    values[key] = value;
    values[@"Preset"] = @(-1);
    RKSaveAndNotify(values);
    [self reloadSpecifiers];
}

- (void)chooseColor:(NSString *)key {
    self.editingColorKey = key;
    UIColorPickerViewController *picker = [UIColorPickerViewController new];
    picker.delegate = self;
    picker.supportsAlpha = NO;

    NSDictionary *titles = @{
        @"CandidateStart": @"候选词起始颜色",
        @"CandidateEnd": @"候选词结束颜色",
        @"KeyboardBackgroundColor": @"键盘底色",
        @"KeycapColor": @"键帽颜色",
        @"PressColor": @"单色灯光颜色"
    };
    picker.title = titles[key];

    id rgb = RKReadPreferences()[key];
    if ([rgb isKindOfClass:NSArray.class] && [rgb count] == 3) {
        picker.selectedColor = [UIColor colorWithRed:[rgb[0] doubleValue]
                                                 green:[rgb[1] doubleValue]
                                                  blue:[rgb[2] doubleValue]
                                                 alpha:1.0];
    }
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)chooseKeyboardBackground { [self chooseColor:@"KeyboardBackgroundColor"]; }
- (void)chooseKeycapColor { [self chooseColor:@"KeycapColor"]; }
- (void)choosePressColor { [self chooseColor:@"PressColor"]; }

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)picker {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![picker.selectedColor getRed:&r green:&g blue:&b alpha:&a]) return;

    NSString *key = self.editingColorKey;
    self.editingColorKey = nil;

    NSMutableDictionary *values = [RKReadPreferences() mutableCopy] ?: [NSMutableDictionary dictionary];
    values[key] = @[@(r), @(g), @(b)];
    values[@"Preset"] = @(-1);
    RKSaveAndNotify(values);
    [self reloadSpecifiers];
}

- (void)showPackageInfo { /* 关于页已移除 */ }
@end


@implementation RKBCandidateListController

// Route only these three action rows ourselves. Other preference cells retain
// PSListController's normal switch/slider behavior.
- (BOOL)isCandidateActionSpecifier:(PSSpecifier *)specifier {
    NSString *identifier = [specifier propertyForKey:@"id"];
    return [identifier isEqualToString:@"candidate.mode"] ||
           [identifier isEqualToString:@"candidate.start"] ||
           [identifier isEqualToString:@"candidate.end"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    if (![self isCandidateActionSpecifier:specifier]) {
        return [super tableView:tableView cellForRowAtIndexPath:indexPath];
    }
    // Use a normal UIKit cell so private Preferences link-cell validation
    // cannot disable a row with no detail controller.
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"RKCandidateAction"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                    reuseIdentifier:@"RKCandidateAction"];
    }
    NSString *identifier = [specifier propertyForKey:@"id"];
    BOOL isMode = [identifier isEqualToString:@"candidate.mode"];
    cell.textLabel.text = isMode ? @"渐变模式" :
        ([identifier isEqualToString:@"candidate.start"] ? @"起始颜色" : @"结束颜色");
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.textLabel.enabled = YES;
    cell.detailTextLabel.enabled = YES;
    cell.userInteractionEnabled = YES;
    cell.contentView.userInteractionEnabled = YES;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    cell.detailTextLabel.text = nil;
    if (isMode) {
        NSArray *titles = @[@"关闭", @"静态渐变", @"流动渐变", @"呼吸渐变", @"彩虹渐变", @"跟随输入"];
        id saved = RKReadPreferences()[@"CandidateGradientMode"];
        NSInteger value = saved ? [saved integerValue] : 1;
        cell.detailTextLabel.text = (value >= 0 && value < (NSInteger)titles.count) ? titles[value] : titles[1];
    }
    return cell;
}

- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self isCandidateActionSpecifier:[self specifierAtIndexPath:indexPath]]) return indexPath;
    return [super tableView:tableView willSelectRowAtIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    if (![self isCandidateActionSpecifier:specifier]) {
        [super tableView:tableView didSelectRowAtIndexPath:indexPath];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.presentedViewController) return;
    NSString *identifier = [specifier propertyForKey:@"id"];
    if ([identifier isEqualToString:@"candidate.mode"]) [self chooseCandidateGradientMode];
    else if ([identifier isEqualToString:@"candidate.start"]) [self chooseCandidateStart];
    else if ([identifier isEqualToString:@"candidate.end"]) [self chooseCandidateEnd];
}

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *items = [NSMutableArray array];

        PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"候选词渐变"
                                                               target:self
                                                                  set:nil
                                                                  get:nil
                                                               detail:nil
                                                                 cell:PSGroupCell
                                                                 edit:nil];
        [items addObject:group];

        PSSpecifier *enabled = [PSSpecifier preferenceSpecifierNamed:@"启用候选词渐变"
                                                                target:self
                                                                   set:@selector(setPreferenceValue:specifier:)
                                                                   get:@selector(readPreferenceValue:)
                                                                detail:nil
                                                                  cell:PSSwitchCell
                                                                  edit:nil];
        [enabled setProperty:@"CandidateGradient" forKey:@"key"];
        [enabled setProperty:@YES forKey:@"default"];
        [enabled setProperty:@"com.minis.rainbowkeyboard" forKey:@"defaults"];
        [enabled setProperty:kRKChangedNotification forKey:@"PostNotification"];
        [items addObject:enabled];

        PSSpecifier *mode = [PSSpecifier preferenceSpecifierNamed:@"渐变模式"
                                                            target:self
                                                               set:nil
                                                               get:nil
                                                            detail:nil
                                                              cell:PSButtonCell
                                                              edit:nil];
        [mode setProperty:@"CandidateGradientMode" forKey:@"key"];
        [mode setProperty:@"candidate.mode" forKey:@"id"];
        [mode setProperty:@YES forKey:@"enabled"];
        [mode setButtonAction:@selector(chooseCandidateGradientMode)];
        [items addObject:mode];

        PSSpecifier *colorGroup = [PSSpecifier preferenceSpecifierNamed:@"候选词颜色"
                                                                  target:self
                                                                     set:nil
                                                                     get:nil
                                                                  detail:nil
                                                                    cell:PSGroupCell
                                                                    edit:nil];
        [items addObject:colorGroup];

        PSSpecifier *start = [PSSpecifier preferenceSpecifierNamed:@"起始颜色"
                                                             target:self
                                                                set:nil
                                                                get:nil
                                                             detail:nil
                                                               cell:PSButtonCell
                                                               edit:nil];
        [start setProperty:@"candidate.start" forKey:@"id"];
        [start setProperty:@YES forKey:@"enabled"];
        [start setButtonAction:@selector(chooseCandidateStart)];
        [items addObject:start];

        PSSpecifier *end = [PSSpecifier preferenceSpecifierNamed:@"结束颜色"
                                                           target:self
                                                              set:nil
                                                              get:nil
                                                           detail:nil
                                                             cell:PSButtonCell
                                                             edit:nil];
        [end setProperty:@"candidate.end" forKey:@"id"];
        [end setProperty:@YES forKey:@"enabled"];
        [end setButtonAction:@selector(chooseCandidateEnd)];
        [items addObject:end];

        PSSpecifier *inputGroup = [PSSpecifier preferenceSpecifierNamed:@"输入法"
                                                                   target:self
                                                                      set:nil
                                                                      get:nil
                                                                   detail:nil
                                                                     cell:PSGroupCell
                                                                     edit:nil];
        [items addObject:inputGroup];

        PSSpecifier *native = [PSSpecifier preferenceSpecifierNamed:@"原生候选栏"
                                                               target:self
                                                                  set:@selector(setPreferenceValue:specifier:)
                                                                  get:@selector(readPreferenceValue:)
                                                               detail:nil
                                                                 cell:PSSwitchCell
                                                                 edit:nil];
        [native setProperty:@"CandidateNative" forKey:@"key"];
        [native setProperty:@YES forKey:@"default"];
        [items addObject:native];

        PSSpecifier *wetype = [PSSpecifier preferenceSpecifierNamed:@"WeType 候选栏"
                                                               target:self
                                                                  set:@selector(setPreferenceValue:specifier:)
                                                                  get:@selector(readPreferenceValue:)
                                                               detail:nil
                                                                 cell:PSSwitchCell
                                                                 edit:nil];
        [wetype setProperty:@"CandidateWeType" forKey:@"key"];
        [wetype setProperty:@YES forKey:@"default"];
        [items addObject:wetype];

        PSSpecifier *animationGroup = [PSSpecifier preferenceSpecifierNamed:@"动画"
                                                                       target:self
                                                                          set:nil
                                                                          get:nil
                                                                       detail:nil
                                                                         cell:PSGroupCell
                                                                         edit:nil];
        [items addObject:animationGroup];

        PSSpecifier *speed = [PSSpecifier preferenceSpecifierNamed:@"动画速度"
                                                              target:self
                                                                 set:@selector(setPreferenceValue:specifier:)
                                                                 get:@selector(readPreferenceValue:)
                                                              detail:nil
                                                                cell:PSSliderCell
                                                                edit:nil];
        [speed setProperty:@"CandidateGradientSpeed" forKey:@"key"];
        [speed setProperty:@0.5 forKey:@"default"];
        [speed setProperty:@0.05 forKey:@"min"];
        [speed setProperty:@2.0 forKey:@"max"];
        [speed setProperty:@YES forKey:@"showValue"];
        [items addObject:speed];

        _specifiers = items;
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"候选栏渐变";
}

@end
