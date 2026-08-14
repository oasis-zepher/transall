import type { Metadata } from "next";
import { publicationConfig } from "../publication-config";
import { SiteFooter, SiteHeader } from "../site-chrome";

export const metadata: Metadata = {
  title: "隐私政策",
  description: "Transall 的本地文件处理、翻译服务、数据保留和 API Key 存储说明。",
  openGraph: {
    title: "Transall 隐私政策",
    description: "Transall 的本地文件处理、翻译服务、数据保留和 API Key 存储说明。",
    images: [],
  },
  twitter: {
    card: "summary",
    title: "Transall 隐私政策",
    description: "Transall 的本地文件处理、翻译服务、数据保留和 API Key 存储说明。",
    images: [],
  },
};

export default function PrivacyPolicy() {
  return (
    <div className="site-shell">
      <SiteHeader current="privacy" />
      <main>
        <article className="policy-shell">
        <header className="policy-title">
          <div className="section-index">PRIVACY / 02</div>
          <div>
            <p className="eyebrow">PRIVACY POLICY</p>
            <h1>Transall 隐私政策</h1>
            <p className="lede">
              生效日期：{publicationConfig.privacyEffectiveDate}。Transall 默认在 Mac 本机处理文档，不要求注册账号，不包含广告、分析统计或跨 App 跟踪。
            </p>
          </div>
          <div className="language-links" aria-label="语言">
            <a href="#zh">中文</a>
            <a href="#en">English</a>
          </div>
        </header>

        <section id="zh" className="policy-content" lang="zh-CN" aria-labelledby="zh-title">
          <h2 id="zh-title">中文</h2>

          <section>
            <h3>1. 适用范围</h3>
            <p>
              本政策说明 Transall macOS App 如何处理用户选择的文件、任务数据和翻译服务凭据。Transall 不运营用户账号系统，也不设置开发者控制的分析、广告或遥测服务。
            </p>
          </section>

          <section>
            <h3>2. 文件与任务数据</h3>
            <p>
              PDF 整理、OCR、文字提取和格式转换在 Mac 本机完成。App 会在自身容器内保存工作副本、结果、预览和日志，用于完成任务及恢复未完成任务。任务元数据只保留当前转换实际使用的设置，不会把其他转换路径中填写的术语表、水印等内容附带到该任务。任务数据超过 24 小时后，会在启动 App 时及 App 运行期间定期自动删除；正在处理的任务不会被运行期清理。用户也可以在结果区立即删除。原始文件不会被删除或覆盖。
            </p>
          </section>

          <section>
            <h3>3. 翻译服务</h3>
            <p>
              只有用户主动执行翻译任务时，Transall 才会将翻译所需的文档文字直接发送给用户选择的 DeepSeek 或 OpenAI。PDF 原文件不会上传。服务商会按照其各自的条款和隐私政策处理这些文字；Transall 开发者不会接收翻译内容。
            </p>
            <p className="policy-links">
              <a href="https://cdn.deepseek.com/policies/zh-CN/deepseek-privacy-policy.html">
                DeepSeek 隐私政策
              </a>
              <a href="https://openai.com/policies/privacy-policy/">OpenAI 隐私政策</a>
            </p>
          </section>

          <section>
            <h3>4. API Key</h3>
            <p>
              DeepSeek 与 OpenAI API Key 保存在 macOS 钥匙串中，不写入项目文件、任务文件或日志。凭据只用于向用户选择的服务商发起翻译请求。用户可以随时在 Transall 设置中将其从钥匙串删除。
            </p>
          </section>

          <section>
            <h3>5. 开发者收集的数据</h3>
            <p>
              Transall 不向开发者服务器上传文件、任务日志、API Key、设备标识符或使用情况。App 不进行广告追踪，也不出售或共享用户数据用于广告。
            </p>
          </section>

          <section>
            <h3>6. 用户选择与删除</h3>
            <p>
              用户可以不配置任何翻译服务，只使用全部本地功能；可以删除当前任务数据；可以在设置中删除 API Key；也可以从 Mac 删除 Transall，从而删除其 App 容器内的数据。
            </p>
          </section>

          <section>
            <h3>7. 联系方式与变更</h3>
            <p>
              政策发生实质变化时，发布日期和内容会在本页更新。隐私问题可通过下方支持邮箱联系发布者。
            </p>
            <dl className="publisher-fields">
              <div>
                <dt>个人发布者</dt>
                <dd>{publicationConfig.legalPublisherName}</dd>
              </div>
              <div>
                <dt>邮箱</dt>
                <dd>{publicationConfig.supportEmail}</dd>
              </div>
            </dl>
          </section>
        </section>

        <section id="en" className="policy-content policy-english" lang="en" aria-labelledby="en-title">
          <h2 id="en-title">English</h2>

          <section>
            <h3>1. Scope</h3>
            <p>
              This policy explains how the Transall macOS app handles files, task data, and translation credentials. Transall has no user account system and no developer-controlled advertising, analytics, or telemetry service.
            </p>
          </section>

          <section>
            <h3>2. Local files and retention</h3>
            <p>
              PDF editing, OCR, text extraction, and format conversion run locally on the Mac. Working copies, results, previews, and logs stay in the app container. Task metadata retains only settings used by the selected conversion; values entered for other routes, such as a glossary or watermark, are not carried into that local task. Task data more than 24 hours old is removed when the app launches and during hourly checks while it remains open; active processing is retained. Users can also delete the current task immediately. Original files are never deleted or overwritten.
            </p>
          </section>

          <section>
            <h3>3. Translation providers</h3>
            <p>
              Only when the user starts a translation task does Transall send the required extracted text directly to the selected DeepSeek or OpenAI service. The original PDF is not uploaded. Each provider processes that text under its own terms and privacy policy; the Transall publisher does not receive the translation content.
            </p>
          </section>

          <section>
            <h3>4. API credentials</h3>
            <p>
              DeepSeek and OpenAI API keys are stored in the macOS Keychain. They are not written to project files, task data, or logs, and can be removed at any time in Transall Settings.
            </p>
          </section>

          <section>
            <h3>5. Developer data collection</h3>
            <p>
              Transall does not send files, task logs, API keys, device identifiers, or usage data to a developer server. It does not track users or sell data for advertising.
            </p>
          </section>

          <section>
            <h3>6. Contact</h3>
            <dl className="publisher-fields">
              <div>
                <dt>Individual Publisher</dt>
                <dd>{publicationConfig.legalPublisherName}</dd>
              </div>
              <div>
                <dt>Email</dt>
                <dd>{publicationConfig.supportEmail}</dd>
              </div>
            </dl>
          </section>
        </section>
        </article>
      </main>
      <SiteFooter href="/" label="返回支持首页" />
    </div>
  );
}
