import Foundation

func readPlist(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
}

let root = FileManager.default.currentDirectoryPath
let page = try readPlist(root + "/RainbowKeyboardPrefs/Resources/RainbowKeyboard.plist")
let items = page["items"] as! [[String: Any]]
let keys = items.compactMap { $0["key"] as? String }
let legacyKeys: Set<String> = [
    "Enabled", "EffectStyle", "BackgroundDuration", "Brightness",
    "Opacity", "RippleEnabled", "NativeKeyboard", "WeChatKeyboard"
]
precondition(legacyKeys.isSubset(of: Set(keys)), "A legacy setting was lost")
precondition(Set(keys).count == keys.count, "Duplicate controls in the merged page")
let saturation = items.first { $0["key"] as? String == "NeonSaturation" }!
precondition(saturation["min"] as? Double == 0 && saturation["max"] as? Double == 1)
precondition(saturation["default"] as? Double == 0.72)
precondition(items.filter { $0["key"] as? String == "Brightness" }.count == 1)
let styles = items.first { $0["key"] as? String == "EffectStyle" }!
precondition(styles["validValues"] as? [Int] == [0, 1, 2], "Keep both old styles and the new neon press style")
precondition((styles["validTitles"] as? [String])?.last == "霓虹键帽 · 轻弹")
let sliderKeys = Set(items.filter { $0["cell"] as? String == "PSSliderCell" }.compactMap { $0["key"] as? String })
let help = try readPlist(root + "/RainbowKeyboardPrefs/Resources/SliderHelp.plist")
precondition(Set(help.keys) == sliderKeys && sliderKeys.count == 15, "Every slider needs its own explanation")
let pressMode = items.first { $0["key"] as? String == "PressColorMode" }!
precondition(pressMode["validValues"] as? [Int] == [0, 1])
precondition(pressMode["cell"] as? String == "PSSegmentCell")
let pressBrightness = items.first { $0["key"] as? String == "PressBrightness" }!
precondition(pressBrightness["default"] as? Double == 1 &&
             pressBrightness["min"] as? Double == 0 && pressBrightness["max"] as? Double == 1)
precondition(help.values.allSatisfy { (($0 as? String)?.count ?? 0) > 20 })
for (index, item) in items.enumerated() where item["cell"] as? String == "PSSliderCell" {
    let key = item["key"] as! String
    precondition(index > 0 && items[index - 1]["cell"] as? String == "PSGroupCell",
                 "\(key) must have a declarative group before loading")
    precondition(items[index - 1]["footerText"] as? String == help[key] as? String,
                 "\(key) help must remain complete and match the packaged reference")
    precondition((items[index - 1]["label"] as? String)?.contains(item["label"] as! String) == true)
    precondition(index + 1 == items.count || items[index + 1]["cell"] as? String == "PSGroupCell",
                 "\(key) footer must be directly below its slider")
}
for (key, action) in [("KeyboardBackgroundColor", "chooseKeyboardBackground"), ("KeycapColor", "chooseKeycapColor"),
                      ("PressColor", "choosePressColor")] {
    let color = items.first { $0["colorKey"] as? String == key }!
    precondition(color["action"] as? String == action)
    precondition(color["cellClass"] == nil && color["key"] == nil && color["default"] == nil)
    precondition(color["cell"] as? String == "PSButtonCell")
}
let entry = try readPlist(root + "/RainbowKeyboardPrefs/Resources/RainbowKeyboardPrefs.plist")
precondition((entry["entry"] as! [String: Any])["detail"] as? String == "RKBRootListController")
let info = try readPlist(root + "/RainbowKeyboardPrefs/Resources/Info.plist")
precondition(info["NSPrincipalClass"] as? String == "RKBRootListController",
             "A multi-controller bundle must explicitly select the settings root")
precondition(!FileManager.default.fileExists(atPath:
    root + "/layout/Library/PreferenceLoader/Preferences/RainbowKeyboard/RainbowKeyboard.plist"))

if CommandLine.arguments.count > 1 {
    let staged = URL(fileURLWithPath: CommandLine.arguments[1])
    let files = FileManager.default.enumerator(at: staged, includingPropertiesForKeys: nil)!
    let allFiles = files.compactMap { $0 as? URL }
    let entries = allFiles.filter {
        $0.path.contains("/PreferenceLoader/Preferences/") && $0.pathExtension == "plist"
    }
    precondition(entries.count == 1, "The package must contain exactly one Settings entry")
    precondition(entries[0].lastPathComponent == "com.minis.rainbowkeyboard.prefs.plist")
    let bundleInfos = allFiles.filter { $0.path.hasSuffix("/RainbowKeyboardPrefs.bundle/Info.plist") }
    precondition(bundleInfos.count == 1)
    let packagedInfo = try readPlist(bundleInfos[0].path)
    precondition(packagedInfo["NSPrincipalClass"] as? String == "RKBRootListController",
                 "The packaged bundle must retain the explicit principal class")
}
print("PASS: all 8 legacy settings retained, no duplicate controls, concentration and brightness available, one Settings entry")
