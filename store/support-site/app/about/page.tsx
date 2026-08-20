import type { Metadata } from "next";
import { publicationConfig } from "../publication-config";
import { mainContentId, SiteFooter, SiteHeader } from "../site-chrome";

export const metadata: Metadata = {
  title: "关于发布者",
  description: "Transall 产品与发布者信息。",
  openGraph: {
    title: "安静、明确的本地生产力软件",
    description: "Transall 产品与个人发布者信息。",
    images: [],
  },
  twitter: {
    card: "summary",
    title: "安静、明确的本地生产力软件",
    description: "Transall 产品与个人发布者信息。",
    images: [],
  },
};

export default function AboutPublisher() {
  return (
    <div className="site-shell">
      <SiteHeader current="about" />
      <main id={mainContentId} tabIndex={-1}>
        <section className="about-shell" aria-labelledby="about-title">
        <div className="section-index">PUBLISHER / 03</div>
        <div className="about-copy">
          <p className="eyebrow">ABOUT THE PUBLISHER</p>
          <h1 id="about-title">安静、明确的本地生产力软件</h1>
          <p className="lede">
            Transall 面向需要反复整理研究资料、扫描件与日常 PDF 的 Mac 用户。产品把文件处理、错误信息、预览和清理控制放在同一个本地工作台中。
          </p>

          <div className="about-principles">
            <article>
              <span className="topic-number">01</span>
              <h2>本地优先</h2>
              <p>常规文档处理使用 macOS 系统框架在设备上完成。</p>
            </article>
            <article>
              <span className="topic-number">02</span>
              <h2>失败可读</h2>
              <p>任务提供预检、取消、恢复、日志和明确的恢复建议。</p>
            </article>
            <article>
              <span className="topic-number">03</span>
              <h2>边界清楚</h2>
              <p>翻译的网络处理会在运行前说明，密钥保存在钥匙串。</p>
            </article>
          </div>
        </div>

        <aside className="publisher-card" aria-label="发布者资料">
          <p className="eyebrow">LEGAL INFORMATION</p>
          <dl>
            <div>
              <dt>发布者法定姓名</dt>
              <dd>{publicationConfig.legalPublisherName}</dd>
            </div>
            <div>
              <dt>支持邮箱</dt>
              <dd>{publicationConfig.supportEmail}</dd>
            </div>
          </dl>
          <p>个人开发者法定姓名和公开支持邮箱确认后再发布本页。Zephyr 作为品牌使用，不替代 App Store 卖家名称。</p>
        </aside>
        </section>
      </main>
      <SiteFooter href="/privacy" label="隐私政策" />
    </div>
  );
}
