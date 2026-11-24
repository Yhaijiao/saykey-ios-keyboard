# AGENTS.md — 给 AI 编程助手的项目规则（SayKey）

本文件给任何接手本仓库的 AI 助手看（Google Antigravity / Gemini、Codex、Claude 等）。
**先读完本文件，再读 [docs/交接.md](docs/交接.md)（当前状态、待办、运行环境），再动手。**

## 1. 这是什么项目

SayKey 是一款 iPhone 第三方键盘：语音输入 + 离线拼音 + 英文键盘。主 App 叫 **SayKey Lab**，负责录音；键盘扩展负责发指令和上屏。识别在用户自己控制的服务器上做（家里 Windows 电脑上的语音桥接，或以后的 AWS GPU 服务器），不经过任何第三方语音云。

## 2. 主人和目标（决定你怎么取舍）

- 主人是 Jeremy，**用中文交流**，住在美国，**刚接触 Git / CI**：解释要直白，少用术语，必要时一步一步写清楚点哪里。
- 真正目的：**完整走一遍个人开发 + 小规模美国商业化的流程**，学会了以后做别的产品。实用价值是次要的。
- **隐私第一**：不要引入中国境内托管的识别服务，不加广告、统计、第三方语音 API。
- **能发出去比打磨更重要**：先做完、发布、让他日常用，再改。注意他的额度和时间，不要做没要求的大重构。
- 他不做专门的真机测试，在日常使用中测。所以每次改动要小而稳，能在云端测试的尽量写测试。

## 3. 必须遵守的规则

### 语言
- **PR 标题和描述用中文。**
- **代码、代码注释、commit message 用英文。**
- 写给 Jeremy 看的文档（docs/*.zh-CN.md、docs/交接.md）用中文。

### 分支
- 开发主线是 **`feature/phone-asr`**（beta 线）。`main` 是将来的稳定版，比较旧，**稳定后才合并过去**；GitHub 默认分支保持 `main`。
- 每项工作从 `feature/phone-asr` 新开分支，做完开 PR 合回 `feature/phone-asr`。
- 不要 force-push 别人的分支，不要直接推 `main`。

### 绝对不能改的东西
- **Bundle ID 不变**：`org.capswriterlab.keyboard`、`.extension`、`.activity`，钥匙串组也不变。改了 SideStore 会当成新 App，配对丢失。
- **安装包文件名不变**：发布时仍叫 `CapsWriterLab-sideload.ipa`。手机里的更新按钮写死了这个地址：
  `https://github.com/Yhaijiao/saykey-releases/releases/download/lab-phone-asr/CapsWriterLab-sideload.ipa`
- 工程内部的 target 名、文件名还带旧前缀 CapsWriter，**这是故意的**，不要顺手改名。只有显示名叫 SayKey。

### 密钥和隐私数据
- **永远不要**把令牌、密码、配对码、个人热词、录音、私有配置写进代码、文档、commit 或聊天。
- 发布用的令牌在 GitHub 仓库 Settings → Secrets and variables → Actions 里，名字叫 **`RELEASES_TOKEN`**。只说名字，不要读、不要打印。
- 本地 `private/` 目录（在 .gitignore 里）放的是私有运行数据，不要扫描、上传、提交。

### 版本号
- 每次要发布的改动，在 `project.yml` 里同时加 `MARKETING_VERSION`（如 0.4.34 → 0.4.35）和 `CURRENT_PROJECT_VERSION`（47 → 48），并同步修改 `.github/workflows/build-ios.yml` 里 IPA 打包和 `verify_ipa.py` 的版本号。
- 当前已发布：**v0.4.38（build 51）**。下一个是 **v0.4.39（build 52）**。

### 发布
- **一批功能全部做完后再发布一次**，不要每做一个功能就发一次；一批做到一半时不要发。
- **合并 PR 前**让 Jeremy 看一眼 PR 标题和描述，得到他同意再合并。
- **一批合并完、CI 编译通过后，直接发布，不用再问他**（这是他的长期规则）。发布完告诉他版本号，让他在手机上点更新。
- 怎么发布见 [docs/RELEASE.zh-CN.md](docs/RELEASE.zh-CN.md) 和 [docs/交接.md](docs/交接.md) 第 4 节。

### 编译和测试
- iOS 代码只能在 macOS 上编译。Jeremy 用的是 Windows，所以 **iOS 编译只在 GitHub Actions 上跑**（工作流 `build-ios.yml`，手动触发）。PR 不会自动编译，要手动 Run workflow。
- 模拟器界面测试是可选的（输入项 `simulator_tests`，多用约 15 分钟 Mac 时间）。改了键盘布局或正式发版前再勾。推到 `main` 时总会跑全套。
- 服务端（Python）测试可以在本地跑：`python -B -m unittest discover -s bridge -p 'test_*.py' -v`
- 改了 Swift 后请仔细自查语法，因为每次 CI 编译要好几分钟，私有仓库的 Mac 免费时间有限（约 200 分钟/月）。

### PR 的写法
- 先把所有 commit 推完、CI 通过，再告诉 Jeremy PR 好了。他看到链接就会很快合并，PR 开出后不要再往里塞新内容。
- PR 描述要和实际内容一致：做了什么、为什么、他需要做什么（例如需要重启电脑桥接）。

## 4. 代码地图

| 路径 | 内容 |
| --- | --- |
| `ios/App/` | 主 App SayKey Lab：录音会话（`VoiceSession.swift`）、配对、热词、自动跳回（`HostAppReturn.swift`）、更新入口（`AppDelegate.swift`） |
| `ios/Keyboard/` | 键盘扩展：`KeyboardViewController.swift`（布局、拼音、语音页、上屏）、宿主探测（`HostAppProbe.swift`） |
| `ios/Shared/` | 主 App 和键盘共用：拼音引擎、联想词、配对、草稿上屏、跳回策略与宿主解析（`HostReturnPolicy.swift`）、更新链接（`SideStoreUpdateLink.swift`）、词库数据 |
| `ios/VoiceActivity/`, `ios/IntentShared/` | 灵动岛 / 锁屏实时活动、App Intents |
| `ios/LayoutTests/`, `ios/UITests/` | 单元测试和界面测试 |
| `bridge/` | 家里电脑的 Python 语音桥接（`server.py`、`voice.py`、热词 `hotwords.py`、纠错 `engine.py`、口语清理与阿拉伯数字 `cleanup.py`、本地大模型润色 `polish.py`、边说边上屏 `stream.py`） |
| `cloud/` | AWS / Linux 服务器部署脚本（网关、HTTPS、自动关机），暂停中 |
| `scripts/` | 词库生成、冒烟测试、发布校验 |
| `project.yml` | XcodeGen 工程定义，版本号在这里 |
| `.github/workflows/build-ios.yml` | 编译 IPA + 只发布 |
| `docs/` | 中文文档：安装、发布、语音、云、热词等 |

工作流程：键盘 → POST `/v1/voice/start|stop` → 主 App 录音并上传音频到桥接 → 桥接调用 CapsWriter-Offline 识别 → 热词纠错 → 键盘轮询 `/v1/voice/result` 拿到文字上屏。

## 5. 现在先做什么

先做 [docs/交接.md](docs/交接.md) 第 7 节「最新反馈（2026-11-24）」里的三项：① 修复主 App 没开时「跳主 App 再跳回」的回归（P0）；② 借鉴电脑版 CapsWriter 的去语气词 / 去口吃重复（P0）；③ 误触滑动。
