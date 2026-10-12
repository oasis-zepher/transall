# 图表阻隔与跨栏续句修复（Metabolic 文献）

截图第 4 页的 `projection` 被重复译成“投影”。检查当前任务 `5c45f29a-8719-4204-b7b7-095740cf0552` 后确认旧缓存 541 个区域均无 continuationGroup。上一版依赖正文在页尾/页首 35% 区域，并将图注混入阅读顺序；第 3 页下方大图和第 4 页上方大图使真实正文落在页面中部，因此没有识别接续。另未处理同页左栏到右栏，且把列表末尾分号当作句末。

## 实现

- 阅读顺序中排除图注、重复页眉和可由标题/注释界定的表格区域；章节标题仍作为边界，防止跨入新章节。按正文实际阅读顺序连接页和栏，不再依赖正文必须位于页面边缘。
- 跨栏纳入原有联合翻译和原子保存队列，兼容跨页加跨栏的三段连续文字。保留最多四页并发和后页等待入站衔接的约束。
- 列表分号、冒号不作为完整句子的终点。新增 continuationVersion=2，用于选择性失效旧接续译文；旧缓存摘要保持兼容。
- 提示词要求边界术语只译一次，允许少量边界词语移动到相邻区域。中文译文再在最多 32 字的局部范围内靠近标点调整分割，不新增、删除、重复或重写内容。新请求和缓存恢复均使用同一规则。

## 当前文件修复

识别 7 组 / 15 个区域：p2 左右栏、p3→p4、p4 左右栏、p5 左右栏、p5→p6、p6 左右栏，以及 p6→p7→p7 下一栏。真实调用已配置的 DeepSeek 联合翻译，复用其余 526 区域；核对任务缓存仅这 15 个区域译文改变。

第一轮模型仍把“变量投影重要性值”拆成前页“变量投影重要性”、后页“值；FC…”。局部分割修复后第 3 页以“变量投影重要性值；”结束，第 4 页从“FC：倍数变化”继续；拼接后的译文逐字不变。第 4 页的跨栏代谢通路列表也联合翻译。

最终结果在 `output/pdf/metabolic-continuity-repair/Metabolic-衔接修复.pdf`。通过生产 NativeDocumentEngine.rebuildTranslationPDF 写回当前任务、更新完成凭据；之前的 PDF、缓存、任务记录在同目录 `before-repair/` 备份。重启后实际应用显示修复后的第 4/10 页，下载启用。

## 验证

- 严格并发与警告视为错误：261 项相关测试 / 7 个套件通过（`/tmp/transall-obstacle-final-tests.log`）；最终增加缓存分割集成断言后，23 项 / 3 套件通过（`/tmp/transall-obstacle-last-tests.log`）。
- 在真实文献中确认 7 组候选，15 区域已完整保存；输出保持 10 页左右对照。渲染检查第 2–7 页总览、详细查看第 3/4 页，相关文本无重复术语和裁切。
- Swift 格式、XcodeGen 一致性、git diff --check 通过。
- Documents 中 Xcode 工程读取卡在 DVTFilePath.performCoordinatedReadRecursively。停止本次挂起的两个构建进程，将同一份 Sources/Resources/Support/Tests/scripts 复制到 `/tmp/transall-obstacle-release-workspace` 后重新由 project.yml 生成工程，严格 Release 构建通过（`/tmp/transall-obstacle-isolated-release.log`）。安装前逐文件比对生产 Swift 源码与临时构建源码一致。
- 已更新唯一 `/Users/zephyr/Applications/Transall.app`；二进制 SHA256：2a26352dca24df5cb98b5dce5770296bafbf87247d205a5d8d21c705e9818003。旧 App 移入废纸篓并注销，构建 App 移入正式路径。

边界：这次验证针对本篇原生文字双栏论文和明确的接续规则，不等同于所有扫描 OCR、复杂浮动排版或全文翻译质量都已通过。既有图中文字及未涉及接续的段落未作语义重译。
