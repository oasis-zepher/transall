import { publicationConfig } from "./publication-config";

type SiteSection = "support" | "privacy" | "about";

const navigation: Array<{ href: string; label: string; section: SiteSection }> = [
  { href: "/", label: "支持", section: "support" },
  { href: "/privacy", label: "隐私", section: "privacy" },
  { href: "/about", label: "关于", section: "about" },
];

export function SiteHeader({ current }: { current: SiteSection }) {
  return (
    <header className="site-header">
      {/* Vinext's production next/link prefetch currently throws before navigation. */}
      {/* eslint-disable-next-line @next/next/no-html-link-for-pages */}
      <a className="wordmark" href="/" aria-label="Transall 支持首页">
        transall
      </a>
      <nav aria-label="主要导航">
        {navigation.map((item) => (
          <a
            key={item.section}
            aria-current={current === item.section ? "page" : undefined}
            href={item.href}
          >
            {item.label}
          </a>
        ))}
      </nav>
    </header>
  );
}

export function SiteFooter({ href, label }: { href: string; label: string }) {
  return (
    <footer>
      <span>© {publicationConfig.copyrightYear} Transall</span>
      <a href={href}>{label}</a>
    </footer>
  );
}
