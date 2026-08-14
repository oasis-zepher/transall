import Link from "next/link";
import { publicationConfig } from "./publication-config";

const topics = [
  {
    number: "01",
    title: "文件是否会上传？",
    body: "PDF 整理、OCR、文字提取和格式转换都在 Mac 本机完成。只有主动执行翻译时，提取出的文字会发送给你选择的服务商。",
  },
  {
    number: "02",
    title: "任务文件保存多久？",
    body: "工作副本、结果、预览和日志保存在 Transall 的 App 容器内，24 小时后自动清理，也可以在结果区立即删除。",
  },
  {
    number: "03",
    title: "API Key 存在哪里？",
    body: "DeepSeek 与 OpenAI API Key 保存在 macOS 钥匙串，不会写入任务文件、项目文件或日志。",
  },
];

export default function SupportHome() {
  return (
    <main>
      <header className="site-header">
        <Link className="wordmark" href="/" aria-label="Transall 支持首页">
          transall
        </Link>
        <nav aria-label="主要导航">
          <Link aria-current="page" href="/">
            支持
          </Link>
          <Link href="/privacy">隐私</Link>
          <Link href="/about">关于</Link>
        </nav>
      </header>

      <section className="support-intro" aria-labelledby="support-title">
        <div className="section-index">SUPPORT / 01</div>
        <div>
          <p className="eyebrow">LOCAL DOCUMENT WORKBENCH</p>
          <h1 id="support-title">Transall 支持</h1>
          <p className="lede">
            面向 macOS 的本地 PDF 与文档工作台。这里汇总数据处理方式、常见问题和联系入口。
          </p>
        </div>
        <aside className="status-note" aria-label="系统要求">
          <span className="status-dot" aria-hidden="true" />
          <div>
            <strong>macOS 14 或更高版本</strong>
            <span>无需注册 Transall 账号</span>
          </div>
        </aside>
      </section>

      <section className="topic-grid" aria-label="常见问题">
        {topics.map((topic) => (
          <article key={topic.number}>
            <span className="topic-number">{topic.number}</span>
            <h2>{topic.title}</h2>
            <p>{topic.body}</p>
          </article>
        ))}
      </section>

      <section className="help-block" aria-labelledby="help-title">
        <div>
          <p className="eyebrow">TROUBLESHOOTING</p>
          <h2 id="help-title">任务失败时</h2>
        </div>
        <ol>
          <li>确认文件类型与圆形路由中选择的源格式一致。</li>
          <li>翻译失败时检查网络、API Key、服务余额和服务商状态。</li>
          <li>保留结果区的错误信息与运行日志，联系支持时一并提供；不要发送 API Key。</li>
        </ol>
      </section>

      <section className="contact-strip" aria-labelledby="contact-title">
        <div>
          <p className="eyebrow">CONTACT</p>
          <h2 id="contact-title">联系支持</h2>
        </div>
        <p>团队域名邮箱将在发布前填写。请勿使用 QQ 或个人 Gmail 作为正式支持地址。</p>
        <span className="pending-field">{publicationConfig.supportEmail}</span>
      </section>

      <footer>
        <span>© {publicationConfig.copyrightYear} Transall</span>
        <Link href="/privacy">隐私政策</Link>
      </footer>
    </main>
  );
}
