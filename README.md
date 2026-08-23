# Pictool

macOS 原生图片查看器 · Swift 6 + SwiftUI(混合 AppKit),零第三方依赖。

## 功能

- **文件夹浏览**:多文件夹项目侧栏(文件夹树),点选切换;←/→ 或缩略图网格切换图片,首尾循环
- **缩略图网格**:边栏下半区自适应网格,异步生成 + 缓存,当前项高亮并自动跟随滚动
- **流畅缩放**:触控板捏合 / ⌘ 或 ⌥ + 滚轮(以光标为锚点)/ 鼠标拖拽平移 / 双击切换 适配↔实际大小;大图按需加载全尺寸
- **图片信息**:文件、像素、色彩、EXIF(相机/镜头/快门/光圈/ISO/GPS)面板,可一键复制
- **简单裁切**:8 手柄选区、比例预设(1:1、4:3、16:9 等)、三分线辅助;导出 PNG/JPEG/HEIC/TIFF 并尽量保留 EXIF
- **打印**:适配页面 / 实际大小,横纵向自动,标准打印面板
- **格式支持**:系统 ImageIO 原生 61 种,含 HEIC/AVIF/WebP/JXL/PSD/RAW(佳能/尼康/索尼/富士等);GIF 动画播放

## 快捷键

| 按键 | 功能 |
|---|---|
| ⌘O | 打开文件夹 |
| ← / → | 上一张 / 下一张 |
| 0 / 1 | 适配窗口 / 实际大小 |
| ⌘= / ⌘- | 放大 / 缩小 |
| I | 信息面板 |
| C | 裁切 |
| ⌘P | 打印 |

也支持把图片文件或文件夹**拖入窗口**直接打开。

## 构建与运行

```bash
./build.sh            # release 构建 + 组装 Pictool.app(ad-hoc 签名)
open build/Pictool.app

swift build           # debug 构建
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # 单元测试
```

> 说明:XCTest 不随 Command Line Tools 提供,跑测试时需用 `DEVELOPER_DIR` 指向完整 Xcode。

要求:macOS 14+,Xcode 16+ 或 CommandLineTools(Swift 5.10+)。

## 结构

```
Sources/Pictool/
├── PictoolApp.swift        # 入口、菜单与全局快捷键
├── Models/                 # ImageFile(发现/自然排序)、FolderStore、ThumbnailProvider
├── Views/                  # 三栏布局、文件夹树、缩略图网格、缩放画布、信息面板、裁切
└── Services/               # ImageLoader(降采样解码)、Metadata、Crop(坐标换算+导出)、Print
Tests/PictoolTests/         # 裁切坐标 / 排序 / 格式识别 单元测试
```
