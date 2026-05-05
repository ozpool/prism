import type {Metadata} from "next";
import type {ReactNode} from "react";

import {AppShell} from "@/components/AppShell";

import "./globals.css";
import {Providers} from "./providers";

export const metadata: Metadata = {
  title: "PRISM",
  description:
    "Permissionless automated liquidity management on Uniswap V4. One LP deposit refracted into N tick-range positions.",
  icons: {
    icon: "/favicon.ico",
  },
};

export default function RootLayout({children}: {children: ReactNode}) {
  return (
    <html lang="en" className="dark">
      <body className="min-h-screen antialiased">
        <Providers>
          <AppShell>{children}</AppShell>
        </Providers>
      </body>
    </html>
  );
}
