# NetworkMonitor 文档

[English](../README.md) · 简体中文

[README](../../README.zh-Hans.md) 是简短的介绍。这些页面则更详细：每项功能是如何工作的，以及为什么这样设计。

## 使用 NetworkMonitor

| 页面 | 内容 |
|---|---|
| [安装、更新和卸载](installing.md) | 每个步骤、它如何自行更新，以及卸载时会恢复什么 |
| [功能](features.md) | 菜单栏读数、弹出窗口、按连接统计的总计、主窗口、设置 |
| [连接](connections.md) | 你的应用在和哪些公司、国家或地区、服务器通信，以及这些名称的含义 |
| [流量历史](usage-history.md) | 按日、周、月或年回顾；连接时段；导出 CSV |
| [网速测试](speed-test.md) | 它测量什么、如何显示，以及会消耗多少流量 |
| [热点模式](hotspot-mode.md) | 什么算作热点、它会暂停什么、辅助程序、低数据模式 |
| [统计准确性与耗电量](accuracy-and-battery.md) | 这些数字的含义、各行加起来为什么不完全等于总计，以及运行它的开销 |
| [隐私](privacy.md) | 它会读取、发送和存储什么 |
| [安全策略](security.md) | 报告漏洞、哪些内容在范围内、检查下载的文件 |

## 开发 NetworkMonitor

以下页面只有英文版。

| 页面 | 内容 |
|---|---|
| [Architecture](../architecture.md) | 数据如何流动（附示意图）、线程、两种测量来源、文件 |
| [Building, testing and releasing](../development.md) | Make 目标、签名和公证、测试工具、CI、启动参数、发布和网站流程 |
| [Decisions](../decisions.md) | 原则、按日期记录的决策日志，以及被否决的方案 |
| [Roadmap and known limits](../roadmap.md) | Developer ID 带来了哪些可能、已经完成了什么；想法；已知限制 |

在更改任何测量方式之前，请先阅读 [Architecture](../architecture.md)（英文）和 [Decisions](../decisions.md)（英文）。
