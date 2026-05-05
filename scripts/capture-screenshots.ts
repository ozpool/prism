#!/usr/bin/env node
// Capture UI screenshots for the product walkthrough doc.
//
// Boots a headless Chromium against an already-running `next dev`,
// navigates to each route, and writes PNGs into
// `docs/walkthrough/screenshots/`. The dev server is expected on
// http://localhost:3000 — run `pnpm --filter @prism/web dev` in
// another terminal first, or call this from the wrapper script that
// boots and tears down the server.
//
// For populated states we inject mock data via window so we can
// screenshot the loading / active / vault-detail surfaces without
// needing real deployed contracts.

import {existsSync, mkdirSync} from "node:fs";
import {dirname, join, resolve} from "node:path";
import {fileURLToPath} from "node:url";
import {chromium, type Page} from "playwright";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "..");
const OUT_DIR = join(REPO_ROOT, "docs", "walkthrough", "screenshots");
const BASE_URL = process.env.SCREENSHOT_BASE_URL ?? "http://localhost:3000";

const VIEWPORTS = {
  desktop: {width: 1280, height: 800},
  mobile: {width: 390, height: 844},
} as const;

const MOCK_VAULTS = [
  {
    address: "0x1111111111111111111111111111111111111111",
    pairName: "ETH / USDC",
    versionLabel: "0.3% · v1.0",
    tvlUsd: 4_287_341_290_000n, // $4,287,341.29
    apr24hBps: 1840, // 18.40%
    sharePriceUsd: 1_028_400n, // $1.03
  },
  {
    address: "0x2222222222222222222222222222222222222222",
    pairName: "WBTC / USDC",
    versionLabel: "0.3% · v1.0",
    tvlUsd: 1_624_802_000_000n, // $1,624,802.00
    apr24hBps: 1240, // 12.40%
    sharePriceUsd: 1_018_900n,
  },
  {
    address: "0x3333333333333333333333333333333333333333",
    pairName: "DAI / USDC",
    versionLabel: "0.05% · v1.0",
    tvlUsd: 891_200_530_000n,
    apr24hBps: 410, // 4.10%
    sharePriceUsd: 1_004_300n,
  },
];

interface Shot {
  name: string;
  path: string;
  viewport: "desktop" | "mobile";
  describe: string;
  go: (page: Page) => Promise<void>;
}

const SHOTS: Shot[] = [
  {
    name: "01-home-desktop",
    path: "/",
    viewport: "desktop",
    describe: "Landing page (desktop) — the entry point. Wallet button in the header, primary CTA into /vaults.",
    go: async (page) => {
      await page.goto(`${BASE_URL}/`);
      await page.waitForLoadState("networkidle");
    },
  },
  {
    name: "02-home-mobile",
    path: "/",
    viewport: "mobile",
    describe: "Landing page (mobile) — same content, narrower. Header collapses; nav stays visible.",
    go: async (page) => {
      await page.goto(`${BASE_URL}/`);
      await page.waitForLoadState("networkidle");
    },
  },
  {
    name: "03-vaults-loading",
    path: "/vaults",
    viewport: "desktop",
    describe: "Vaults list — loading state. Renders six skeleton cards while the registry loads.",
    go: async (page) => {
      // Slow the placeholder fetch so we can capture the loading state.
      await page.route("**/*", (route) => route.continue());
      await page.goto(`${BASE_URL}/vaults`);
      // The placeholder fetcher resolves after 300 ms; capture before then.
      await page.waitForSelector("[class*='animate-pulse'], [class*='skeleton']", {timeout: 1_000}).catch(() => {});
    },
  },
  {
    name: "04-vaults-empty",
    path: "/vaults",
    viewport: "desktop",
    describe: "Vaults list — empty state. No vaults deployed yet; CTA links to GitHub + PRD.",
    go: async (page) => {
      await page.goto(`${BASE_URL}/vaults`);
      await page.waitForLoadState("networkidle");
      // Wait for the placeholder fetcher to finish (300 ms) and the
      // empty state to render.
      await page.waitForTimeout(600);
    },
  },
  {
    name: "05-vaults-active",
    path: "/vaults",
    viewport: "desktop",
    describe: "Vaults list — active state with three vaults. This is what users see after the first cohort ships.",
    go: async (page) => {
      // Inject mock vaults by overriding fetchVaultSummaries before
      // the page module loads. We use an init script so the override
      // is in place before any module evaluates.
      // No init script — addInitScript can't serialize BigInts.
      // We DOM-inject after the empty state renders instead.
      await page.goto(`${BASE_URL}/vaults`);
      await page.waitForLoadState("networkidle");
      await page.waitForTimeout(600);

      // The placeholder fetcher returns []. To get the active state in
      // a screenshot, we splice mock cards into the DOM after the
      // empty state renders. This is an inspector-grade hack but is
      // the cleanest way to demo the active layout without forking
      // the source.
      await page.evaluate((vaults) => {
        // Find the section whose first child is the empty-state card,
        // then replace it with a grid of mock cards.
        const section = document.querySelector("section.flex-col");
        if (!section) return;
        const empty = section.querySelector("div.mx-auto");
        if (!empty) return;

        const grid = document.createElement("div");
        grid.className = "grid gap-4 sm:grid-cols-2 lg:grid-cols-3";

        for (const v of vaults as Array<{
          address: string;
          pairName: string;
          versionLabel: string;
          tvlUsd: string;
          apr24hBps: number;
          sharePriceUsd: string;
        }>) {
          const card = document.createElement("a");
          card.href = `/vaults/${v.address}`;
          card.className =
            "group relative flex flex-col gap-4 overflow-hidden rounded-2xl border border-border bg-surface/60 p-5 transition-colors duration-fast ease-standard hover:border-border-strong hover:bg-surface";

          const header = document.createElement("div");
          header.className = "flex items-start justify-between gap-3";
          header.innerHTML = `
            <div class="flex flex-col gap-1">
              <span class="text-base font-semibold text-text">${v.pairName}</span>
              <span class="text-xs text-text-faint">${v.versionLabel}</span>
            </div>
            <span class="rounded-pill border border-spectrum-arc/40 bg-spectrum-arc/10 px-2 py-0.5 text-xs text-spectrum-arc">
              Active
            </span>
          `;

          const stats = document.createElement("div");
          stats.className = "grid grid-cols-3 gap-3 pt-2";
          const tvlNum = BigInt(v.tvlUsd) / 1_000_000n;
          const tvlFmt = tvlNum.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
          const aprFmt = (v.apr24hBps / 100).toFixed(2);
          const spNum = BigInt(v.sharePriceUsd);
          const spWhole = spNum / 1_000_000n;
          const spCents = (spNum % 1_000_000n) / 10_000n;
          const spFmt = `${spWhole.toString()}.${spCents.toString().padStart(2, "0")}`;
          stats.innerHTML = `
            <div class="flex flex-col"><span class="text-xs text-text-faint">TVL</span><span class="text-sm text-text">$${tvlFmt}</span></div>
            <div class="flex flex-col"><span class="text-xs text-text-faint">24h APR</span><span class="text-sm text-spectrum-arc">${aprFmt}%</span></div>
            <div class="flex flex-col"><span class="text-xs text-text-faint">Share</span><span class="text-sm text-text">$${spFmt}</span></div>
          `;

          card.appendChild(header);
          card.appendChild(stats);
          grid.appendChild(card);
        }

        empty.replaceWith(grid);
      },
        MOCK_VAULTS.map((m) => ({
          ...m,
          tvlUsd: m.tvlUsd.toString(),
          sharePriceUsd: m.sharePriceUsd.toString(),
        })));
    },
  },
  {
    name: "06-vault-detail",
    path: "/vaults/0x1111111111111111111111111111111111111111",
    viewport: "desktop",
    describe: "Vault detail — header, PrismVisual chart, Deposit + Withdraw forms side by side.",
    go: async (page) => {
      await page.goto(`${BASE_URL}/vaults/0x1111111111111111111111111111111111111111`);
      await page.waitForLoadState("networkidle");
      await page.waitForTimeout(800);
    },
  },
  {
    name: "07-vault-detail-mobile",
    path: "/vaults/0x1111111111111111111111111111111111111111",
    viewport: "mobile",
    describe: "Vault detail (mobile) — sections stack vertically; Deposit form above Withdraw.",
    go: async (page) => {
      await page.goto(`${BASE_URL}/vaults/0x1111111111111111111111111111111111111111`);
      await page.waitForLoadState("networkidle");
      await page.waitForTimeout(800);
    },
  },
  {
    name: "08-not-found",
    path: "/nonexistent-route",
    viewport: "desktop",
    describe: "404 page — soft routing miss inside the app shell.",
    go: async (page) => {
      await page.goto(`${BASE_URL}/this-route-does-not-exist`);
      await page.waitForLoadState("networkidle");
    },
  },
];

async function main() {
  if (!existsSync(OUT_DIR)) mkdirSync(OUT_DIR, {recursive: true});

  console.log(`Capturing ${SHOTS.length} screenshots to ${OUT_DIR}`);
  const browser = await chromium.launch();

  try {
    for (const shot of SHOTS) {
      const ctx = await browser.newContext({viewport: VIEWPORTS[shot.viewport]});
      const page = await ctx.newPage();
      try {
        await shot.go(page);
        const outPath = join(OUT_DIR, `${shot.name}.png`);
        await page.screenshot({path: outPath, fullPage: true});
        console.log(`  ${shot.name} → ${outPath}`);
      } catch (err) {
        console.error(`  ${shot.name} FAILED`, err);
      } finally {
        await ctx.close();
      }
    }
  } finally {
    await browser.close();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
