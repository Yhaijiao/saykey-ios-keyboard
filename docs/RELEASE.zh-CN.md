# 构建与发布

代码仓库（`Yhaijiao/saykey-ios-keyboard`）可以是私有的。手机上的「用 SideStore 安装更新」只从一个**公开的安装包仓库**下载：

```
https://github.com/Yhaijiao/saykey-releases/releases/download/lab-phone-asr/CapsWriterLab-sideload.ipa
```

这个仓库里只放安装包，不放代码。

## 日常流程

1. **构建**：Actions → *Build iPhone keyboard for sideloading* → Run workflow，选分支。
   - 默认只编译并打包 IPA（Mac 机器约 3 分钟）。
   - 勾选「同时跑模拟器界面测试」会多跑约 15 分钟。改了键盘布局或正式发版前再勾。推送到 `main` 时总会跑全套。
2. **发布**：同一个 workflow 再 Run 一次，在「只发布」一栏填上一步通过的运行编号。它会：
   - 检查那次构建成功、校验 SHA-256；
   - 把 IPA 上传到 `saykey-releases` 的 `lab-phone-asr`，并在说明里写上版本号和提交；
   - 顺手也传一份到代码仓库自己的旧地址（仓库私有后这一步失败也不影响）。
3. 手机上打开 Lab →「更新与续签」→「用 SideStore 安装更新」。

本地也可以用 `发布实验包.ps1 -RunId <运行编号>` 发布，效果一样。

## 需要的设置（只做一次）

- 公开仓库 `Yhaijiao/saykey-releases`（勾选 Add a README，内容随意）。
- 代码仓库的 Actions 密钥 `RELEASES_TOKEN`：一个 fine-grained 令牌，只授权 `saykey-releases`，权限 *Contents: Read and write*。令牌到期后发布会报错「缺少 RELEASES_TOKEN」或 401，重新生成并替换密钥即可。

## 为什么这样分

私有仓库的 Release 下载需要登录，SideStore 拿不到，所以安装包要放在公开仓库。私有仓库每月有 2000 分钟免费 Actions 时间，但 macOS 按 10 倍计算（约 200 分钟 Mac 时间），所以日常构建默认跳过模拟器测试，不需要 Xcode 的检查放在 Linux 机器上跑。
