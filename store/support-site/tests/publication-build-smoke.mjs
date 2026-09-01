import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { access, cp, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

const sourceRoot = fileURLToPath(new URL("..", import.meta.url));
const temporaryRoot = await mkdtemp(join(tmpdir(), "transall-publication-build-"));
const checkout = join(temporaryRoot, "support-site");
const excludedTopLevelPaths = new Set([
  ".next",
  ".wrangler",
  "dist",
  "node_modules",
  "outputs",
  "work",
]);

try {
  await cp(sourceRoot, checkout, {
    recursive: true,
    filter(source) {
      const pathFromRoot = relative(sourceRoot, source);
      const topLevelPath = pathFromRoot.split(sep)[0];
      return !excludedTopLevelPaths.has(topLevelPath) && !basename(source).startsWith(".env");
    },
  });
  await symlink(join(sourceRoot, "node_modules"), join(checkout, "node_modules"), "dir");

  const token = randomUUID().replaceAll("-", "");
  const temporaryConfig = {
    legalPublisherName: `Q${token} Z${token}`,
    supportEmail: `support@mail-${token}.com`,
    copyrightYear: "2026",
    privacyEffectiveDate: "2026年8月14日",
  };
  await writeFile(
    join(checkout, "app/publication-config.json"),
    `${JSON.stringify(temporaryConfig, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );

  const result = spawnSync("npm", ["run", "build:publication"], {
    cwd: checkout,
    encoding: "utf8",
    env: process.env,
    maxBuffer: 10 * 1024 * 1024,
  });
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  await access(join(checkout, "dist/.openai/hosting.json"));
  assert.match(result.stdout, /发布配置有效/);
  assert.match(result.stdout, /包含有效的 Sites 部署清单/);
  console.log("Temporary publication build passed without committing identity data.");
} finally {
  await rm(temporaryRoot, { force: true, recursive: true });
}
