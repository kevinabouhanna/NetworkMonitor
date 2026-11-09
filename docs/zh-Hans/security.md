# 安全策略

[English](../../SECURITY.md) · 简体中文

## 支持的版本

只有[最新发布版本](https://github.com/kevinabouhanna/NetworkMonitor/releases/latest)会获得安全修复，不会向旧版本移植修复。从 1.15 开始，NetworkMonitor 会自己提示新版本；在此之前的版本，请下载新版本并替换旧版本（请参阅[更新](installing.md#更新)）。

## 报告漏洞

请通过 [GitHub 的私密漏洞报告](https://github.com/kevinabouhanna/NetworkMonitor/security/advisories/new)私下报告。不要为此创建公开的问题或拉取请求。

请包括：

- NetworkMonitor 的版本（设置 › 关于）和 macOS 的版本；
- 攻击者能做什么，以及需要先具备什么条件（本地账户、管理员权限、处于同一网络中）；
- 重现步骤。

你会在 7 天内收到回复。确认后，修复会随某个发布版本推出，安全公告和发行说明中会注明你的贡献，除非你不希望这样。

## 范围

按重要程度排列：

- **以 root 身份运行的辅助程序。**在发布版本中，它是应用内的启动守护进程，只通过 XPC 响应由其团队签名的 NetworkMonitor；还包括它在 `/Library/PrivilegedHelperTools/com.kevinabouhanna.NetworkMonitor.helper` 的副本、它每小时运行的自我修复任务，以及它在 `/Library/Application Support/NetworkMonitor/` 中的记录。没有 Developer ID 的构建版本则通过位于 `/etc/sudoers.d/networkmonitor` 的 sudoers 规则运行同一个二进制文件。范围内的问题包括：让它做出超出其固定指令的事情、从 NetworkMonitor 以外的任何程序访问它、改变这些指令的作用对象，或篡改它的记录。它本应如何工作，请参阅[热点模式](hotspot-mode.md#辅助程序)。
- **内容过滤器**，即为每个连接命名并应用你的规则的系统扩展（[连接](connections.md#网站名称)）。范围内的问题包括：让它阻止或允许你的规则没有指定的内容、报告它不应报告的内容，或响应 NetworkMonitor 以外的任何程序。如果它停止运行，不应有任何连接被切断。
- **安装和移除它们**：`helper-setup.sh`、`Scripts/install.sh`、`Scripts/uninstall.sh` 以及应用内的“卸载…”，包括它们遗留下来的任何内容。
- **应用把数据发送到你的 Mac 之外。**它唯一应该发起的流量是你自己运行的网速测试、每日更新检查，以及每月的国家或地区和网络数据（请参阅[隐私](privacy.md#它会发送什么)）。
- **它从 GitHub 接受的内容。**只有当更新的磁盘映像使用应用内置的密钥签名时，更新才会安装；只有当已签名的清单和每张表的 SHA-256 都验证通过时，每月数据才会被使用。任何能绕过其中一项的问题都在范围内。
- **下载的文件。**Releases 页面上的 `NetworkMonitor.dmg` 与用对应标签的源代码构建出的结果不一致。

## 已知且有意为之

以下是已记录的设计选择，不是漏洞：

- **你允许辅助程序后，它的指令无需密码即可运行**：在发布版本中，通过“系统设置 › 通用 › 登录项与扩展”中的开关允许；在没有 Developer ID 的构建版本中，通过 sudoers 规则，仅限安装它的账户。每条指令都不接受参数，它涉及的每项设置、每个域名和主机都已编译在程序中。
- **热点模式会编辑 `/etc/hosts`**，以便在你使用热点时阻止 Google、Canva 和 Figma 的更新服务器。离开热点时，它会恢复这个文件。
- **热点模式会在你使用热点时写入受管理的策略文件**：Claude 和 Slack 的写在 `/Library/Managed Preferences` 中，Claude Code 的写在 `/Library/Application Support/ClaudeCode/managed-settings.d` 中。离开热点时，它会移除这些文件。
- **内容过滤器会阻止你的规则要求阻止的连接**，打开热点模式时，还会在你使用热点时阻止应用的更新程序。在 **询问我** 下，它会在询问期间暂停新连接，30 秒内没有回应则让它继续。
- **本身就需要 root 权限或管理员密码的攻击。**

## 检查下载的文件

每个发布版本都由仓库的 [Release 工作流程](../../.github/workflows/release.yml)根据对应的标签构建和发布，而不是在任何人的 Mac 上构建。发布页面列出了 `NetworkMonitor.dmg` 的 SHA-256。比较方法：

```sh
shasum -a 256 ~/Downloads/NetworkMonitor.dmg
```

发布版本使用 Kevin Abou Hanna 的 Developer ID（团队 `GRQKG7M8CL`）签名，并经过 Apple 公证。检查已安装的副本：

```sh
spctl -a -vv /Applications/NetworkMonitor.app
# accepted, source=Notarized Developer ID, origin=Developer ID Application: Kevin Abou Hanna (GRQKG7M8CL)
```

请只从 [Releases 页面](https://github.com/kevinabouhanna/NetworkMonitor/releases)或[网站](https://kevinabouhanna.github.io/NetworkMonitor/)（它链接到 Releases 页面）下载。
