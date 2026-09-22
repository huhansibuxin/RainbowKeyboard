#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "../RKBlackProbe.h"
#import "../RKPreferences.h"
static NSDictionary *RKReadPreferences(void) {
    return RKReadStoredPreferences();
}
static NSBundle *RKPrefsBundle(void) {
    static NSBundle *b;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ b = [NSBundle bundleForClass:NSClassFromString(@"RKBPackageInfoController")]; });
    return b ?: [NSBundle mainBundle];
}
static NSString *RKLoc(NSString *key) {
    return [RKPrefsBundle() localizedStringForKey:key value:key table:@"RainbowKeyboard"];
}
@interface RKBPackageInfoController : UIViewController
@end
@implementation RKBPackageInfoController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = RKLoc(@"关于与预览");
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSData *data = [NSData dataWithContentsOfFile:[bundle pathForResource:@"PackageInfo" ofType:@"json"]];
    NSDictionary *info = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 18;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]
    ]];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"PackageIcon"
        inBundle:bundle compatibleWithTraitCollection:nil]];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon.heightAnchor constraintEqualToConstant:88].active = YES;
    [stack addArrangedSubview:icon];
    void (^label)(NSString *, UIFontTextStyle, UIColor *) = ^(NSString *text, UIFontTextStyle style, UIColor *color) {
        UILabel *view = [UILabel new];
        view.text = text;
        view.numberOfLines = 0;
        view.font = [UIFont preferredFontForTextStyle:style];
        view.adjustsFontForContentSizeCategory = YES;
        view.textColor = color;
        [stack addArrangedSubview:view];
    };
    label(info[@"name"] ?: RKLoc(@"彩虹键盘光效"), UIFontTextStyleTitle2, UIColor.labelColor);
    label([NSString stringWithFormat:@"%@ · %@", info[@"version"] ?: @"", info[@"author"] ?: @"MoWang"],
        UIFontTextStyleFootnote, UIColor.secondaryLabelColor);
    label(info[@"summary"] ?: RKLoc(@"说明文件未找到，请重新安装完整安装包。"), UIFontTextStyleBody, UIColor.labelColor);
    for (NSDictionary *item in info[@"screenshots"]) {
        UIImage *image = [UIImage imageWithContentsOfFile:[bundle.resourcePath stringByAppendingPathComponent:item[@"file"]]];
        if (!image || image.size.width <= 0) continue;
        UIImageView *preview = [[UIImageView alloc] initWithImage:image];
        preview.contentMode = UIViewContentModeScaleAspectFit;
        preview.isAccessibilityElement = YES;
        preview.accessibilityLabel = item[@"title"];
        [preview.heightAnchor constraintEqualToAnchor:preview.widthAnchor multiplier:image.size.height / image.size.width].active = YES;
        [stack addArrangedSubview:preview];
    }
    for (NSDictionary *section in info[@"sections"]) {
        label(section[@"title"], UIFontTextStyleHeadline, UIColor.labelColor);
        label(section[@"body"], UIFontTextStyleBody, UIColor.secondaryLabelColor);
    }
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end
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
    return (key ? values[key] : nil) ?: [specifier propertyForKey:@"default"];
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key || !value) return;
    NSMutableDictionary *values = [RKReadPreferences() mutableCopy];
    values[key] = value;
    if ([key isEqualToString:@"Preset"]) {
        NSInteger preset = [value integerValue];
        NSArray *options = @[
            @{@"Opacity":@.4,@"Brightness":@.8,@"NeonSaturation":@.4,@"Duration":@.6,@"Spread":@1.5,@"Softness":@10,@"CoreStrength":@.3,@"MaxEffects":@3},
            @{@"Opacity":@.75,@"Brightness":@1,@"NeonSaturation":@1,@"Duration":@.55,@"Spread":@2.2,@"Softness":@8,@"CoreStrength":@.65,@"MaxEffects":@4},
            @{@"Opacity":@.6,@"Brightness":@.95,@"NeonSaturation":@.72,@"Duration":@.25,@"Spread":@1.3,@"Softness":@5,@"CoreStrength":@.6,@"MaxEffects":@3},
            @{@"Opacity":@.65,@"Brightness":@.95,@"NeonSaturation":@.72,@"Duration":@.55,@"Spread":@2,@"Softness":@8,@"CoreStrength":@.5,@"MaxEffects":@4}
        ];
        if (preset >= 0 && preset < (NSInteger)options.count) {
            [values addEntriesFromDictionary:options[preset]];
            values[@"EffectStyle"] = @0;
            values[@"AmbientGlow"] = @YES;
            values[@"AmbientStrength"] = @.85;
            values[@"PureBlackKeyboard"] = @YES;
            values[@"ColorMode"] = @0;
            values[@"BackgroundFeedback"] = @YES;
            values[@"BackgroundStrength"] = @.18;
            values[@"BackgroundDuration"] = @.4;
        }
    } else values[@"Preset"] = @(-1);
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
- (void)chooseKeyboardBackground { [self openCandidatePicker:@"KeyboardBackgroundColor"]; }
- (void)chooseKeycapColor { [self openCandidatePicker:@"KeycapColor"]; }
- (void)choosePressColor { [self openCandidatePicker:@"PressColor"]; }
- (void)showPackageInfo {
    RKBPackageInfoController *controller = [RKBPackageInfoController new];
    if (self.navigationController) [self.navigationController pushViewController:controller animated:YES];
    else {
        controller.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:controller action:@selector(close)];
        [self presentViewController:[[UINavigationController alloc] initWithRootViewController:controller] animated:YES completion:nil];
    }
}
- (void)copyBlackDiagnostic {
    NSDictionary *values = RKReadPreferences();
    NSDictionary *report = @{@"build":@"1.0.25~samsung17.1", @"systemVersion":UIDevice.currentDevice.systemVersion,
        @"preferenceSync":RKPreferencesDiagnostic(),
        @"native":RKReadBlackProbe(NO), @"weType":RKReadBlackProbe(YES),
        @"settings":@{@"revision":@(RKPreferencesRevision(values)),
            @"CandidateGradient":values[@"CandidateGradient"] ?: @YES,
            @"CandidateNative":values[@"CandidateNative"] ?: @YES,
            @"CandidateWeType":values[@"CandidateWeType"] ?: @YES}};
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    if (!data) return;
    UIPasteboard.generalPasteboard.string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:RKLoc(@"键帽诊断已复制")
        message:RKLoc(@"仅包含版本、接口状态和处理数量，不含输入文字或图片。") preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:RKLoc(@"好") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)chooseCandidateEnd { [self openCandidatePicker:@"CandidateEnd"]; }
- (void)openCandidatePicker:(NSString *)key {
    self.editingColorKey = key;
    UIColorPickerViewController *picker = [UIColorPickerViewController new];
    picker.delegate = self;
    picker.supportsAlpha = NO;
    picker.title = @{@"CandidateStart":RKLoc(@"候选词起始颜色"), @"CandidateEnd":RKLoc(@"候选词结束颜色"),
        @"KeyboardBackgroundColor":RKLoc(@"键盘底色"), @"KeycapColor":RKLoc(@"键帽颜色"), @"PressColor":RKLoc(@"霓虹键帽单色")}[key];
    NSDictionary *values = RKReadPreferences();
    id rgb = values[key];
    if ([rgb isKindOfClass:NSArray.class] && [rgb count] == 3 &&
        [rgb[0] isKindOfClass:NSNumber.class] && [rgb[1] isKindOfClass:NSNumber.class] && [rgb[2] isKindOfClass:NSNumber.class]) {
        picker.selectedColor = [UIColor colorWithRed:[rgb[0] doubleValue] green:[rgb[1] doubleValue] blue:[rgb[2] doubleValue] alpha:1];
    } else if ([key isEqualToString:@"CandidateStart"]) picker.selectedColor = [UIColor colorWithRed:0 green:.65 blue:1 alpha:1];
    else if ([key isEqualToString:@"CandidateEnd"]) picker.selectedColor = [UIColor colorWithRed:.85 green:.15 blue:1 alpha:1];
    else if ([key isEqualToString:@"PressColor"]) picker.selectedColor = RKKeyboardColor(values, key);
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
