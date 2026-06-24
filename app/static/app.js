const form = document.querySelector("#jobForm");
const kind = document.querySelector("#kind");
const log = document.querySelector("#log");
const jobState = document.querySelector("#jobState");
const download = document.querySelector("#download");
const preview = document.querySelector("#preview");
const providerStatus = document.querySelector("#providerStatus");
const refreshPreview = document.querySelector("#refreshPreview");
const submitButton = document.querySelector("#submitButton");
const routeLine = document.querySelector("#routeLine");
const routeTitle = document.querySelector("#routeTitle");
const routeStatus = document.querySelector("#routeStatus");
const routeKind = document.querySelector("#routeKind");
const routeSummary = document.querySelector("#routeSummary");
const routeInput = document.querySelector("#routeInput");
const routeOutput = document.querySelector("#routeOutput");
const diagnosticsList = document.querySelector("#diagnosticsList");
const formTitle = document.querySelector("#formTitle");
const sourcePick = document.querySelector("#sourcePick");
const targetPick = document.querySelector("#targetPick");
const coreStatus = document.querySelector("#coreStatus");
const resetRoute = document.querySelector("#resetRoute");
const formatNodes = [...document.querySelectorAll(".format-node")];
const formatOrbit = document.querySelector(".format-orbit");
const routeSlots = [...document.querySelectorAll("[data-route-slot]")];
const filesInput = document.querySelector("#files");
const dropzone = document.querySelector("#dropzone");
const fileList = document.querySelector("#fileList");
const fileCount = document.querySelector("#fileCount");
const slotTitle = document.querySelector("#slotTitle");
const slotHint = document.querySelector("#slotHint");
const emptyOutput = document.querySelector("#emptyOutput");
const shell = document.querySelector(".shell");
const glossaryInput = document.querySelector("#glossary");

let currentJob = null;
let sourceFormat = null;
let targetFormat = null;
let activeRoute = null;
let selectedFiles = [];
let isSubmitting = false;
let routeEnterTimer = null;
let routeSettledTimer = null;
let nodeSettledTimer = null;
let pointerDragState = null;
let slotDragState = null;
let suppressNextNodeClick = false;
let suppressClickUntil = 0;
let hasOpenedRoutePage = false;
let diagnosticsByName = {};
let diagnosticsReady = false;

const ROUTE_ENTER_DELAY_MS = 180;
const ROUTE_ANIMATION_MS = 900;
const NODE_SETTLE_MS = 420;
const POINTER_DRAG_THRESHOLD = 6;
const CLICK_SUPPRESS_MS = 450;
const GLOSSARY_STORAGE_KEY = "proteuswitch.translate.glossary";
const TEXT_SELECTION_CLASS = "is-format-dragging";

const formats = {
  pdf: { label: "PDF", input: ".pdf", detail: "PDF 文档" },
  word: { label: "Word", input: ".doc,.docx", detail: "Word 文档" },
  ppt: { label: "PPT", input: ".ppt,.pptx", detail: "PowerPoint 幻灯片" },
  excel: { label: "Excel", input: ".xls,.xlsx", detail: "Excel 表格" },
  md: { label: "Markdown", input: ".md,.markdown", detail: "Markdown 文本" },
  html: { label: "HTML", input: ".html,.htm", detail: "HTML 页面" },
  image: { label: "Image", input: ".png,.jpg,.jpeg,.webp,.tif,.tiff", detail: "图片文件" },
  data: {
    label: "Data",
    input: ".txt,.text,.csv,.json,.xml,.yaml,.yml,.zip,.epub",
    pdfInput: ".txt,.text,.csv,.json,.xml,.yaml,.yml",
    detail: "文本、表格、结构化数据或归档文件",
  },
  translated_pdf: { label: "中文PDF", input: ".pdf", detail: "翻译后的 PDF" },
  ocr: { label: "OCR", input: ".pdf,.png,.jpg,.jpeg,.webp,.tif,.tiff", detail: "OCR 结果" },
};

const routeCopy = {
  convert: {
    kindLabel: "转 PDF",
    output: "输出为 PDF，可下载并预览前 12 页。",
    summary: "使用本地转换引擎生成 PDF。Office 走 LibreOffice，图片走本地合成，Markdown/HTML/文本数据走 Playwright 排版。",
  },
  extract_markdown: {
    kindLabel: "转 Markdown",
    output: "输出为 Markdown，目标是结构化文本，不承诺版式保真。",
    summary: "使用 MarkItDown 插件化抽取文档结构，适合知识库、摘要和后续文本处理。",
  },
  pdf_edit: {
    kindLabel: "PDF 修改",
    output: "输出为新的 PDF，原文件不会被覆盖。",
    summary: "支持合并、删除页、旋转、水印和文字查找替换。内容级编辑不是 Word 式自由编辑。",
  },
  pdf_translate: {
    kindLabel: "PDF 翻译",
    output: "输出为纯译文 PDF 或双语对照 PDF。",
    summary: "优先使用 BabelDOC 做版式保真翻译，失败后回退到 pdf2zh，再回退到基础文本重建。扫描件请先走 OCR。",
  },
  ocr: {
    kindLabel: "OCR",
    output: "输出为可搜索 PDF 或纯文本。",
    summary: "使用本机 Tesseract 识别 PDF 或图片中的文字。适合扫描件、截图和图片型 PDF。",
  },
};

function formatLabel(format) {
  return formats[format]?.label || format || "";
}

function resolveRoute(source, target) {
  if (!source || !target) return null;
  if (source === "pdf" && target === "translated_pdf") {
    return {
      kind: "pdf_translate",
      title: "PDF → 中文PDF",
      enabled: true,
      accept: formats.pdf.input,
      input: formats.pdf.detail,
      ...routeCopy.pdf_translate,
    };
  }
  if (target === "ocr" && ["pdf", "image"].includes(source)) {
    return {
      kind: "ocr",
      title: `${formatLabel(source)} → OCR`,
      enabled: true,
      accept: formats[source].input,
      input: formats[source].detail,
      ...routeCopy.ocr,
    };
  }
  if (target === "md" && ["pdf", "image"].includes(source)) {
    return {
      kind: "extract_markdown",
      title: `${formatLabel(source)} → Markdown`,
      enabled: true,
      accept: formats[source].input,
      input: formats[source].detail,
      ocrFallback: true,
      ...routeCopy.extract_markdown,
    };
  }
  if (target === "pdf" && source !== "pdf") {
    return {
      kind: "convert",
      title: `${formatLabel(source)} → PDF`,
      enabled: true,
      accept: formats[source].pdfInput || formats[source].input,
      input: formats[source].detail,
      ...routeCopy.convert,
    };
  }
  if (target === "md" && source !== "md") {
    return {
      kind: "extract_markdown",
      title: `${formatLabel(source)} → Markdown`,
      enabled: true,
      accept: formats[source].input,
      input: formats[source].detail,
      ...routeCopy.extract_markdown,
    };
  }
  if (source === "pdf" && target === "pdf") {
    return {
      kind: "pdf_edit",
      title: "PDF → PDF",
      enabled: true,
      accept: formats.pdf.input,
      input: formats.pdf.detail,
      ...routeCopy.pdf_edit,
    };
  }
  return {
    kind: "convert",
    title: `${formatLabel(source)} → ${formatLabel(target)}`,
    enabled: false,
    accept: formats[source]?.input || "",
    input: formats[source]?.detail || "未知格式",
    output: "该路径第一版未接入。",
    summary: "当前支持：常见文档/图片/文本数据转 PDF，常见文档/数据转 Markdown，PDF 修改，PDF 翻译为中文PDF，PDF/图片 OCR。",
    kindLabel: "未接入",
  };
}

function optionsForKind() {
  if (kind.value === "pdf_edit") {
    return {
      action: value("#editAction"),
      delete_pages: value("#deletePages"),
      rotate_pages: value("#rotatePages"),
      rotate_degrees: Number(value("#rotateDegrees") || 90),
      replace_find: value("#replaceFind"),
      replace_with: value("#replaceWith"),
      watermark: value("#watermark"),
    };
  }
  if (kind.value === "pdf_translate") {
    return {
      provider: value("#provider"),
      output_mode: value("#outputMode"),
      source_lang: value("#sourceLang") || "en",
      target_lang: value("#targetLang") || "zh",
      glossary: value("#glossary"),
    };
  }
  if (kind.value === "ocr") {
    return {
      language: value("#ocrLanguage") || "chi_sim+eng",
      output_format: value("#ocrOutputFormat") || "searchable_pdf",
    };
  }
  if (kind.value === "extract_markdown") {
    return {
      ocr_fallback: Boolean(activeRoute?.ocrFallback),
      ocr_language: value("#ocrLanguage") || "chi_sim+eng",
    };
  }
  return {};
}

function value(selector) {
  return document.querySelector(selector)?.value?.trim() || "";
}

function refreshControls() {
  activeRoute = resolveRoute(sourceFormat, targetFormat);
  if (activeRoute) {
    kind.value = activeRoute.kind;
  }

  document.querySelectorAll("[data-panel]").forEach((el) => {
    const isOcrPanel = el.dataset.panel === "ocr" && kind.value === "ocr";
    const show = el.dataset.panel === "edit" && kind.value === "pdf_edit"
      || el.dataset.panel === "translate" && kind.value === "pdf_translate"
      || isOcrPanel
      || el.dataset.panel === "ocr" && activeRoute?.ocrFallback;
    el.dataset.hidden = show ? "false" : "true";
  });

  updateRouteUi();
  updateFileUi();
}

function routeAvailabilityForCandidate(candidate) {
  if (sourceFormat && !targetFormat) {
    return resolveRoute(sourceFormat, candidate)?.enabled === true;
  }
  if (!sourceFormat && targetFormat) {
    return resolveRoute(candidate, targetFormat)?.enabled === true;
  }
  return null;
}

function updateRouteUi() {
  if (!activeRoute && !hasOpenedRoutePage) {
    shell.classList.remove("is-route-active", "is-route-entering");
  }
  formatNodes.forEach((node) => {
    const candidate = node.dataset.format;
    const availability = routeAvailabilityForCandidate(candidate);
    const isAssigned = [sourceFormat, targetFormat].includes(candidate);
    node.classList.toggle("is-source", node.dataset.format === sourceFormat);
    node.classList.toggle("is-target", node.dataset.format === targetFormat);
    node.classList.toggle("is-assigned", isAssigned);
    node.classList.toggle("is-route-available", availability === true && !isAssigned);
    node.classList.toggle("is-route-unavailable", availability === false && !isAssigned);
    node.setAttribute("aria-pressed", isAssigned ? "true" : "false");
  });
  routeSlots.forEach((slot) => {
    const isSourceSlot = slot.dataset.routeSlot === "source";
    const slotFormat = isSourceSlot ? sourceFormat : targetFormat;
    const canReuseFormat = !slotFormat && (isSourceSlot ? targetFormat : sourceFormat);
    slot.classList.toggle("is-filled", Boolean(slotFormat));
    slot.classList.toggle("can-reuse-format", Boolean(canReuseFormat));
    slot.dataset.format = slotFormat || "";
    slot.setAttribute(
      "aria-label",
      slotFormat
        ? `${isSourceSlot ? "源" : "目标"}格式槽，点击清空`
        : canReuseFormat
          ? `${isSourceSlot ? "源" : "目标"}格式槽，点击复用另一侧格式`
          : `${isSourceSlot ? "源" : "目标"}格式槽`
    );
  });

  sourcePick.textContent = sourceFormat ? formatLabel(sourceFormat) : "";
  targetPick.textContent = targetFormat ? formatLabel(targetFormat) : "";

  if (!activeRoute) {
    routeLine.textContent = "选择源格式和目标格式";
    routeTitle.textContent = "未选择";
    routeSummary.textContent = "把格式模块拖到上下两个槽位。上方是源格式，下方是目标格式。";
    routeStatus.textContent = "等待选择";
    routeStatus.className = "";
    routeKind.textContent = "未定";
    routeInput.textContent = sourceFormat ? formats[sourceFormat].detail : "选择源格式后显示";
    routeOutput.textContent = "选择目标格式后显示";
    formTitle.textContent = "选择路径后上传";
    coreStatus.textContent = sourceFormat ? "继续选择" : "";
    submitButton.disabled = true;
    filesInput.accept = sourceFormat ? formats[sourceFormat].input : "";
    renderDiagnostics();
    return;
  }

  routeLine.textContent = activeRoute.title;
  routeTitle.textContent = activeRoute.title;
  routeSummary.textContent = activeRoute.summary;
  routeStatus.textContent = activeRoute.enabled ? "可用" : "未接入";
  routeStatus.className = activeRoute.enabled ? "is-ready" : "is-warning";
  routeKind.textContent = activeRoute.kindLabel;
  routeInput.textContent = activeRoute.input;
  routeOutput.textContent = activeRoute.output;
  formTitle.textContent = activeRoute.enabled ? activeRoute.kindLabel : "路径未接入";
  coreStatus.textContent = activeRoute.kindLabel;
  const canSubmit = activeRoute.enabled && !isSubmitting && missingRequiredDependencies().length === 0;
  submitButton.disabled = !canSubmit;
  filesInput.accept = activeRoute.accept;
  renderDiagnostics();

  if (!activeRoute.enabled) {
    log.textContent = "该转换路径第一版未接入。可选：转 PDF、转 Markdown、PDF → PDF。";
  } else if (log.textContent.startsWith("该转换路径")) {
    log.textContent = "等待任务。";
  }
}

function dependenciesForRoute(route = activeRoute) {
  if (!route || !route.enabled) return [];
  if (route.kind === "convert") {
    if (["word", "ppt", "excel"].includes(sourceFormat)) return [{ name: "libreoffice", required: true }];
    if (["md", "html", "data"].includes(sourceFormat)) return [{ name: "playwright", required: true }];
    return [];
  }
  if (route.kind === "extract_markdown") {
    if (sourceFormat === "image") return [{ name: "tesseract", required: true }];
    if (sourceFormat === "pdf") {
      return [
        { name: "markitdown", required: "one-of-markdown" },
        { name: "tesseract", required: "one-of-markdown" },
      ];
    }
    return [{ name: "markitdown", required: true }];
  }
  if (route.kind === "ocr") return [{ name: "tesseract", required: true }];
  if (route.kind === "pdf_translate") {
    return [
      { name: value("#provider") || "deepseek", required: true },
      { name: "babeldoc", required: false },
      { name: "pdf2zh", required: false },
    ];
  }
  return [];
}

function missingRequiredDependencies() {
  if (!diagnosticsReady) return [];
  const requirements = dependenciesForRoute();
  const markdownFallback = requirements.filter((item) => item.required === "one-of-markdown");
  const missing = requirements.filter((item) => item.required === true && !diagnosticsByName[item.name]?.available);
  if (markdownFallback.length && !markdownFallback.some((item) => diagnosticsByName[item.name]?.available)) {
    missing.push(...markdownFallback);
  }
  return missing;
}

function renderDiagnostics() {
  if (!diagnosticsList) return;
  diagnosticsList.innerHTML = "";
  if (!activeRoute || !activeRoute.enabled) return;
  const requirements = dependenciesForRoute();
  if (!requirements.length) {
    diagnosticsList.textContent = "该路径不需要额外外部引擎。";
    return;
  }
  if (!diagnosticsReady) {
    diagnosticsList.textContent = "正在检测本机依赖。";
    return;
  }
  requirements.forEach((requirement) => {
    const dependency = diagnosticsByName[requirement.name] || {};
    const item = document.createElement("div");
    const available = Boolean(dependency.available);
    item.className = `diagnostic-item ${available ? "is-ready" : "is-missing"} ${requirement.required === false ? "is-optional" : ""}`;
    const status = available ? "可用" : requirement.required === false ? "可选缺失" : "缺失";
    item.innerHTML = `
      <strong>${dependency.label || requirement.name}</strong>
      <span>${status}</span>
      <small>${available ? dependency.detail || "" : dependency.install_hint || "请安装对应依赖"}</small>
    `;
    diagnosticsList.appendChild(item);
  });
}

function updateFileUi() {
  selectedFiles = [...filesInput.files];
  fileCount.textContent = `${selectedFiles.length} file${selectedFiles.length === 1 ? "" : "s"}`;
  slotTitle.textContent = activeRoute?.enabled ? `上传 ${activeRoute.input}` : "放入文件";
  slotHint.textContent = activeRoute?.enabled
    ? `接受：${activeRoute.accept || "任意文件"}`
    : "先选择一个已支持的转换路径";

  fileList.innerHTML = "";
  selectedFiles.slice(0, 6).forEach((file) => {
    const item = document.createElement("li");
    const name = document.createElement("span");
    const size = document.createElement("small");
    name.textContent = file.name;
    size.textContent = formatBytes(file.size);
    item.append(name, size);
    fileList.appendChild(item);
  });
  if (selectedFiles.length > 6) {
    const item = document.createElement("li");
    item.textContent = `另有 ${selectedFiles.length - 6} 个文件`;
    fileList.appendChild(item);
  }
}

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB"];
  let value = bytes / 1024;
  let index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  return `${value.toFixed(value >= 10 ? 0 : 1)} ${units[index]}`;
}

async function loadProviders() {
  const res = await fetch("/api/config/providers");
  const data = await res.json();
  const ready = data.providers.filter((p) => p.configured).map((p) => p.name).join(", ");
  providerStatus.textContent = ready ? `已配置: ${ready}` : "未配置翻译密钥";
}

async function loadDiagnostics() {
  try {
    const res = await fetch("/api/diagnostics");
    const data = await res.json();
    diagnosticsByName = Object.fromEntries((data.dependencies || []).map((dependency) => [dependency.name, dependency]));
    diagnosticsReady = true;
  } catch (error) {
    diagnosticsByName = {};
    diagnosticsReady = false;
  }
  refreshControls();
}

async function submitJob(event) {
  event.preventDefault();
  if (!activeRoute || !activeRoute.enabled) {
    log.textContent = "请先选择一个已支持的转换路径。";
    return;
  }
  if (!filesInput.files.length) {
    log.textContent = "请选择文件。";
    return;
  }

  const data = new FormData();
  data.append("kind", kind.value);
  data.append("options", JSON.stringify(optionsForKind()));
  [...filesInput.files].forEach((file) => data.append("files", file));

  isSubmitting = true;
  submitButton.disabled = true;
  submitButton.textContent = "运行中";
  jobState.textContent = "上传中";
  jobState.className = "job-state";
  log.textContent = "上传文件并创建任务。";
  download.hidden = true;
  emptyOutput.hidden = false;
  preview.innerHTML = "";

  const res = await fetch("/api/jobs", { method: "POST", body: data });
  const job = await res.json();
  currentJob = job.id;
  if (!res.ok) {
    isSubmitting = false;
    submitButton.textContent = "开始任务";
    refreshControls();
    jobState.textContent = "失败";
    jobState.classList.add("is-error");
    log.textContent = job.detail || "任务创建失败。";
    return;
  }
  renderJob(job);
  pollJob(job.id);
}

async function pollJob(jobId) {
  for (;;) {
    const res = await fetch(`/api/jobs/${jobId}`);
    const job = await res.json();
    renderJob(job);
    if (["done", "failed"].includes(job.status)) {
      isSubmitting = false;
      submitButton.textContent = "开始任务";
      refreshControls();
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 900));
  }
}

function renderJob(job) {
  jobState.textContent = job.status;
  jobState.className = `job-state ${job.status === "done" ? "is-ready" : ""} ${job.status === "failed" ? "is-error" : ""}`;
  log.textContent = [...(job.logs || []), job.error ? `ERROR: ${job.error}` : ""].filter(Boolean).join("\n") || "任务运行中。";
  if (job.output && job.status === "done") {
    download.href = `/api/jobs/${job.id}/download`;
    download.hidden = false;
    emptyOutput.hidden = true;
    loadPreview(job.id);
  }
}

async function loadPreview(jobId) {
  const res = await fetch(`/api/jobs/${jobId}/preview/pages`);
  if (!res.ok) return;
  const data = await res.json();
  preview.innerHTML = "";
  data.pages.forEach((page) => {
    const img = document.createElement("img");
    img.alt = `Page ${page.page}`;
    img.src = `${page.url}?t=${Date.now()}`;
    preview.appendChild(img);
  });
}

function clearRouteTimers() {
  window.clearTimeout(routeEnterTimer);
  window.clearTimeout(routeSettledTimer);
  routeEnterTimer = null;
  routeSettledTimer = null;
}

function clearSettlingNodes() {
  window.clearTimeout(nodeSettledTimer);
  nodeSettledTimer = null;
  formatNodes.forEach((node) => node.classList.remove("is-settling"));
}

function markSettlingNodes(...formatsToSettle) {
  clearSettlingNodes();
  const selectedFormats = new Set(formatsToSettle.filter(Boolean));
  formatNodes.forEach((node) => {
    node.classList.toggle("is-settling", selectedFormats.has(node.dataset.format));
  });
  nodeSettledTimer = window.setTimeout(clearSettlingNodes, NODE_SETTLE_MS);
}

function enterRoutePage() {
  clearRouteTimers();
  if (hasOpenedRoutePage || shell.classList.contains("is-route-active")) {
    updateRoutePageWithoutTransition();
    return;
  }
  hasOpenedRoutePage = true;
  shell.classList.remove("is-route-active");
  shell.classList.add("is-route-entering");
  routeEnterTimer = window.setTimeout(() => {
    shell.classList.add("is-route-active");
    routeSettledTimer = window.setTimeout(() => {
      shell.classList.remove("is-route-entering");
    }, ROUTE_ANIMATION_MS);
  }, ROUTE_ENTER_DELAY_MS);
}

function updateRoutePageWithoutTransition() {
  clearRouteTimers();
  shell.classList.add("is-route-active");
  shell.classList.remove("is-route-entering");
}

function returnToHomeState() {
  clearRouteTimers();
  clearSettlingNodes();
  shell.classList.remove("is-route-active", "is-route-entering");
}

function finalizeRouteSelection() {
  refreshControls();
  if (sourceFormat && targetFormat) {
    enterRoutePage();
  } else if (hasOpenedRoutePage) {
    updateRoutePageWithoutTransition();
  }
}

function assignFormatToSlot(slotName, selected) {
  if (!selected || !formats[selected]) return;
  if (!hasOpenedRoutePage && !targetFormat && slotName === "source") {
    returnToHomeState();
  }
  if (slotName === "source") {
    sourceFormat = selected;
  } else if (slotName === "target") {
    targetFormat = selected;
  }
  markSettlingNodes(sourceFormat, targetFormat);
  finalizeRouteSelection();
}

function clearFormatSlot(slotName) {
  if (slotName === "source") {
    sourceFormat = null;
  } else if (slotName === "target") {
    targetFormat = null;
  }
  log.textContent = "等待任务。";
  finalizeRouteSelection();
}

function reuseOppositeSlotFormat(slotName) {
  const formatToReuse = slotName === "source" ? targetFormat : sourceFormat;
  if (!formatToReuse) return false;
  assignFormatToSlot(slotName, formatToReuse);
  return true;
}

function swapFilledSlots() {
  if (!sourceFormat || !targetFormat) return;
  const previousSource = sourceFormat;
  sourceFormat = targetFormat;
  targetFormat = previousSource;
  markSettlingNodes(sourceFormat, targetFormat);
  finalizeRouteSelection();
}

function slotFromPoint(x, y) {
  const geometryMatch = routeSlots.find((slot) => {
    const rect = slot.getBoundingClientRect();
    return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
  });
  if (geometryMatch) return geometryMatch;
  return document.elementsFromPoint(x, y)
    .map((element) => element.closest?.("[data-route-slot]"))
    .find(Boolean) || null;
}

function updateDragOverSlot(activeSlot) {
  routeSlots.forEach((slot) => {
    slot.classList.toggle("is-drag-over", slot === activeSlot);
  });
}

function createDragProxy(node, rect) {
  const proxy = document.createElement("div");
  proxy.className = "drag-proxy";
  proxy.style.width = `${rect.width}px`;
  proxy.style.height = `${rect.height}px`;
  proxy.style.setProperty("--node-color", node.style.getPropertyValue("--node-color"));
  proxy.innerHTML = node.innerHTML;
  document.body.appendChild(proxy);
  return proxy;
}

function createSlotDragProxy(slot, rect) {
  const proxy = document.createElement("div");
  proxy.className = "drag-proxy slot-drag-proxy";
  proxy.style.width = `${rect.width}px`;
  proxy.style.height = `${rect.height}px`;
  proxy.style.setProperty("--node-color", getComputedStyle(slot).getPropertyValue("--slot-color").trim() || "var(--accent)");
  proxy.innerHTML = slot.innerHTML;
  document.body.appendChild(proxy);
  return proxy;
}

function moveDragProxy(x, y) {
  if (!pointerDragState?.proxy) return;
  pointerDragState.proxy.style.transform = `translate3d(${x - pointerDragState.width / 2}px, ${y - pointerDragState.height / 2}px, 0)`;
}

function moveSlotDragProxy(x, y) {
  if (!slotDragState?.proxy) return;
  slotDragState.proxy.style.transform = `translate3d(${x - slotDragState.width / 2}px, ${y - slotDragState.height / 2}px, 0)`;
}

function blockTextSelection() {
  document.body.classList.add(TEXT_SELECTION_CLASS);
  window.getSelection?.()?.removeAllRanges();
}

function unblockTextSelection() {
  if (pointerDragState || slotDragState) return;
  document.body.classList.remove(TEXT_SELECTION_CLASS);
  window.getSelection?.()?.removeAllRanges();
}

function finishPointerDrag(x, y) {
  if (!pointerDragState) return;
  const { node, format, proxy, started, pointerId } = pointerDragState;
  const slot = started ? slotFromPoint(x, y) : null;
  node.classList.remove("is-pointer-dragging");
  if (node.hasPointerCapture?.(pointerId)) {
    node.releasePointerCapture(pointerId);
  }
  proxy?.remove();
  updateDragOverSlot(null);
  pointerDragState = null;
  unblockTextSelection();
  if (slot) {
    assignFormatToSlot(slot.dataset.routeSlot, format);
  }
}

function startPointerDrag(node, event) {
  if (event.pointerType === "mouse" && event.button !== 0) return;
  event.preventDefault();
  blockTextSelection();
  const rect = node.getBoundingClientRect();
  pointerDragState = {
    node,
    format: node.dataset.format,
    startX: event.clientX,
    startY: event.clientY,
    pointerId: event.pointerId,
    width: rect.width,
    height: rect.height,
    started: false,
    proxy: null,
  };
  node.setPointerCapture?.(event.pointerId);
}

function startSlotDrag(slot, event) {
  if (!slot.classList.contains("is-filled")) return;
  if (event.pointerType === "mouse" && event.button !== 0) return;
  event.preventDefault();
  blockTextSelection();
  const rect = slot.getBoundingClientRect();
  slotDragState = {
    slot,
    slotName: slot.dataset.routeSlot,
    format: slot.dataset.format,
    startX: event.clientX,
    startY: event.clientY,
    pointerId: event.pointerId,
    width: rect.width,
    height: rect.height,
    started: false,
    proxy: null,
  };
  slot.setPointerCapture?.(event.pointerId);
}

function updatePointerDrag(event) {
  if (!pointerDragState) return;
  event.preventDefault();
  const deltaX = event.clientX - pointerDragState.startX;
  const deltaY = event.clientY - pointerDragState.startY;
  const distance = Math.hypot(deltaX, deltaY);
  if (!pointerDragState.started && distance < POINTER_DRAG_THRESHOLD) return;
  if (!pointerDragState.started) {
    pointerDragState.started = true;
    pointerDragState.node.classList.add("is-pointer-dragging");
    pointerDragState.proxy = createDragProxy(pointerDragState.node, pointerDragState.node.getBoundingClientRect());
  }
  moveDragProxy(event.clientX, event.clientY);
  updateDragOverSlot(slotFromPoint(event.clientX, event.clientY));
}

function updateSlotDrag(event) {
  if (!slotDragState) return;
  event.preventDefault();
  const deltaX = event.clientX - slotDragState.startX;
  const deltaY = event.clientY - slotDragState.startY;
  const distance = Math.hypot(deltaX, deltaY);
  if (!slotDragState.started && distance < POINTER_DRAG_THRESHOLD) return;
  if (!slotDragState.started) {
    slotDragState.started = true;
    slotDragState.slot.classList.add("is-slot-dragging");
    slotDragState.proxy = createSlotDragProxy(slotDragState.slot, slotDragState.slot.getBoundingClientRect());
  }
  moveSlotDragProxy(event.clientX, event.clientY);
  updateDragOverSlot(slotFromPoint(event.clientX, event.clientY));
}

function endPointerDrag(event) {
  if (!pointerDragState) return;
  const wasDragging = pointerDragState.started;
  if (wasDragging) {
    event.preventDefault();
    suppressClicksTemporarily();
  }
  finishPointerDrag(event.clientX, event.clientY);
}

function finishSlotDrag(x, y) {
  if (!slotDragState) return;
  const { slot, slotName, format, proxy, started, pointerId } = slotDragState;
  const targetSlot = started ? slotFromPoint(x, y) : null;
  slot.classList.remove("is-slot-dragging");
  if (slot.hasPointerCapture?.(pointerId)) {
    slot.releasePointerCapture(pointerId);
  }
  proxy?.remove();
  updateDragOverSlot(null);
  slotDragState = null;
  unblockTextSelection();
  if (!started) return;
  if (targetSlot) {
    if (targetSlot === slot) return;
    if (targetSlot.classList.contains("is-filled")) {
      swapFilledSlots();
      return;
    }
    assignFormatToSlot(targetSlot.dataset.routeSlot, format);
  } else {
    clearFormatSlot(slotName);
  }
}

function endSlotDrag(event) {
  if (!slotDragState) return;
  const wasDragging = slotDragState.started;
  if (wasDragging) {
    event.preventDefault();
    suppressClicksTemporarily();
  }
  finishSlotDrag(event.clientX, event.clientY);
}

function suppressClicksTemporarily() {
  suppressNextNodeClick = true;
  suppressClickUntil = performance.now() + CLICK_SUPPRESS_MS;
  window.setTimeout(() => {
    if (performance.now() >= suppressClickUntil) {
      suppressNextNodeClick = false;
      suppressClickUntil = 0;
    }
  }, CLICK_SUPPRESS_MS + 30);
}

function hasActiveClickSuppression() {
  return suppressNextNodeClick || performance.now() < suppressClickUntil;
}

function shouldSuppressSyntheticClick(event) {
  if (!hasActiveClickSuppression()) return false;
  event?.preventDefault();
  event?.stopImmediatePropagation();
  return true;
}

function chooseFormat(selected) {
  if (!sourceFormat || sourceFormat && targetFormat) {
    if (!hasOpenedRoutePage) {
      returnToHomeState();
    }
    sourceFormat = selected;
    targetFormat = null;
    markSettlingNodes(sourceFormat);
  } else if (sourceFormat === selected && !targetFormat) {
    if (!hasOpenedRoutePage) {
      returnToHomeState();
    }
    sourceFormat = null;
  } else {
    targetFormat = selected;
    markSettlingNodes(sourceFormat, targetFormat);
  }
  finalizeRouteSelection();
}

formatNodes.forEach((node) => {
  node.addEventListener("click", (event) => {
    event.stopPropagation();
    if (shouldSuppressSyntheticClick(event)) return;
    chooseFormat(node.dataset.format);
  });
  node.addEventListener("pointerdown", (event) => {
    startPointerDrag(node, event);
  });
});

document.addEventListener("pointermove", updatePointerDrag);
document.addEventListener("pointermove", updateSlotDrag);
document.addEventListener("pointerup", endPointerDrag);
document.addEventListener("pointerup", endSlotDrag);
document.addEventListener("pointercancel", endPointerDrag);
document.addEventListener("pointercancel", endSlotDrag);
document.addEventListener("click", (event) => {
  shouldSuppressSyntheticClick(event);
}, true);

formatOrbit.addEventListener("click", (event) => {
  if (shouldSuppressSyntheticClick(event)) return;
  const node = event.target.closest(".format-node")
    || document.elementsFromPoint(event.clientX, event.clientY).find((element) => element.classList?.contains("format-node"));
  if (!node) return;
  chooseFormat(node.dataset.format);
});

resetRoute.addEventListener("click", () => {
  sourceFormat = null;
  targetFormat = null;
  hasOpenedRoutePage = false;
  filesInput.value = "";
  log.textContent = "等待任务。";
  returnToHomeState();
  refreshControls();
});

routeSlots.forEach((slot) => {
  slot.addEventListener("click", (event) => {
    event.stopPropagation();
    if (shouldSuppressSyntheticClick(event)) return;
    if (slot.classList.contains("is-filled")) {
      clearFormatSlot(slot.dataset.routeSlot);
      return;
    }
    if (slot.classList.contains("can-reuse-format")) {
      reuseOppositeSlotFormat(slot.dataset.routeSlot);
    }
  });
  slot.addEventListener("keydown", (event) => {
    if (!["Enter", " "].includes(event.key)) return;
    if (!slot.classList.contains("is-filled") && !slot.classList.contains("can-reuse-format")) return;
    event.preventDefault();
    if (slot.classList.contains("is-filled")) {
      clearFormatSlot(slot.dataset.routeSlot);
      return;
    }
    reuseOppositeSlotFormat(slot.dataset.routeSlot);
  });
  slot.addEventListener("pointerdown", (event) => {
    startSlotDrag(slot, event);
  });
});

filesInput.addEventListener("change", updateFileUi);
document.querySelector("#provider")?.addEventListener("change", refreshControls);
document.querySelector("#ocrLanguage")?.addEventListener("input", refreshControls);

dropzone.addEventListener("dragenter", () => dropzone.classList.add("is-dragging"));
dropzone.addEventListener("dragover", (event) => {
  event.preventDefault();
  dropzone.classList.add("is-dragging");
});
dropzone.addEventListener("dragleave", () => dropzone.classList.remove("is-dragging"));
dropzone.addEventListener("drop", (event) => {
  event.preventDefault();
  dropzone.classList.remove("is-dragging");
  if (event.dataTransfer?.files?.length) {
    filesInput.files = event.dataTransfer.files;
    updateFileUi();
  }
});

form.addEventListener("submit", submitJob);
refreshPreview.addEventListener("click", () => currentJob && loadPreview(currentJob));

function loadStoredGlossary() {
  if (!glossaryInput) return;
  glossaryInput.value = localStorage.getItem(GLOSSARY_STORAGE_KEY) || "";
}

function saveStoredGlossary() {
  if (!glossaryInput) return;
  localStorage.setItem(GLOSSARY_STORAGE_KEY, glossaryInput.value);
}

glossaryInput?.addEventListener("input", saveStoredGlossary);
loadStoredGlossary();
refreshControls();
loadProviders();
loadDiagnostics();
