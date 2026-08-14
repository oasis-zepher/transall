import assert from "node:assert/strict";
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
  assert.match(html, /24 小时后自动清理/);
  assert.match(html, /href="\/privacy"/);
  assert.doesNotMatch(html, /codex-preview|SkeletonPreview|Building your site/);
});

test("server-renders the bilingual privacy policy", async () => {
  const response = await render("/privacy");
  assert.equal(response.status, 200);

  const html = await response.text();
  assert.match(html, /Transall 隐私政策/);
  assert.match(html, /PDF 原文件不会上传/);
  assert.match(html, /Local files and retention/);
  assert.match(html, /macOS Keychain/);
  assert.match(html, /DeepSeek 隐私政策/);
  assert.match(html, /OpenAI 隐私政策/);
  assert.match(html, /个人发布者/);
  assert.match(html, /\[待填写：个人开发者法定姓名\]/);
});

test("server-renders individual publisher information without inventing a legal name", async () => {
  const response = await render("/about");
  assert.equal(response.status, 200);

  const html = await response.text();
  assert.match(html, /安静、明确的本地生产力软件/);
  assert.match(html, /\[待填写：个人开发者法定姓名\]/);
  assert.match(html, /个人开发者法定姓名和公开支持邮箱确认后再发布本页/);
  assert.match(html, /Zephyr 作为品牌使用，不替代 App Store 卖家名称/);
});
