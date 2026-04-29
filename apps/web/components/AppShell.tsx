import type {ReactNode} from "react";

import {Footer} from "./Footer";
import {Header} from "./Header";
import {WrongNetworkBanner} from "./WrongNetworkBanner";

export function AppShell({children}: {children: ReactNode}) {
  return (
    <div className="flex min-h-screen flex-col">
      <Header />
      <WrongNetworkBanner />
      <main className="mx-auto w-full max-w-6xl flex-1 px-4 py-8">{children}</main>
      <Footer />
    </div>
  );
}
