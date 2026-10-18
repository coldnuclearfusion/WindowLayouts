# WindowLayouts

[English](README.md) · [한국어](README.ko.md) · [日本語](README.ja.md) · **中文（简体）**

保存窗口布局，并在菜单栏中一键恢复。

- **保存**：保存当前窗口的排列，可选择要包含的应用和窗口。
- **恢复**：从菜单栏立即应用布局。可以在设置窗口中手动修改每个窗口的标题、位置和大小，也可以直接编辑 JSON 文件。
- **按显示器配置区分**：每个布局都会记住保存时的显示器配置。与当前配置匹配的布局排在前面；应用在其他配置下保存的布局时，会按当前连接的显示器重新放置窗口。
- **多窗口应用**：同一应用的多个窗口先按标题匹配，再按顺序匹配。
- **未运行的应用**：布局中的应用未运行时，可以为每个布局选择询问、启动它，或只排列正在运行的应用。
- **应用时置于最前**：可选择按保存的顺序把布局中的窗口置于最前。
- **浏览器页面**：浏览器窗口可以带有页面地址。应用时使用含有该标签页的窗口（并切换到该标签页），没有则在新窗口中打开该页面。
- 登录时自动启动并常驻菜单栏，没有程序坞（Dock）图标。
- **可用脚本调用**：`open "windowlayouts://apply?name=Coding"` 可以从终端、快捷指令或快捷键应用中应用布局。
- **语言**：支持韩语、英语、日语和简体中文，默认跟随系统语言，可在常规设置中更改。三个平台的应用共用同一个字符串表（[`shared/strings.json`](shared/strings.json)）。

## 平台

| 平台 | 状态 | 目录 |
|---|---|---|
| macOS 15 及以上 | 可用 | [`macos/`](macos/) |
| Windows 10/11 | 草稿，尚未构建或测试 | [`windows/`](windows/) |
| Linux (X11) | 草稿，尚未运行或测试 | [`linux/`](linux/) |

布局以 JSON（`layouts.json`）格式保存，因此各平台可以共用同一格式；已验证 Linux 版的模型无需修改即可读取 macOS 的文件。Windows 版和 Linux 版是在 Mac 上照着 macOS 应用逐个模块移植编写的，尚未构建或运行。各目录中的文档只有英文版。

## 语言

界面提供韩语、英语、日语和简体中文。默认情况下，每个应用都跟随系统语言（繁体中文系统显示简体中文）；也可以在详细设置窗口的 *常规设置* 中固定使用一种语言。所有用户可见的字符串都在 [`shared/strings.json`](shared/strings.json) 中，以固定不变的标识符为键，并支持 `{placeholder}` 替换；各平台在构建时复制此文件（macOS 为 `build.sh`，Windows 为项目文件，Linux 为 `install.sh`）。要添加一种语言，请把它的代码加入 `languages` 和每个条目。

## 快速开始（macOS）

需要 macOS 15 或更高版本以及 Xcode（较新的 Command Line Tools 缺少 SwiftUI 宏插件，参见 [macos/README.md](macos/README.md)（英文））。

```bash
git clone https://github.com/coldnuclearfusion/WindowLayouts.git
cd WindowLayouts/macos
./install.sh
```

然后在“系统设置 › 隐私与安全性 › 辅助功能”中允许此应用。关于让权限在重新构建后依然有效的代码签名、JSON 格式、浏览器页面的处理以及在多台 Mac 上安装，详见 [`macos/README.md`](macos/README.md)（英文）。

## 许可证

MIT，参见 [LICENSE](LICENSE)。
