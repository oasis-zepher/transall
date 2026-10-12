# Translation language menus — 2026-09-13

Replaced the source/target code text fields with native menu pickers labeled 原文语言 and 译文语言. Both menus show Chinese language names for 19 choices, including simplified/traditional Chinese, English, Japanese, Korean, French, German, and Spanish. Only the source menu offers automatic detection. New jobs default to `auto` → `zh`; saved job values are retained, including older language variants outside the menu catalog.

Local task capabilities are published before the asynchronous provider/Keychain check. A pending credential check therefore does not hide or disable local language controls. While provider status is pending, its menu names remain visible with 正在检查配置; authentication is still required for translation.

Validation:
- Release build succeeded with strict concurrency and warnings as errors.
- Five existing startup/environment, job-option, and validation tests passed. The blocking-Keychain startup test now verifies that local capabilities remain available without publishing unverified provider status, and cancellation/retry still works.
- In the installed App, opened both menus, selected 原文语言 = 日语 and 译文语言 = 法语, and verified the displayed values. Restored 自动识别 → 简体中文. Target menu contains no automatic-detection option.
- No translation request was sent for this interaction check; it does not validate translation quality for all listed languages.
