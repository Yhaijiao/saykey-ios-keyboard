# SayKey — iPhone 语音键盘

SayKey 是一款 iPhone 第三方键盘：按一下麦克风说话，识别好的文字直接打进当前输入框。同时自带拼音和英文键盘，平时打字也不用切回系统键盘。

> 当前是实验版（SayKey Lab），通过 SideStore 侧载安装，不需要付 Apple 开发者年费。

## 能做什么

- **语音输入**：在任何 App 的输入框里点麦克风开始、再点停止，结果自动上屏。单段最长 5 分钟，网络短暂波动会自动重试。
- **拼音输入**：全拼、简拼、混拼都支持，例如 `wom` 出"我们""我妈"，`nihaom` 出"你好吗"。约 3.1 万词的离线词库，长句可以分段选字。
- **字母键盘**：拼音和英文共用一页，打开时默认是拼音；左下角「123」旁的「中/英」键切换语言。大小写、数字和标点齐全。两页（键盘 / 语音）左右滑动切换，顶部也能直接点选。Shift 点一下只大写一个字母，快速点两下锁定大写。
- **联想词**：按键上方有一条联想词栏。打完一个词，它给出最可能接着打的词，点一下直接上屏并继续联想；英文打到一半时给出补全；继续键入新字母，联想词自动让位。全部离线。键盘会在本机记下你常用的词和词语搭配的次数（不存整句），让常用词排到前面、词库里没有的词也能出现；这些计数只存在手机上的键盘里，不上传，密码框、邮箱和号码框里不记录。
- **顶栏**：键盘页的顶栏有话筒，不用翻页就能开始或停止语音，话筒旁是语音自动换行开关；最右的收起按钮把整个 SayKey 面板收起，点一下输入框即可再打开。录音中收起面板不会打断录音，再打开后点停止才结束。
- **整行删除**：橙色删除键一次删到上一个换行符，长按连续删行。拼音页空格上屏中文，Return 上屏已输入的字母。
- **热词**：可以查看和编辑自己的热词表，专有名词识别更准，和电脑端双向同步。
- **灵动岛**：录音时在灵动岛和锁屏显示状态。
- **一键更新**：主 App 里点一下，就能通过 SideStore 装上最新版本。

## 工作原理

```
iPhone 键盘  ──开始/停止──▶  SayKey 主 App（负责录音）
                                   │
                                   ▼  上传录音（带配对码认证）
                        你自己的语音识别服务
                       （家里电脑，或自己的云服务器）
                                   │
                                   ▼
                        识别结果 + 热词纠错 ──▶ 文字上屏
```

iOS 不允许键盘扩展直接使用麦克风，所以录音由主 App 在后台完成，键盘只负责发指令和接收文字。识别在你自己控制的服务上进行，不经过任何第三方语音云。

## 安装

1. 手机上先装好 [SideStore](https://sidestore.io/)。
2. 用 SideStore 安装最新的 `CapsWriterLab-sideload.ipa`（在本仓库的 Releases 页面，标签 `lab-phone-asr`）。
3. 设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → **SayKey Lab**，并开启"允许完全访问"（语音功能需要，纯打字不需要）。
4. 打开 SayKey Lab 主 App，填入识别服务的地址和配对码（也可以扫配对二维码），在"开启语音会话"一栏开启会话。
5. 在任意输入框长按地球键切到 SayKey，就可以开始用了。

以后有新版本，在主 App 里点"用 SideStore 安装更新"即可，不用连电脑。

## 部署识别服务

- **家里电脑**：见 [docs/VOICE.zh-CN.md](docs/VOICE.zh-CN.md)，运行 `bridge/server.py`，手机和电脑在同一个局域网。
- **云服务器**：见 [docs/CLOUD.zh-CN.md](docs/CLOUD.zh-CN.md)，提供 HTTPS 网关、证书续期和到期自动关机脚本。
- **热词同步**：见 [docs/HOTWORD-SYNC.zh-CN.md](docs/HOTWORD-SYNC.zh-CN.md)。

识别引擎目前使用用户自行安装的开源 [CapsWriter-Offline](https://github.com/HaujetZhao/CapsWriter-Offline)。本仓库不包含它的源码、模型或任何个人词库。

## 自己编译

公开仓库用 GitHub 的 macOS 机器免费编译，产物是未签名的 IPA，需要用自己的 Apple ID 签名后安装。本地 Mac 也可以：

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project CapsWriterKeyboard.xcodeproj -scheme CapsWriterLab \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/device CODE_SIGNING_ALLOWED=NO build
```

（工程内部的文件名和 Bundle ID 还保留旧前缀，为了让已安装的版本能继续原地升级，不影响使用。）

服务端测试：

```sh
python -B -m unittest discover -s bridge -p 'test_*.py' -v
```

## 隐私

- 没有广告、统计或付费 API。
- 只在你主动开启的语音会话内使用麦克风，空闲时的音频直接丢弃。
- 录音只发到你自己配对的识别服务；服务端不保存音频和文字。
- 配对码保存在系统钥匙串里，不会上传到本仓库。

## 已知限制

- 免费 Apple ID 签名 7 天到期，需要 SideStore 定期刷新。
- 密码输入框和部分禁止第三方键盘的 App 里无法使用。
- 键盘冷启动时不能直接录音，需要先在主 App 开启语音会话。

## 许可

MIT，见 [LICENSE](LICENSE)。第三方组件说明见 [NOTICE.md](NOTICE.md)。
