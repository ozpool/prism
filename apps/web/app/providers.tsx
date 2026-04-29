"use client";

import "@rainbow-me/rainbowkit/styles.css";

import {RainbowKitProvider, darkTheme} from "@rainbow-me/rainbowkit";
import {QueryClient, QueryClientProvider} from "@tanstack/react-query";
import {useState, type ReactNode} from "react";
import {WagmiProvider} from "wagmi";

import {wagmiConfig} from "@/lib/wagmi";

// PRISM-themed RainbowKit modal — keeps wallet UI visually consistent with
// the brand-token palette defined in app/tokens.css.
const prismRainbowTheme = darkTheme({
  accentColor: "#7c5cff", // --color-spectrum-violet
  accentColorForeground: "#0c0a14", // --color-canvas (high contrast on violet)
  borderRadius: "medium",
  fontStack: "system",
  overlayBlur: "small",
});

/**
 * Top-level web3 provider tree.
 *
 * Order matters:
 *   1. WagmiProvider — owns the wallet config + connectors.
 *   2. QueryClientProvider — wagmi v2 reads/writes via TanStack Query.
 *   3. RainbowKitProvider — provides wallet UI and theme.
 *
 * The `QueryClient` is constructed inside a `useState` initialiser so
 * Next.js / React 18 Strict Mode does not produce a fresh client on
 * every render (which would invalidate every cache entry).
 */
export function Providers({children}: {children: ReactNode}) {
  const [queryClient] = useState(() => new QueryClient());

  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider theme={prismRainbowTheme} modalSize="compact">
          {children}
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
