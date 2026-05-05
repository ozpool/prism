"use client";

import dynamic from "next/dynamic";

import {Logo} from "./Logo";
import {Nav} from "./Nav";

// RainbowKit's ConnectButton calls wagmi hooks at render time, which trips
// Next 14's static prerender (no WagmiProvider context yet, no indexedDB).
// Loading it client-only sidesteps prerender entirely; the button slot
// remains empty until hydration, which is the right UX for wallet UI.
const ConnectButton = dynamic(
  () => import("@rainbow-me/rainbowkit").then((m) => m.ConnectButton),
  {ssr: false},
);

export function Header() {
  return (
    <header className="sticky top-0 z-40 border-b border-border bg-canvas/80 backdrop-blur-md">
      <div className="mx-auto flex h-14 max-w-6xl items-center justify-between gap-4 px-4">
        <div className="flex items-center gap-8">
          <Logo />
          <Nav />
        </div>
        <ConnectButton accountStatus="address" chainStatus="icon" showBalance={false} />
      </div>
    </header>
  );
}
