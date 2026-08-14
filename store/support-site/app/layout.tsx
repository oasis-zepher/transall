import type { Metadata } from "next";
import { headers } from "next/headers";
import "./globals.css";

const title = "Transall 支持";
const description = "Transall macOS App 的支持、常见问题与隐私说明。";

export async function generateMetadata(): Promise<Metadata> {
  const requestHeaders = await headers();
  const host = requestHeaders.get("x-forwarded-host") ?? requestHeaders.get("host") ?? "localhost";
  const protocol = requestHeaders.get("x-forwarded-proto") ?? (host.startsWith("localhost") ? "http" : "https");
  const baseURL = new URL(`${protocol}://${host}`);
  const previewURL = new URL("/og.png", baseURL).toString();

  return {
    metadataBase: baseURL,
    title: {
      default: title,
      template: "%s · Transall",
    },
    description,
    icons: {
      icon: "/icon.png",
      apple: "/icon.png",
    },
    openGraph: {
      type: "website",
      locale: "zh_CN",
      title,
      description,
      images: [{ url: previewURL, width: 1536, height: 1024, alt: "Transall 本地 PDF 与文档工作台" }],
    },
    twitter: {
      card: "summary_large_image",
      title,
      description,
      images: [previewURL],
    },
  };
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="zh-CN">
      <body>{children}</body>
    </html>
  );
}
