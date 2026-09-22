#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "../RKPreferences.h"
static NSDictionary *RKReadPreferences(void) {
    return RKReadStoredPreferences();
}
static NSBundle *RKPrefsBundle(void) {
    static NSBundle *b;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ b = [NSBundle bundleForClass:NSClassFromString(@"RKBRootListController")]; });
    return b ?: [NSBundle mainBundle];
}
static NSString *RKLoc(NSString *key) {
    return [RKPrefsBundle() localizedStringForKey:key value:key table:@"RainbowKeyboard"];
}
// The exact key set a preset writes. Presets overwrite these in place, so the
// same list defines what "自定义" has to be able to put back afterwards.
static NSArray<NSString *> *RKEffectParameterKeys(void) {
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"Opacity", @"Brightness", @"NeonSaturation", @"Duration", @"Spread",
            @"Softness", @"CoreStrength", @"MaxEffects", @"EffectStyle", @"AmbientGlow",
            @"AmbientStrength", @"ColorMode", @"BackgroundFeedback",
            @"BackgroundStrength", @"BackgroundDuration",
            @"BackgroundRadius", @"BackgroundBand",
            @"Hue", @"PressBrightness"];
    });
    return keys;
}
// A preset's number is persisted in the plist, so a new preset must take a fresh
// number instead of shifting the existing ones: 自用 is 4 while 柔和/鲜艳/快速/推荐 keep
// 0..3. Display order comes from the plist's validValues array -- that is what places
// 自用 ahead of 柔和水波 without rewriting anybody's saved selection.
enum { RKPresetValueSelfUse = 4 };
static NSDictionary *RKPresetTable(NSInteger preset) {
    static NSDictionary *tables[RKPresetValueSelfUse + 1];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tables[0] = @{@"Opacity":@.4,@"Brightness":@.8,@"NeonSaturation":@.4,@"Duration":@.6,@"Spread":@1.5,@"Softness":@10,@"CoreStrength":@.3,@"MaxEffects":@3};
        tables[1] = @{@"Opacity":@.75,@"Brightness":@1,@"NeonSaturation":@1,@"Duration":@.55,@"Spread":@2.2,@"Softness":@8,@"CoreStrength":@.65,@"MaxEffects":@4};
        tables[2] = @{@"Opacity":@.6,@"Brightness":@.95,@"NeonSaturation":@.72,@"Duration":@.25,@"Spread":@1.3,@"Softness":@5,@"CoreStrength":@.6,@"MaxEffects":@3};
        tables[3] = @{@"Opacity":@.65,@"Brightness":@.95,@"NeonSaturation":@.72,@"Duration":@.55,@"Spread":@2,@"Softness":@8,@"CoreStrength":@.5,@"MaxEffects":@4};
        // 自用 is the shared frozen tuning (RKPresetSelfUseTable) -- the very same table the
        // renderer falls back on, so the preset and the no-configuration look cannot drift.
        tables[RKPresetValueSelfUse] = RKPresetSelfUseTable();
    });
    return (preset >= 0 && preset <= RKPresetValueSelfUse) ? tables[preset] : nil;
}
// Keys every preset also forces, so a preset always lands on 三星风格扩散.
static NSDictionary *RKPresetBase(void) {
    static NSDictionary *base;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        base = @{@"EffectStyle":@0, @"AmbientGlow":@YES, @"AmbientStrength":@.85,
            @"ColorMode":@0, @"BackgroundFeedback":@YES,
            @"BackgroundStrength":@.18, @"BackgroundDuration":@.4};
    });
    return base;
}
// "自定义" is not a preset table -- it is the user's own last manual numbers. The
// preset writes the very same keys in place, so without this backup it destroys
// them and picking 自定义 afterwards changes nothing but the label. Kept out of
// RKDisplayKeys() on purpose: the display wire format is positional and this is
// a dictionary, so registering it would shift every later bit.
static void RKSnapshotCustomParameters(NSMutableDictionary *values) {
    NSMutableDictionary *custom = [NSMutableDictionary dictionary];
    for (NSString *key in RKEffectParameterKeys()) if (values[key]) custom[key] = values[key];
    if (custom.count) values[@"CustomParams"] = custom;
}
static void RKRestoreCustomParameters(NSMutableDictionary *values) {
    id stored = values[@"CustomParams"];
    if (![stored isKindOfClass:NSDictionary.class]) return;
    NSDictionary *custom = stored;
    for (NSString *key in RKEffectParameterKeys()) if (custom[key]) values[key] = custom[key];
}
@interface RKBRootListController : PSListController <UIColorPickerViewControllerDelegate>
@property(nonatomic,copy) NSString *editingColorKey;
@end
@implementation RKBRootListController
- (NSMutableArray *)specifiers {
    // Keep the loader's mutable list and section metadata together.
    // Slider titles and footers are declared in the plist, before loading.
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"RainbowKeyboard" target:self];
    return _specifiers;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = RKLoc(@"彩虹键盘光效");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSString *key = [specifier propertyForKey:@"colorKey"];
    if ([key isKindOfClass:NSString.class]) {
        UIView *swatch = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, 24)];
        swatch.backgroundColor = RKKeyboardColor(RKReadPreferences(), key);
        swatch.layer.cornerRadius = 4;
        swatch.layer.borderWidth = 1;
        swatch.layer.borderColor = UIColor.separatorColor.CGColor;
        swatch.tag = 0x524B;
        cell.accessoryView = swatch;
    } else if (cell.accessoryView.tag == 0x524B) cell.accessoryView = nil;
    return cell;
}
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSDictionary *values = RKReadPreferences();
    if (key && values[key]) return values[key];
    // With nothing stored the renderer uses the frozen 自用 tuning, so the page shows that
    // number rather than the plist literal -- display and behaviour stay the same value.
    NSNumber *selfUse = key ? RKPresetSelfUseTable()[key] : nil;
    return selfUse ?: [specifier propertyForKey:@"default"];
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key || !value) return;
    NSMutableDictionary *values = [RKReadPreferences() mutableCopy];
    // Read the outgoing preset before the new value lands: a preset may only
    // replace the backup when the state it overwrites really is 自定义.
    BOOL wasCustom = [values[@"Preset"] integerValue] == -1;
    values[key] = value;
    if ([key isEqualToString:@"Preset"]) {
        NSInteger preset = [value integerValue];
        NSDictionary *table = RKPresetTable(preset);
        if (table) {
            // A fresh install has no backup yet; seed one from the current
            // (default) numbers so 自定义 still has something to return to.
            if (wasCustom || !values[@"CustomParams"]) RKSnapshotCustomParameters(values);
            [values addEntriesFromDictionary:RKPresetBase()];
            [values addEntriesFromDictionary:table];
        } else if (preset == -1) {
            RKRestoreCustomParameters(values);
        }
    } else {
        values[@"Preset"] = @(-1);
        RKSnapshotCustomParameters(values);
    }
    if (!RKSavePreferences(values)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:RKLoc(@"保存失败") message:RKLoc(@"配置文件未写入，请检查偏好设置目录权限。") preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:RKLoc(@"知道了") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self reloadSpecifiers];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.minis.rainbowkeyboard.changed"), NULL, NULL, YES);
}

- (void)chooseCandidateStart { [self openCandidatePicker:@"CandidateStart"]; }
- (void)chooseCandidateEnd { [self openCandidatePicker:@"CandidateEnd"]; }
- (void)openCandidatePicker:(NSString *)key {
    self.editingColorKey = key;
    UIColorPickerViewController *picker = [UIColorPickerViewController new];
    picker.delegate = self;
    picker.supportsAlpha = NO;
    picker.title = @{@"CandidateStart":RKLoc(@"候选词起始颜色"),
        @"CandidateEnd":RKLoc(@"候选词结束颜色")}[key];
    NSDictionary *values = RKReadPreferences();
    id rgb = values[key];
    if ([rgb isKindOfClass:NSArray.class] && [rgb count] == 3 &&
        [rgb[0] isKindOfClass:NSNumber.class] && [rgb[1] isKindOfClass:NSNumber.class] && [rgb[2] isKindOfClass:NSNumber.class]) {
        picker.selectedColor = [UIColor colorWithRed:[rgb[0] doubleValue] green:[rgb[1] doubleValue] blue:[rgb[2] doubleValue] alpha:1];
    } else if ([key isEqualToString:@"CandidateStart"]) picker.selectedColor = [UIColor colorWithRed:0 green:.65 blue:1 alpha:1];
    else if ([key isEqualToString:@"CandidateEnd"]) picker.selectedColor = [UIColor colorWithRed:.85 green:.15 blue:1 alpha:1];
    else picker.selectedColor = UIColor.blackColor;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)picker {
    CGFloat r=0,g=0,b=0,a=1;
    NSString *key = self.editingColorKey;
    if (!key || ![picker.selectedColor getRed:&r green:&g blue:&b alpha:&a]) return;
    NSMutableDictionary *values = [RKReadPreferences() mutableCopy];
    values[key] = @[@(r),@(g),@(b)];
    BOOL saved = RKSavePreferences(values);
    self.editingColorKey = nil;
    [picker dismissViewControllerAnimated:YES completion:^{
        if (!saved) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:RKLoc(@"颜色保存失败") message:RKLoc(@"请检查配置文件权限。") preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:RKLoc(@"知道了") style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        } else {
            [self reloadSpecifiers];
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),CFSTR("com.minis.rainbowkeyboard.changed"),NULL,NULL,YES);
        }
    }];
}
@end
