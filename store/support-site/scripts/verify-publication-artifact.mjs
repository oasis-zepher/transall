import { readFile } from "node:fs/promises";

const hostingArtifact = new URL("../dist/.openai/hosting.json", import.meta.url);

try {
  const config = JSON.parse(await readFile(hostingArtifact, "utf8"));
  if (!("d1" in config) || !("r2" in config)) {
    throw new Error("部署清单缺少 d1 或 r2 声明。");
  }
  console.log("支持站点发布构建包含有效的 Sites 部署清单。");
} catch (error) {
  console.error(`支持站点发布构建无效：${error.message}`);
  process.exitCode = 1;
}
