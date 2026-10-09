# FolderSync — 目录同步合并工具

一款原生 macOS SwiftUI 桌面工具：对两个目录进行**全局统一排重**，并将副目录中主目录缺失的文件合并进主目录，专为海量文件场景做了性能优化。

## 功能特性

- **目录配置**：分别选取主目录（合并目标）与副目录（来源），自动识别符号链接指向同一目录的冲突
- **一键分析**：并发扫描两棵目录树，通过 SHA-256 哈希在两个目录的所有子目录间进行全局排重
- **统计展示**：显示主/副目录各自的文件数量与总占用空间，以及排重后预估的合并文件数与总空间（显示在"开始合并"按钮左侧）
- **安全合并**：将副目录排重后的全局唯一文件写入主目录，优先沿用主目录的目录结构（缺失时自动创建）；目标已存在的文件自动跳过，不覆盖
- **过程可视**：下方 2/3 区域实时滚动显示处理日志（含里程碑进度、跳过/失败明细），底部状态栏展示总体进度
- **随时取消**：分析（扫描/哈希）与合并阶段均可中途取消，合并取消后安全回退到已分析状态

## 界面布局

```
┌──────────────────────────────────────────────┐
│  目录配置（上 1/3）                            │
│  主目录 [路径________] [浏览…]                │
│  副目录 [路径________] [浏览…]                │
│            [取消]  [开始分析]                 │
├──────────────────────────────────────────────┤
│  主目录统计 │ 副目录统计 │ 合并后预估 │ [开始合并] │
│ ──────────────────────────────────────────── │
│  处理过程日志（下 2/3，自动滚动）               │
├──────────────────────────────────────────────┤
│  状态栏：阶段  ▓▓▓▓░░ 进度条  状态文本          │
└──────────────────────────────────────────────┘
```

## 工作流程

1. **扫描**：并发遍历两棵目录树（跳过符号链接），统计文件数与总大小
2. **排重**：按文件大小分组——大小全局唯一的文件直接跳过哈希；仅对大小歧义文件计算 SHA-256（≤1MiB 整读，大文件 1MiB 分块）
3. **合并**：预创建全部所需父目录 → 最多 4 路并行复制 → 汇总跳过/失败明细

## 性能设计（海量文件友好）

| 策略 | 说明 |
|---|---|
| 大小预分组 | 大小全局唯一的文件免于哈希，大幅减少 I/O |
| 并行哈希 | TaskGroup 并行度 = CPU 核数，分块读取控制内存 |
| 流式进度 | UI 回调经 Pulse 时间窗节流（0.12~0.15s），避免高频刷新卡顿 |
| 日志上限 | 日志环形截断至 500 条，长任务不膨胀内存 |
| 活性心跳 | 扫描每 5 万文件、哈希每 25% 记录里程碑日志，长任务可感知 |
| 低内存哈希 | 结果直接累积到最终字典，无中间双倍峰值 |

## 项目结构

```
FolderSync/
├── Package.swift                  # SwiftPM 清单（swift-tools-version 6.0）
├── Sources/
│   ├── FolderSyncCore/            # 核心逻辑库（可独立测试）
│   │   ├── Models.swift           # FileInfo / TreeStats / DedupResult / MergeOutcome 等
│   │   ├── ScanEngine.swift       # 目录树扫描
│   │   ├── HashEngine.swift       # SHA-256 哈希（并行 + 分块 + 可取消）
│   │   ├── DedupEngine.swift      # 全局排重与合并计划
│   │   └── MergeExecutor.swift    # 并行复制执行
│   └── FolderSync/                # GUI 应用
│       ├── AppModel.swift         # @MainActor 状态机（阶段/进度/日志/取消）
│       └── FolderSyncApp.swift    # SwiftUI 界面（Window 单窗口场景）
├── Tests/FolderSyncCoreTests/     # 19 个 Swift Testing 用例
└── Scripts/make_icon.swift        # CoreGraphics 图标生成脚本
```

## 系统要求

- macOS 13.0+
- Apple Silicon 或 Intel Mac
- 构建仅需 Command Line Tools（无需完整 Xcode）

## 构建与运行

```bash
# 调试构建
swift build

# 运行 GUI 应用
swift run FolderSync

# Release 构建
swift build -c release
```

## 测试

本机仅有 Command Line Tools（无完整 Xcode）时需显式传入 Swift Testing 宏插件路径：

```bash
swift test -Xswiftc -plugin-path -Xswiftc \
  /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

测试覆盖：扫描（递归/符号链接跳过/进度）、哈希（同内容同哈希/大文件分块）、排重（8 项边界场景）、合并（目录创建/二进制保真/跳过已存在/进度/取消）、端到端一致性，共 19 个用例。

## 打包分发

### 1. 生成应用图标

```bash
swift Scripts/make_icon.swift "$(pwd)/build/icon/FolderSync_1024.png"

# 生成 iconset 各尺寸并转为 icns
cd build/icon && mkdir -p FolderSync.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s FolderSync_1024.png --out FolderSync.iconset/icon_${s}x${s}.png >/dev/null
  d=$((s*2))
  sips -z $d $d FolderSync_1024.png --out FolderSync.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns FolderSync.iconset -o FolderSync.icns
```

### 2. 组装 app bundle 并签名

```bash
APP=build/dist/FolderSync.app
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/FolderSync $APP/Contents/MacOS/
cp build/icon/FolderSync.icns $APP/Contents/Resources/
# Info.plist / PkgInfo 参考 build/dist/FolderSync.app/Contents/ 中的现成文件
codesign --force --sign - --timestamp=none $APP
```

### 3. 制作 DMG

```bash
mkdir -p build/dmg-staging
cp -R build/dist/FolderSync.app build/dmg-staging/
ln -s /Applications build/dmg-staging/Applications
hdiutil create -volname FolderSync -srcfolder build/dmg-staging \
  -format UDZO -ov build/dist/FolderSync-1.0.0.dmg
```

### 签名说明

当前为 **ad-hoc 签名**：在本机可直接打开；分发到其他 Mac 时首次打开需**右键 → 打开**，或执行：

```bash
xattr -cr FolderSync.app
```

如需无警告的正式分发，需付费 Apple Developer 账号：用 Developer ID 证书替换 `--sign -`，并通过 `notarytool` 提交公证。
