# 文件格式图标组成的立体莫比乌斯环

## 当前修订 v4：简化表面

用户认可 v3 的双环形状，但认为图标过多、画面繁杂。以 v3 为编辑参照，保留双环和中央交叠，将重复小图标简化为四块连续色面，只保留 W、P、X、PDF 各一次，并减少接缝、凸起边框与强反光。

当前概念图为 `format-icons-infinity-v4-simple.png`；使用内置 image_gen 编辑，完整提示词为 `prompt-v4-simplified.txt`。这是待用户评价的概念修订，尚未替换 App 图标。

## 已认可的形状 v3：左右两个环孔

用户明确要求「有两个圈的那种」，现采用横向 ∞ 轮廓：左右两个环孔，中央前后交叠，由 Word、PPT、Excel、PDF 等格式图标构成环带。

当前概念图为 `format-icons-infinity-v3.png`，由内置 image_gen 生成；完整提示词为 `prompt-v3-two-loops.txt`。这是用户指定的视觉轮廓，不以单孔参数曲面限制造型。保留以前版本作为过程记录，尚未替换 App 图标。

## 修订版 v2

`format-icons-mobius-v2.png` 为本轮重做的概念图。先构造标准参数曲面，再将 `geometry-view-c.png` 作为内置 image_gen 的编辑参照，生成材质、厚度和文件图标。完整提示词保存在 `prompt-v2.txt`。

几何参照采用 `((R + v cos(u/2)) cos(u), (R + v cos(u/2)) sin(u), v sin(u/2))`，验证首尾满足 `P(0,v) = P(2π,-v)`，形成一次半扭转。验证结果保存在 `geometry-reference.json`。此数值验证针对参照曲面；最终图像是基于参照的生成图，不等同于经过拓扑验证的三维模型。

## 被否定的初版

根据新的方向生成一张概念图：用 Word、PowerPoint、Excel、PDF、文本和图片格式图标直接连接成扭转的立体环，保留各格式的识别色，并表现前后遮挡和表面厚度。

- 文件：`format-icons-mobius.png`
- 生成方式：内置 image_gen 图像生成工具。
- 完整生成提示词：`prompt.txt`。
- 定位：栅格设计概念，不是可编辑三维模型；几何拓扑未经三维模型验证。
- 原有 App 图标资源未替换。
