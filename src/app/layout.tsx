import type { Metadata } from "next";

import "./globals.css";

export const metadata: Metadata = {
  title: "Taskforce",
  description: "AI 프로젝트 매니저",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="ko" className="h-full antialiased">
      <body className="flex min-h-full flex-col">{children}</body>
    </html>
  );
}
