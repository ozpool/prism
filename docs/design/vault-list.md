# Vault List Page — Layout + Card States

The vault list (`/vaults` route or `/` for v1.0) is the primary entry
point for the dApp. This doc locks the layout and the four card states
the implementation in #49 must handle.

Pairs with [`docs/design/component-library.md`](./component-library.md)
(`Card`, `Skeleton`, `Badge`, `Button`).

## Page layout

```
┌─────────────────────────────────────────────────────────────┐
│ HEADER (sticky, blurred)                                    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Vaults                                                     │
│  ─────────────────────────                                  │
│  Earn fees + MEV by depositing into a permissionless        │
│  ALM vault on Uniswap V4.                                   │
│                                                             │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐                        │
│  │ Vault   │ │ Vault   │ │ Vault   │     ← responsive grid  │
│  │ card    │ │ card    │ │ card    │                        │
│  └─────────┘ └─────────┘ └─────────┘                        │
│                                                             │
│  ┌─────────┐ ┌─────────┐                                    │
│  │ Vault   │ │ Vault   │                                    │
│  │ card    │ │ card    │                                    │
│  └─────────┘ └─────────┘                                    │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│ FOOTER                                                      │
└─────────────────────────────────────────────────────────────┘
```

**Responsive breakpoints:**

- `< 640px` (mobile): 1-column grid, `gap-3`
- `640–1024px` (tablet): 2-column grid, `gap-4`
- `> 1024px` (desktop): 3-column grid, `gap-4`

**Container:** `max-w-6xl mx-auto px-4 py-8` — same width as the app
shell `<main>`.

**Page header block:**

- Title: `Vaults`, `text-3xl font-semibold tracking-tight`
- Description: `text-text-muted text-base max-w-2xl`
- Above the grid by 24px (`mb-6`)

## Card states

The `VaultCard` component renders one of four states based on the data
fetcher's status. Implementation must handle all four — no silent UI
that hides errors.

### State 1 — Active (success)

```
┌──────────────────────────────────────┐
│ ⬡ WETH / USDC                  [v1] │  ← Vault icon + name + badge
│ ────────────────────────────────────│
│                                      │
│  $1,234,567.89                       │  ← TVL (display 40px)
│  Total value locked                  │
│                                      │
│  APR  12.4%      Share  $1.0421     │  ← metrics row
│                                      │
│  [Deposit  →]                        │  ← primary CTA
└──────────────────────────────────────┘
```

**Anatomy:**

- Header row: token-pair icon, pair name (`text-base font-medium`), version Badge (`accent`)
- Divider: `border-t border-border` between header and body
- Hero metric: TVL — `text-display`, mono. Subtitle below in `text-sm text-text-muted`
- Two-column metrics: APR (24h trailing), share price. Each cell:
  - Label: `text-xs text-text-faint uppercase tracking-wide`
  - Value: `text-base font-medium font-mono`
- CTA: full-width `Button[primary]` with arrow glyph
- Hover: `shadow-glow-violet`, slight `translate-y-[-2px]`
- Whole card is a Next `<Link>` to `/vaults/<address>`; CTA is decorative
  but conveys affordance (clicking anywhere on the card navigates)

**Accessibility:**

- Card is a single anchor — wrap the whole `<Card>` in `<Link>` rather
  than nesting interactive elements
- TVL value has `aria-label="TVL: 1,234,567 dollars"` to spell out the
  formatted number

### State 2 — Loading (skeleton)

```
┌──────────────────────────────────────┐
│ ▓▓▓▓▓▓▓▓▓▓▓▓                    ▓▓▓ │  ← skeleton blocks for header
│ ────────────────────────────────────│
│                                      │
│  ▓▓▓▓▓▓▓▓▓▓▓▓                       │  ← TVL skeleton (w-32 h-10)
│  ▓▓▓▓▓▓▓▓▓                          │  ← subtitle skeleton (w-24 h-4)
│                                      │
│  ▓▓▓▓ ▓▓▓▓     ▓▓▓▓▓ ▓▓▓▓▓         │  ← metrics skeleton
│                                      │
│  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓     │  ← CTA skeleton (h-10 full-width)
└──────────────────────────────────────┘
```

**Rules:**

- Skeleton shapes match the loaded layout — never use generic blocks
- `aria-busy="true"` on the card root
- `prefers-reduced-motion: reduce` disables the pulse animation
- Show skeleton for at least 200ms even if data loads faster — avoids
  flicker (debounce in the data layer, not in the card)

### State 3 — Error (load failed)

```
┌──────────────────────────────────────┐
│ ⬡ WETH / USDC                  [v1] │
│ ────────────────────────────────────│
│                                      │
│  ⚠ Couldn't load vault data         │  ← warning icon + danger text
│                                      │
│  We retried twice. Check your        │
│  network and try again.              │
│                                      │
│  [Retry]                             │  ← Button[secondary]
└──────────────────────────────────────┘
```

**Rules:**

- Same card chrome (header + divider) as Active so users see *which*
  vault failed
- Body uses `text-danger` for the headline
- Retry button calls the data fetcher's refetch — does not navigate
- Card is NOT wrapped in Link in this state — the whole card surface is
  not interactive
- Failure persists until manual retry; no auto-retry loop in the UI

### State 4 — Empty (no vaults)

This applies to the *page*, not an individual card — when the registry
returns 0 vaults.

```
┌─────────────────────────────────────────────┐
│                                             │
│           ⬡   No vaults yet                 │
│                                             │
│   Vaults are created by the factory.        │
│   The first cohort lands with M5 launch.    │
│                                             │
│   [Read the docs  ↗]   [GitHub  ↗]         │
│                                             │
└─────────────────────────────────────────────┘
```

**Rules:**

- Centred in the grid container, max-width 480px
- Pulsing prism logo (decorative)
- Two outline buttons: external links to docs + GitHub
- No "Create vault" CTA in v1.0 — vault creation is keeper / factory
  responsibility, not an end-user flow

## Data contract

The page fetcher returns:

```ts
type VaultListState =
  | { kind: "loading" }
  | { kind: "empty" }
  | { kind: "error"; error: Error; retry: () => void }
  | { kind: "active"; vaults: VaultSummary[] };

type VaultSummary = {
  address: Address;
  pairName: string;        // "WETH / USDC"
  versionLabel: string;    // "v1"
  tvlUsd: bigint;          // 6-decimal USDC scale
  apr24hBps: number;       // 1240 = 12.40%
  sharePriceUsd: bigint;   // 6-decimal USDC scale
};
```

The discriminated union forces every consumer to handle all four states
at type level — `VaultCard` is rendered for the array of summaries, and
the page-level skeleton/error/empty replace the grid entirely.

## What this doc does not specify

- Sort order — comes with #49 implementation; default is descending TVL
- Filtering — out of scope for v1.0
- Pagination — out of scope for v1.0 (assume <50 vaults at launch)
- Real APR formula — defined in PRD; this doc is layout-only
