# CLAUDE.md — SayKey 项目规则（Claude Code 必读）

**完整规则在 [AGENTS.md](AGENTS.md)，最新状态、v0.4.29–v0.4.35 排查记录与下一步切入点在 [docs/交接.md](docs/交接.md)。开始任何工作前先读完这两个文件。**

核心要点（与 AGENTS.md 一致，冲突时以 AGENTS.md 为准）：

1. 用中文和 Jeremy 交流，解释直白少术语（他刚接触 Git / CI）。
2. **PR 标题和描述用中文；代码、注释、commit message 用英文。**
3. 当前唯一工作目录：`C:\Users\YaoHa\GeminiShare\projects\saykey-ios-keyboard`。开发分支是 `feature/phone-asr`；每项工作从它新开分支，PR 合回 `feature/phone-asr`，不要动 `main`。
4. **绝不改 Bundle ID**（`org.capswriterlab.*`），**绝不改安装包文件名** `CapsWriterLab-sideload.ipa`，不要给带 CapsWriter 旧前缀的 target / 文件改名。
5. **永远不要**把令牌、配对码、个人热词、录音写进代码、文档、commit 或聊天。发布令牌在 GitHub Secrets 里叫 `RELEASES_TOKEN`，只提名字。不要扫描或读取本地 `private/` 目录。
6. 当前已发布版本：**v0.4.35（build 48）**，下一个版本是 **v0.4.36（build 49）**。改版本号时需同步修改 `project.yml` 和 `.github/workflows/build-ios.yml` 里的打包校验版本号。
7. iOS 只能在 GitHub Actions 的 Mac 上编译（`build-ios.yml` 手动触发），模拟器测试默认不勾，注意节省 Mac 分钟数。
8. 合并 PR 前先给 Jeremy 看一眼；一批功能都合并且编译通过后，直接用 `publish_run_id` 发布到 SideStore 更新地址，不用再问。

**接手第一步**：读 [docs/交接.md](docs/交接.md) 第 7.1 节，如自动跳回仍有问题，先请 Jeremy 发一下真机上 SayKey Lab 顶部提示里的 `[nav:... kb:... rep:... kd:...]` 探测码或截图，根据 `kd:...` 精准定位，不要盲猜发包。
