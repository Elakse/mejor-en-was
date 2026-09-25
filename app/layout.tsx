import type { Metadata, Viewport } from "next";
import { Baloo_2, Nunito } from "next/font/google";
import "./globals.css";

const display = Baloo_2({
  variable: "--font-display",
  subsets: ["latin"],
  weight: ["600", "700", "800"],
});

const body = Nunito({
  variable: "--font-body",
  subsets: ["latin"],
  weight: ["500", "700", "900"],
});

export const metadata: Metadata = {
  title: "Mejor en Was — a two-player hidden character party game",
  description:
    "Two players, two phones. Each of you sees the other's secret character but never your own. Ten rounds of clues, reveals and chaos.",
  appleWebApp: { capable: true, title: "Mejor en Was", statusBarStyle: "black-translucent" },
};

export const viewport: Viewport = {
  themeColor: "#150a2e",
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`${display.variable} ${body.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col overscroll-none font-body text-white">
        {children}
      </body>
    </html>
  );
}
