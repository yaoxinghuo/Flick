# Peek

一个极简的 macOS 只读看图软件（Pixea 风格的轻量替代品）。只看不改：不做编辑、标注、滤镜、删除。

- 纯 Swift Package（SwiftPM），无 Xcode 工程、无 storyboard/xib、零第三方依赖
- 界面：AppKit 纯代码；逻辑层 `PeekCore` 与 UI 解耦、可单元测试
- 最低系统：macOS 15；universal binary（Apple Silicon + Intel）
- 应用名 `Peek` 为占位名，集中定义在 `Sources/PeekCore/PeekConstants.swift`

## 构建

需要 macOS 命令行工具链（Swift 6.2+），**不需要 Xcode**：

```bash
swift build                # debug
swift build -c release     # release
swift run Peek             # 运行
swift run Peek /path/to/图片或文件夹   # 带参数打开
```

## 测试

```bash
# 本机只有命令行工具链（无 Xcode）时：
./Scripts/test.sh

# 安装了 Xcode 的机器 / CI 上也可以直接：
swift test
```

> 说明：测试用的是系统自带的 swift-testing 框架。无 Xcode 的 Command Line Tools
> 中 `Testing.framework` 不在默认搜索路径，且其 Foundation crossimport 会引用一个
> 没有 swiftmodule 的私有框架，导致裸 `swift test` 失败。`Scripts/test.sh` 会自动
> 检测环境并补上 `-F` / `-disable-cross-import-overlays` / `-rpath` 参数。

## 打包成 .app

```bash
./Scripts/build_app.sh [版本号]   # 版本号缺省取最新 git tag，无 tag 用 0.1.0
```

产出 `Peek.app` 与 `Peek.zip`。应用为 ad-hoc 签名。

**首次运行从 GitHub Actions / zip 下载的包**，会被 Gatekeeper 隔离，执行一次：

```bash
xattr -dr com.apple.quarantine Peek.app
```

或在 Finder 中右键 → 打开。

## 打开方式

- `Peek /path/to/image_or_folder` 命令行参数
- ⌘O 打开面板（可多选文件，或选文件夹）
- 拖拽文件 / 文件夹到窗口或 Dock 图标
- Finder "打开方式" / 双击（Info.plist 已声明支持的图片类型，Role = Viewer）

规则：打开单张图片 → 自动浏览其所在文件夹全部图片并定位到该张；打开文件夹 → 显示第一张；一次拖入多个文件 → 以这些文件组成临时列表。不递归子文件夹，忽略隐藏文件。

## 快捷键

| 按键 | 功能 |
|------|------|
| ← / → | 上一张 / 下一张 |
| 空格 / ⇧空格 | 下一张 / 上一张 |
| Home / End | 第一张 / 最后一张 |
| ⌘O | 打开 |
| ⌥⌘R | 在 Finder 中显示 |
| ⌘C / ⌥⌘C | 拷贝图片 / 拷贝文件路径 |

排序：显示菜单 → 排序方式（名称 / 修改日期 / 创建日期 / 大小，升序 / 降序）。

## 项目结构

```
Package.swift
Sources/PeekCore/      纯逻辑库：文件夹扫描排序、图片类型判断、翻页状态机、图片解码缓存
Sources/Peek/          AppKit 界面与入口（main.swift 手写启动）
Tests/PeekCoreTests/   swift-testing 单元测试
Scripts/build_app.sh   手工组装 universal Peek.app + zip
Scripts/test.sh        无 Xcode 环境下的 swift test 包装
.github/workflows/     CI：build → test → 打包 → 上传 artifact / Release
```

## 已知限制

- 打开方式规则中，拖拽同时包含文件夹和文件时优先处理文件夹。
- RAW 等格式依赖系统 ImageIO 支持的 UTI 识别；个别罕见扩展名可能被跳过。
