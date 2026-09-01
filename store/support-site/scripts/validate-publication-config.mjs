import { readFile } from "node:fs/promises";
import { isIP } from "node:net";
import { resolve } from "node:path";
import { domainToASCII, fileURLToPath, pathToFileURL } from "node:url";

const defaultConfigPath = fileURLToPath(
  new URL("../app/publication-config.json", import.meta.url),
);

const placeholderPattern =
  /(?:待填写|待定|占位|示例|样例|测试专用|\b(?:todo|tbd|placeholder|example|sample)\b|\byour[\s_-]*(?:name|email|domain)\b|\blegal[\s_-]*name\b)/iu;
const placeholderBrackets = new Set(["[", "]", "【", "】", "{", "}", "<", ">"]);
const reservedDomains = new Set([
  "example.com",
  "example.net",
  "example.org",
  "localhost",
]);
const reservedDomainSuffixes = [
  ".example",
  ".invalid",
  ".internal",
  ".local",
  ".localhost",
  ".onion",
  ".test",
];

export async function loadPublicationConfig(configPath = defaultConfigPath) {
  const source = await readFile(configPath, "utf8");

  try {
    return JSON.parse(source);
  } catch (error) {
    throw new Error(`发布配置不是有效 JSON：${error.message}`);
  }
}

export function validatePublicationConfig(config) {
  const errors = [];

  if (!config || typeof config !== "object" || Array.isArray(config)) {
    return ["发布配置必须是一个 JSON 对象。"];
  }

  const legalName = validatePlainField(
    config.legalPublisherName,
    "legalPublisherName",
    120,
    errors,
  );
  const supportEmail = validatePlainField(
    config.supportEmail,
    "supportEmail",
    254,
    errors,
  );
  const copyrightYear = validatePlainField(
    config.copyrightYear,
    "copyrightYear",
    4,
    errors,
  );
  const effectiveDate = validatePlainField(
    config.privacyEffectiveDate,
    "privacyEffectiveDate",
    64,
    errors,
  );

  if (legalName) {
    if (legalName.toLocaleLowerCase("en-US") === "zephyr") {
      errors.push("legalPublisherName 必须填写个人开发者的法定姓名，不能只填写品牌 Zephyr。");
    }
    if (/[@/:]/u.test(legalName)) {
      errors.push("legalPublisherName 必须是姓名，不能是邮箱、网址或路径。");
    }
  }

  if (supportEmail) {
    validateSupportEmail(supportEmail, errors);
  }

  if (copyrightYear && !/^20\d{2}$/u.test(copyrightYear)) {
    errors.push("copyrightYear 必须是四位年份，例如 2026。");
  }

  if (effectiveDate && !/20\d{2}/u.test(effectiveDate)) {
    errors.push("privacyEffectiveDate 必须包含四位年份。");
  }

  return errors;
}

function validatePlainField(value, field, maximumLength, errors) {
  if (typeof value !== "string") {
    errors.push(`${field} 必须是字符串。`);
    return null;
  }

  const normalized = value.trim();
  if (!normalized) {
    errors.push(`${field} 不能为空。`);
    return null;
  }
  if (normalized !== value) {
    errors.push(`${field} 不能带有首尾空白。`);
  }
  if ([...normalized].length > maximumLength) {
    errors.push(`${field} 不能超过 ${maximumLength} 个字符。`);
  }
  if (containsControlCharacter(normalized)) {
    errors.push(`${field} 不能包含控制字符。`);
  }
  if (
    placeholderPattern.test(normalized) ||
    [...normalized].some((character) => placeholderBrackets.has(character))
  ) {
    errors.push(`${field} 仍是占位值。`);
  }

  return normalized;
}

function containsControlCharacter(value) {
  return [...value].some((character) => {
    const codePoint = character.codePointAt(0) ?? 0;
    return codePoint <= 0x1f || (codePoint >= 0x7f && codePoint <= 0x9f);
  });
}

function validateSupportEmail(email, errors) {
  const separator = email.lastIndexOf("@");
  if (separator <= 0 || separator !== email.indexOf("@")) {
    errors.push("supportEmail 必须是单一、完整的邮箱地址。");
    return;
  }

  const localPart = email.slice(0, separator);
  const domain = email.slice(separator + 1);
  if (
    localPart.length > 64 ||
    localPart.startsWith(".") ||
    localPart.endsWith(".") ||
    localPart.includes("..") ||
    !/^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+$/iu.test(localPart)
  ) {
    errors.push("supportEmail 的邮箱名称部分无效。");
  }

  const asciiDomain = domainToASCII(domain).toLocaleLowerCase("en-US");
  const labels = asciiDomain.split(".");
  const domainIsReserved =
    reservedDomains.has(asciiDomain) ||
    reservedDomainSuffixes.some((suffix) => asciiDomain.endsWith(suffix));
  const labelsAreValid = labels.every(
    (label) =>
      label.length > 0 &&
      label.length <= 63 &&
      /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/u.test(label),
  );
  const topLevelDomain = labels.at(-1) ?? "";
  const topLevelDomainIsValid =
    /^[a-z]{2,63}$/u.test(topLevelDomain) ||
    /^xn--[a-z0-9-]{2,59}$/u.test(topLevelDomain);

  if (
    !asciiDomain ||
    asciiDomain.length > 253 ||
    isIP(asciiDomain) !== 0 ||
    labels.length < 2 ||
    !labelsAreValid ||
    !topLevelDomainIsValid
  ) {
    errors.push("supportEmail 必须使用格式有效的公共域名，不能使用本地名称或 IP 地址。");
  } else if (domainIsReserved) {
    errors.push("supportEmail 不能使用保留、示例或仅供文档使用的域名。");
  }
}

function configPathFromArguments(arguments_) {
  if (arguments_.length === 0) {
    return defaultConfigPath;
  }
  if (arguments_.length === 2 && arguments_[0] === "--config") {
    return resolve(arguments_[1]);
  }
  throw new Error("用法：node scripts/validate-publication-config.mjs [--config <path>]");
}

async function main() {
  const configPath = configPathFromArguments(process.argv.slice(2));
  const config = await loadPublicationConfig(configPath);
  const errors = validatePublicationConfig(config);

  if (errors.length > 0) {
    console.error(`支持站点发布检查失败：\n- ${errors.join("\n- ")}`);
    process.exitCode = 1;
    return;
  }

  console.log("支持站点发布配置有效。");
}

const entryPath = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : "";
if (import.meta.url === entryPath) {
  main().catch((error) => {
    console.error(`支持站点发布检查失败：${error.message}`);
    process.exitCode = 1;
  });
}
