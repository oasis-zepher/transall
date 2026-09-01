import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  loadPublicationConfig,
  validatePublicationConfig,
} from "../scripts/validate-publication-config.mjs";

function validTemporaryConfig() {
  const token = randomUUID().replaceAll("-", "");
  return {
    legalPublisherName: `Q${token} Z${token}`,
    supportEmail: `support@mail-${token}.com`,
    copyrightYear: "2026",
    privacyEffectiveDate: "2026年8月14日",
  };
}

test("rejects the committed drafting placeholders", async () => {
  const config = await loadPublicationConfig();
  const errors = validatePublicationConfig(config);

  assert.ok(errors.some((error) => error.includes("legalPublisherName") && error.includes("占位")));
  assert.ok(errors.some((error) => error.includes("supportEmail") && error.includes("占位")));
});

test("rejects a brand in place of the individual legal name", () => {
  const errors = validatePublicationConfig({
    ...validTemporaryConfig(),
    legalPublisherName: "Zephyr",
  });

  assert.ok(errors.some((error) => error.includes("品牌 Zephyr")));
});

test("rejects malformed, local, numeric, and reserved support domains", () => {
  for (const supportEmail of [
    "support@example.com",
    "support@localhost",
    "support@publisher.test",
    "support@127.0.0.1",
    "support@invalid_domain.com",
  ]) {
    const errors = validatePublicationConfig({
      ...validTemporaryConfig(),
      supportEmail,
    });
    assert.ok(errors.length > 0, `Expected ${supportEmail} to fail`);
  }
});

test("accepts an uncommitted temporary publication fixture", async (context) => {
  const temporaryDirectory = await mkdtemp(join(tmpdir(), "transall-publication-"));
  context.after(async () => rm(temporaryDirectory, { force: true, recursive: true }));

  const fixturePath = join(temporaryDirectory, "publication-config.json");
  await writeFile(
    fixturePath,
    `${JSON.stringify(validTemporaryConfig(), null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );

  const config = await loadPublicationConfig(fixturePath);
  assert.deepEqual(validatePublicationConfig(config), []);

  const scriptPath = fileURLToPath(
    new URL("../scripts/validate-publication-config.mjs", import.meta.url),
  );
  const result = spawnSync(
    process.execPath,
    [scriptPath, "--config", fixturePath],
    { encoding: "utf8" },
  );
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /发布配置有效/);
});

test("routes publication builds through the dedicated validation gate", async () => {
  const packagePath = new URL("../package.json", import.meta.url);
  const packageConfig = JSON.parse(await readFile(packagePath, "utf8"));

  assert.equal(
    packageConfig.scripts["build:publication"],
    "npm run publication:check && TRANSALL_PUBLICATION_BUILD=1 npm run build && npm run publication:artifact-check",
  );
  assert.equal(
    packageConfig.scripts["publication:check"],
    "node scripts/validate-publication-config.mjs",
  );
});

test("keeps ordinary draft builds outside the Sites deployment format", async () => {
  await assert.rejects(
    readFile(new URL("../dist/.openai/hosting.json", import.meta.url), "utf8"),
    { code: "ENOENT" },
  );
});
