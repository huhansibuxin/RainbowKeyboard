# 彩虹键盘光效：源发布资料

## 包含内容

- `assets/icon.png`：1024×1024 Sileo 图标原图。
- `assets/icon-256.png`：256×256 在线包图标。
- `assets/banner.png`：1600×800 横幅。
- `assets/preview-neon.png`、`preview-colors.png`：1080×1440 效果预览。
- `assets/brand-preview.png`：图标与预览汇总图。
- 安装包内已经带有设置图标、离线详情及两张预览。保留原作者 MoWang。

## 为什么需要源地址

Sileo 在安装前不能从 deb 内读取详情素材。`Icon`、`Depiction` 和 `SileoDepiction` 必须指向可访问的源网址。未配置源地址的基础 deb 不伪造在线展示链接。

预览使用插件在模拟器中的实际渲染，不是手机真机截图。详情说明与兼容性文字位于 `PackageInfo.json`，生成器统一从该文件生成 HTML 和 Sileo 原生 JSON。

## 生成上传目录

Mac 上可双击 `生成上传目录.command`，输入真实源根地址。生成后会自动校验哈希、展示链接与包内资源。也可使用下面的命令行方式。

系统需有 Python 3 与 `dpkg-deb`；Mac 可用 `brew install dpkg` 安装后者。将 Rootless / RootHide 安装包放在本目录的 `packages/` 下。以下地址必须替换为自己的真实源根目录，包含子目录：

```sh
python3 prepare-release.py --base-url "https://你的源域名/实际源目录/" --output upload
```

也可用 `--deb /绝对路径/安装包.deb` 指定一个或两个包，或用 `--name` 指定源名称。工具会写入在线展示字段、重打包、计算哈希并生成 `Packages`、压缩索引与 `Release`。输出目录必须不存在，防止覆盖旧源。

未拿到地址前，可生成纯离线预览：

```sh
python3 prepare-release.py --preview-only --output preview
```

## 上传到已有源

1. 合并 `upload/debs/` 和 `upload/depictions/` 到现有源对应目录。
2. 使用现有源的索引生成工具重新索引全部包。不要用本工具仅含本插件的 `Packages` 覆盖已有源的完整索引。
3. `Packages.fragment` 仅供核对新增条目；文件名、大小和哈希必须与实际上传 deb 一致。
4. 保留原源的 `Release`、图标及签名流程。若源管理平台自动接管详情字段，以平台最终生成的字段为准。

## 新建专用源

把 `upload/` 的内容上传到 `--base-url` 对应的 HTTPS 根目录，保持大小写和相对路径不变。此目录只含该插件；两个架构的包各有独立文件名。不要同时安装两个包。

`Release` 未签名。若源或客户端要求签名，用源拥有者已有的密钥生成 `InRelease` / `Release.gpg`，不要关闭签名检查来绕过错误。

## 上线验收

- 图标 URL 返回 PNG，不是登录页。
- `depiction.json` 返回 JSON；`index.html`、两张预览都可公开访问。
- `Packages` 中三个展示 URL 均使用真实源域名，没有示例或本机地址。
- 下载后的 deb 哈希与索引一致；在 Sileo 刷新源并检查图标、详情与更新两个标签。
- 现有源中其他插件仍可见。发布前确认你有分发原项目源码与二进制的授权；本资料未替原项目新增开源许可证。

格式核对参考：Sileo 官方源码的 `PackageListManager`、`DepictionTabView`、`DepictionScreenshotsView`、`DepictionMarkdownView`。
