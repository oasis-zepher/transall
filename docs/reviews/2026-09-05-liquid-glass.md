# Transall 原生 Liquid Glass 外观 · 2026-09-05

界面采用 macOS 原生 Liquid Glass，同时保留圆盘格式路由和纸面文档区域。玻璃集中在导航与操作控件，文档、表单和结果内容保持不透明，浅色与深色跟随系统外观。变更位于 [草稿 PR #1](https://github.com/oasis-zepher/transall/pull/1)；远程结果以该 PR 最新提交的 Checks 为准。

## 实现范围

| 区域 | 当前行为 |
|---|---|
| 主窗口工具栏 | 使用原生 toolbar，常用操作由系统排列、显示和处理窄窗口溢出 |
| 操作按钮与浮动控件 | macOS 26 起使用 `.glass`、`.glassProminent` 和 `glassEffect(.regular)`；相邻效果通过 `GlassEffectContainer` 组合 |
| 圆盘格式路由 | 保留格式、源/目标角色和任务锁定行为；适配浅深色、对比度与减少动态设置 |
| 文档与表单 | 保持不透明阅读背景；文本、分隔线和状态颜色适配浅深色 |
| macOS 14/15 | 保留最低系统要求，使用不透明控件与清晰边界；不调用仅限 macOS 26 的玻璃 API |
| 辅助功能 | 自定义控件在减少透明度或增强对比度时切换为不透明样式；减少动态设置抑制自定义运动效果 |

主题修改没有改变 PDF 输出内容、译文缓存、恢复任务或导出规则。前一轮功能说明见 [译文复用与文档检查](2026-09-05-recovery-inspection.md)。

## 已完成的本地检查

环境：arm64 macOS 27.0、Xcode 26.6、macOS SDK 26.5。构建仍以 macOS 14 为最低目标；这不能替代旧系统实机验证。

| 检查 | 结果 |
|---|---|
| 严格 SwiftPM | 201/201，完整并发检查，警告视为错误 |
| Xcode Scheme | 201/201；参数化用例合计 224 次执行 |
| Release 分析与构建 | 均通过 |
| Swift 格式、XcodeGen 一致性 | 通过 |
| 发布元数据 | 校验及 36 组夹具通过 |

界面检查使用独立原生验收应用、临时任务目录和本地合成处理器。基线构建直接编译产品源文件，仅由验收入口选择浅深色和注入合成任务。

| 实际界面操作 | 已观察结果 |
|---|---|
| 浅色、深色与 760 pt 宽度 | 原生工具栏可操作，输入区和结果区可滚动 |
| 最终按钮与圆盘修正 | 次要按钮使用中性玻璃色，主操作保持强调色；①/②/①②移入圆内后完整显示 |
| 深色下查看排版失败 | 问题区域、原文与译文可读，恢复入口可用 |
| 从失败任务生成纯译文 | 任务完成；另行提交新样本前，处理器调用记录保持为 1 |
| 12 页等页对照中搜索 | 显示 24 处匹配；从第 1 处向前切换到第 24 处，两侧均定位第 12 页 |
| 自定义辅助功能分支 | 三项开关组合下，浅色主界面和深色 PDF 检查区显示不透明背景及更清晰边界 |

辅助功能检查使用单独的源码副本，将产品的三个只读 `@Environment` key path 替换为可写的 `review*` key，再由验收入口注入。条件判断、样式和动画分支保持原样。该方式验证自定义产品分支；原生工具栏、标准控件和系统玻璃内部仍读取真实系统设置。验收未修改 macOS 全局辅助功能偏好，不能据此声明完成真实系统设置下的全部验证。

## 验证边界

- 最后的按钮与圆盘修改已重新通过实际界面检查、严格 SwiftPM、Xcode Scheme 和 Release 分析/构建；远程 CI 与本地证据分别记录在 PR 和本文中。
- 未验证 macOS 14/15 或 Intel 实机、完整 VoiceOver 操作及真实系统辅助功能设置组合。
- 未调用真实翻译服务；合成样本不用于判断翻译准确率或复杂文档质量。
- 未执行签名、App Store 提交或发布。

## 官方依据

- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)：优先采用标准组件，移除遮盖系统效果的自定义背景，并检查显示与辅助功能设置。
- [HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials)：Liquid Glass 用于导航和控件层；内容层使用标准材料。文字较多的界面采用 regular 变体。
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)：多个效果使用容器组合，控制同时显示的效果数量与融合距离。
- [HIG Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) 与 [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)：遵循原生操作分组、可访问名称、对比度和减少动态约定。
