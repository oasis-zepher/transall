import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function render(path = "/") {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}-${path}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request(`http://localhost${path}`, {
      headers: { accept: "text/html" },
    }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );
}

test("server-renders the Transall support page", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>Transall 支持<\/title>/i);
  assert.match(html, /本地 PDF 与文档工作台/);
  assert.match(html, /超过 24 小时后，会在启动时及运行期间定期自动清理/);
  assert.match(html, /href="\/privacy"/);
  assert.match(html, /rel="icon" href="\/icon\.png"/);
  assert.match(html, /property="og:image" content="http:\/\/localhost\/og\.png"/);
  assert.match(html, /name="twitter:image" content="http:\/\/localhost\/og\.png"/);
  assert.doesNotMatch(html, /codex-preview|SkeletonPreview|Building your site/);
});

test("server-renders the bilingual privacy policy", async () => {
  const response = await render("/privacy");
  assert.equal(response.status, 200);

  const html = await response.text();
  assert.match(html, /Transall 隐私政策/);
  assert.match(html, /PDF 原文件不会上传/);
  assert.match(html, /任务元数据只保留当前转换实际使用的设置/);
  assert.match(html, /Local files and retention/);
  assert.match(html, /Task metadata retains only settings used by the selected conversion/);
  assert.match(html, /during hourly checks while it remains open/);
  assert.match(html, /macOS Keychain/);
  assert.match(html, /DeepSeek 隐私政策/);
  assert.match(html, /OpenAI 隐私政策/);
  assert.match(html, /个人发布者/);
  assert.match(html, /\[待填写：个人开发者法定姓名\]/);
  assert.match(html, /property="og:title" content="Transall 隐私政策"/);
  assert.match(html, /name="twitter:title" content="Transall 隐私政策"/);
  assert.doesNotMatch(html, /og\.png/);
});

test("keeps repeated site chrome outside the main content landmark", async () => {
  for (const path of ["/", "/privacy", "/about"]) {
    const response = await render(path);
    assert.equal(response.status, 200);
    const html = await response.text();
    const main = html.match(/<main[^>]*>([\s\S]*?)<\/main>/i)?.[1] ?? "";
    assert.ok(main, `Expected a main landmark for ${path}`);
    assert.doesNotMatch(main, /<nav\b/i, `Navigation must be outside main for ${path}`);
    assert.doesNotMatch(main, /<footer\b/i, `Footer must be outside main for ${path}`);
  }
});

test("server-renders individual publisher information without inventing a legal name", async () => {
  const response = await render("/about");
  assert.equal(response.status, 200);

  const html = await response.text();
  assert.match(html, /安静、明确的本地生产力软件/);
  assert.match(html, /\[待填写：个人开发者法定姓名\]/);
  assert.match(html, /个人开发者法定姓名和公开支持邮箱确认后再发布本页/);
  assert.match(html, /Zephyr 作为品牌使用，不替代 App Store 卖家名称/);
  assert.match(html, /property="og:title" content="安静、明确的本地生产力软件"/);
  assert.match(html, /name="twitter:title" content="安静、明确的本地生产力软件"/);
  assert.doesNotMatch(html, /og\.png/);
});

test("support text contrast and navigation targets meet the release baseline", async () => {
  const css = await readFile(new URL("../app/globals.css", import.meta.url), "utf8");
  const paper = css.match(/--paper:\s*(#[0-9a-f]{6})/i)?.[1];
  const muted = css.match(/--muted:\s*(#[0-9a-f]{6})/i)?.[1];
  assert.ok(paper && muted, "Expected paper and muted color tokens");
  assert.ok(contrastRatio(paper, muted) >= 4.5, "Muted text must meet WCAG AA contrast");
  assert.match(css, /nav a\s*{[^}]*min-height:\s*44px/s);
  assert.match(css, /\.language-links a\s*{[^}]*min-height:\s*44px/s);
});

function contrastRatio(first, second) {
  const values = [first, second].map(relativeLuminance).sort((a, b) => b - a);
  return (values[0] + 0.05) / (values[1] + 0.05);
}

function relativeLuminance(hex) {
  const channels = [1, 3, 5].map((offset) => Number.parseInt(hex.slice(offset, offset + 2), 16) / 255);
  const [red, green, blue] = channels.map((channel) =>
    channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4,
  );
  return 0.2126 * red + 0.7152 * green + 0.0722 * blue;
}
