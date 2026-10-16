<p align="center">
  <img src="./docs/app-icon.png" width="128" height="128" style="border-radius: 28px; box-shadow: 0 10px 30px rgba(0,0,0,0.18);" alt="YPlayer-iOS Icon" />
</p>

<h1 align="center">YPlayer for iOS</h1>

<p align="center">
  <b>优雅、流畅、纯净的 iPhone & iPad 全功能音乐播放器</b><br>
  <sub>基于 AlgerMusicPlayer 深度移植与原生扩展 · 目标构建版本 iOS 14.0+ · 纯正 Apple Human Interface 与 Emil Kowalski 设计工程体验</sub>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-iOS%2014.0%2B-000000?style=for-the-badge&logo=apple&logoColor=white" alt="iOS 14.0+" />
  <img src="https://img.shields.io/badge/Device-iPhone%20%7C%20iPad-blue?style=for-the-badge&logo=apple" alt="Universal" />
  <img src="https://img.shields.io/badge/Native-Swift%205.9%20%2F%20WebKit-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift Native" />
  <img src="https://img.shields.io/badge/Build-GitHub%20Actions%20CI-2088FF?style=for-the-badge&logo=github-actions&logoColor=white" alt="CI" />
  <img src="https://img.shields.io/badge/IPA-Unsigned%20Package-success?style=for-the-badge" alt="Unsigned IPA" />
</p>

---

## 🌟 项目亮点

`YPlayer-iOS` 是将经典音乐播放器完整带入 iOS 生态的原生混合架构实现。不仅完整保留了音乐解析、歌词显示、歌单管理、音效均衡器等核心特性，更针对移动端手势与系统底层机制进行了全方位的原生重构：

- 📱 **iPhone & iPad 通用深度自适应**：
  - 完美适配灵动岛、刘海屏与 iPad 侧栏/Split View 多任务分屏。
  - 支持横竖屏全方向旋转，针对平板大屏与手机单手操作进行了空间与布局优化。
- 🎧 **专业级原生后台音频管理**：
  - 配置原生 `AVAudioSessionCategoryPlayback`，实现真正无限制的锁屏与退火后台持续播放。
  - 耳机断开、蓝牙设备移除时遵循 iOS 规范自动优雅暂停，避免公放尴尬。
  - 拨打电话、系统通知接入时自动响应音频焦点中断（Audio Interruption Handling）。
- 🎛 **锁屏与控制中心原生集成**：
  - 完整接入 `MPNowPlayingInfoCenter` 与 `MPRemoteCommandCenter`。
  - 锁屏界面实时展示专辑大图、歌曲名、演唱者、进度条以及可拖拽时间轴。
  - 深度支持 AirPods / 耳机线控双击切换、播放、暂停与上一首/下一首。
- 📳 **精细的原生触觉反馈 (Haptics)**：
  - 基于 Emil Kowalski 交互美学，在切歌、点赞、列表拖拽、音量调整处调用原生 `UIImpactFeedbackGenerator`（Light / Medium / Heavy / Soft / Rigid / Selection），带来指尖温润反馈。
- ⚡ **无跨域本地协议桥接**：
  - 自定义 `LocalSchemeHandler`，通过 `app://localhost/` 协议直接在内存中高效流式加载 Web 打包资源，彻底杜绝 iOS 14 WebKit 的 `file://` 沙盒跨域限制。
  - 彻底重构 IndexDB 异步加载机制，解决旧版 Safari 14 不支持 top-level await 导致的白屏问题，完美向下兼容至 iOS 14.0。
- 🛠 **自建与在线 API 自由切换**：
  - 支持在设置中随时自定义第三方音乐解析 API 服务端地址，数据自由掌控。

---

## 🚀 GitHub Actions 自动云端构建 (未签名 IPA)

本项目已全面配置 GitHub Actions 云端构建工作流，**无需拥有 Mac 电脑或安装 Xcode**，即可通过云端生成专属未签名 `.ipa`：

### 📌 下载构建包步骤：

1. 打开本项目 GitHub 仓库主页。
2. 点击顶部的 **[Actions](https://github.com/1970905901/YPlayer-iOS/actions)** 标签页。
3. 在左侧工作流列表中选择 **Build iOS (iPhone & iPad)**。
4. 点击右侧的 **Run workflow** 下拉菜单，分支选择 `master`，点击绿色的 **Run workflow** 按钮启动。
5. 等待构建完毕（GitHub 托管的 `macos-14` M1 运行环境，全程仅需约 2~3 分钟）。
6. 构建成功后，点击该条构建记录进入详情页，滑至页面底部的 **Artifacts** 区域。
7. 点击下载 **`YPlayer-iOS-ipa`** 压缩包，解压后即获得 **`YPlayer-iOS.ipa`**。

---

## 📲 安装与侧载方式 (Sideloading)

由于打包输出的是标准的未签名（Unsigned）`.ipa` 安装包，你可以使用以下常见方式轻松安装至 iPhone 或 iPad：

| 安装方式 | 适用系统 | 说明 |
| :--- | :--- | :--- |
| **TrollStore (巨魔)** | iOS 14.0 - 16.6.1 / 17.0 | **强烈推荐**。直接导入 IPA 即可实现永久免证书签名、免重签运行。 |
| **AltStore / SideStore** | 所有 iOS 14.0+ 版本 | 借助 Apple ID 每 7 天自动无线自签刷新，支持 Windows / Mac 客户端。 |
| **Sideloadly** | 所有 iOS 14.0+ 版本 | 连接数据线，输入 Apple ID 即可一键完成签名并部署安装到手机。 |
| **自备个人 / 企业证书** | 所有 iOS 14.0+ 版本 | 使用全能签、轻松签、牛蛙助手等移动端签名工具导入 P12 证书直接签名安装。 |

---

## 💻 本地工程架构与开发

如果你拥有 Mac 设备并希望在本地进行定制开发或调试：

### 📁 目录结构

```text
YPlayer-iOS/
├── ios/
│   ├── AlgerMusicPlayer.xcodeproj  # Xcode 原生 iOS 工程 (Deployment Target: iOS 14.0)
│   └── AlgerMusicPlayer/
│       ├── AppDelegate.swift       # 应用程序入口与窗口初始化
│       ├── AudioSessionManager.swift # 原生音频会话与中断监听
│       ├── NowPlayingManager.swift # 锁屏与系统控制中心交互
│       ├── NativeBridge.swift      # 原生与 WebKit 之间的双向 JS 桥
│       ├── ViewController.swift    # WKWebView 核心宿主容器
│       ├── Info.plist              # 后台音频模式与隐私权限配置
│       └── Assets.xcassets/        # 原生 App 图标 (1024x1024) 与资源
├── src/                            # 前端核心业务源码 (Vue 3 + Vite + TailwindCSS)
├── scripts/
│   └── sync-ios.mjs                # 构建产物自动同步至 iOS AppAssets
├── .github/workflows/
│   └── build-ios.yml               # GitHub Actions 云端构建流水线
└── package.json
```

### 🛠 本地环境依赖
- Node.js 20+
- Xcode 15+ (Command Line Tools)
- CocoaPods / Git

### 🏃 运行与构建命令

```bash
# 1. 克隆仓库
git clone https://github.com/1970905901/YPlayer-iOS.git
cd YPlayer-iOS

# 2. 安装 Node.js 依赖
npm install --legacy-peer-deps

# 3. 启动前端实时热重载开发服务器
npm run dev

# 4. 构建前端并自动同步至 iOS 原生工程 Assets
npm run build:ios

# 5. 打开 Xcode 工程
open ios/AlgerMusicPlayer.xcodeproj
```

在 Xcode 中选择模拟器或已连接的真实 iPhone / iPad 设备，点击 **Run (⌘ + R)** 即可直接调试。

---

## 🎨 视觉与体验规范 (Design Guidelines)

本项目遵循 **Emil Kowalski** 的交互与微动效规范以及 **Apple Human Interface Guidelines (HIG)**：
- **微交互与形变**：列表与按钮在按下时具备微妙的 `scale(0.97)` 物理收缩效果。
- **防止误触放大**：禁用默认的双击缩放，输入框默认字体设定为 16px 防止 iOS 自动页面缩放。
- **安全边距与沉浸式**：使用 `viewport-fit=cover` 与 `env(safe-area-inset-top)` / `env(safe-area-inset-bottom)` 优雅避让刘海屏与手势横条。
- **响应式排版**：针对 iPhone 单手握持与 iPad 平板大视野做了专门的列表宽度与控制栏间距微调。

---

## 📜 致谢与开源协议

- 本项目基于开源项目 [algerkong/AlgerMusicPlayer](https://github.com/algerkong/AlgerMusicPlayer) 深度定制与移植。感谢原作者为社区带来的优秀音乐作品！
- 音乐解析与音源服务依赖 [netease-cloud-music-api](https://github.com/Binaryify/NeteaseCloudMusicApi) 与开源社区。
- **免责声明**：本项目仅供个人学习、移动端跨平台技术研究交流使用，不得用于任何商业用途。所有音乐资源与版权归原权利方所有。
