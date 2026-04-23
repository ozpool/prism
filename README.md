# PRISM

> **Liquidity Management Protocol on Uniswap V4** — a permissionless,
> automated LM protocol that refracts a single LP deposit into N tick-range
> positions, rebalances atomically via flash accounting, charges
> volatility-adaptive swap fees, and captures MEV that would otherwise leak
> to external arbitrageurs.

## Overview

PRISM wraps a Uniswap V4 pool in a vault that *refracts* LP capital across
a configurable spectrum of tick-range positions. Where V3-era LM (Gamma,
Arrakis) smoothed day-to-day LP work but remained bottlenecked by
centralized advisors, PRISM uses V4's hook primitive and EIP-1153 flash
accounting to push the entire management loop on-chain:

- **Deposit once** → liquidity distributed across N ticks via a pluggable strategy
- **Rebalance atomically** → all positions remove + redeploy inside a single `PoolManager.unlock()`
- **Volatility-adaptive swap fees** via the `beforeSwap` hook
- **MEV observation / capture** via the `afterSwap` hook
- **Custody-free** — no admin keys on user funds; rebalances are keeper-triggered

## Key Features

- **Refraction.** One deposit → N positions via a pluggable `IStrategy` (Bell, Exponential, OrderBook).
- **Atomic rebalance.** N positions touched, one token transfer per asset via flash accounting.
- **Dynamic fees.** EWMA-volatility-adaptive, computed in `beforeSwap`.
- **Immutable core.** No upgrade proxies; governance is not attack surface.
- **Withdrawals never pausable.** Deposits can be paused (48h timelock); withdraw always works.
- **Composable ERC-20 shares.** No transfer hooks, no share-level fees.
- **On-chain invariants.** Seven formal invariants enforced by Foundry invariant tests.

## Architecture

PRISM is organized into four layers:

```
USER LAYER       LPs · Swappers · Keepers
PRESENTATION     Next.js 14 dApp + wagmi v2 + viem v2 + RainbowKit
PROTOCOL         VaultFactory → Vault → Strategy + ProtocolHook + ChainlinkAdapter
UNISWAP V4       PoolManager (singleton) → Pool (dynamic fee + hook)
OFF-CHAIN INFRA  TypeScript keeper · Tenderly · Sentry
```

Core contracts:

| Contract | Role |
|---|---|
| `Vault` | ERC-20 shares + multi-position aggregator. Owns liquidity inside PoolManager. |
| `VaultFactory` | CREATE2 deploy of vaults per `(PoolKey, Strategy)`. |
| `ProtocolHook` | V4 hook — dynamic fees in `beforeSwap`, MEV observation in `afterSwap`. |
| `BellStrategy` | Default strategy — bell-curve weight distribution. Pure, stateless, deterministic. |
| `ChainlinkAdapter` | Primary oracle with staleness gate. |

Architectural context, seven invariants, gas targets, and risk posture:
[`CLAUDE.md`](./CLAUDE.md). Full spec: [`PRISM_PRD_v1.0.html`](./PRISM_PRD_v1.0.html).

## Development Phases

PRISM ships in six architectural milestones (`M0` → `M5`). Each milestone
is independently demoable — no milestone depends on unfinished work from
the next. Every phase maps to GitHub milestones and the issue backlog.

### M0 · Foundations

Everything else is blocked on M0. Ship this and every downstream track parallelizes.

- Monorepo + Foundry workspace; `v4-core` / `v4-periphery` pinned by commit
- Core interfaces: `IVault`, `IStrategy`, `IProtocolHook`
- Utilities: `Errors.sol`, `ReentrancyGuardTransient.sol`, `PositionLib`, `FeeLib`, `MEVLib`, `HookMiner`
- Design tokens + shadcn-aligned component library (Figma)
- ADRs: hook scoping, oracle strategy, immutable core, strategy purity, flash accounting pattern, gas budget
- Next.js 14 scaffold + wagmi v2 + RainbowKit (Base Sepolia)
- CI: contracts workflow (Foundry + Slither + Aderyn); web + keeper workflows

### M1 · Vault Core

Single-position vault that accepts deposits, issues shares, and honors withdrawals.

- `Vault` storage layout + ERC-20 share accounting
- `deposit()` via `PoolManager.unlock` with slippage bounds
- `withdraw()` with proportional removal across positions — never pausable
- `MIN_SHARES = 1000` burned to `DEAD` on first deposit (inflation-attack mitigation)
- Views: `getPositions`, `getTotalAmounts`, `sharePrice`, TVL cap enforcement
- Unit tests: happy path, reverts, access control, reentrancy probes

### M2 · Strategy System

Multi-position vault with bell-shaped liquidity and atomic rebalance.

- `BellStrategy.computePositions` — pure, deterministic, Gaussian weight distribution
- `BellStrategy.shouldRebalance` — tick-drift + time threshold + 24h keeper-liveness fallback
- `Vault.rebalance` — remove-all → optional internal swap (slippage-bounded) → redeploy in one unlock
- `VaultFactory` with CREATE2 deployment per `(PoolKey, Strategy)`
- Fuzz tests: weight-sum invariant (#2), tick-boundary edges, `MAX_POSITIONS`

### M3 · V4 Hook

Hook-native pool with dynamic fees and MEV observation.

- `ProtocolHook` with `getHookPermissions` + address-bit assertions + `onlyPoolManager`
- `beforeSwap` — EWMA volatility update + dynamic fee override (≤ 12k gas)
- `afterSwap` — oracle read + deviation check + `SwapObserved` event (v1.0 observation only)
- `ChainlinkAdapter` — primary feed with staleness gate (> 1h disables capture)
- Fuzz: hook permission bits, `onlyPoolManager` spoof attempts, gas-budget assertions

### M4 · Integration

End-to-end user flow — wallet → deposit → observe keeper rebalances → withdraw.

- dApp: vault list, vault detail with `PrismVisual`, deposit + withdraw forms
- Shared package: generated ABIs, per-chain addresses, shared types
- Keeper bot: poll loop + `eth_call` simulation gate + tx submission + structured logs
- Invariant suite: all seven PRISM invariants under Foundry fuzz
- Fork tests: Base Sepolia PoolManager integration (deposit → rebalance → withdraw)
- Playwright E2E: happy path + error paths (wrong network, insufficient balance, tx rejection)

### M5 · Launch

Public Base Sepolia testnet — monitored, documented, ready for external LPs.

- `Deploy.s.sol` — full wiring; hook-address mining; pool initialization
- Basescan verification + post-deploy hook-address sanity check
- Keeper deployed to Fly.io with `/health` endpoint + graceful SIGTERM shutdown
- Marketing landing page + dApp on Vercel
- Monitoring: Tenderly alert rules + Sentry (frontend + keeper) + incident runbook
- Docs: README, CONTRIBUTING, SECURITY

Current status: **M0 · Foundations** (in progress).

## Tech Stack

| Concern | Tool |
|---|---|
| Smart contracts | Solidity 0.8.25, Foundry (`via_ir`, `cancun`) |
| V4 dependencies | `v4-core`, `v4-periphery` (pinned by commit) |
| Token utilities | Solmate / Solady |
| Static analysis | Slither + Aderyn |
| Frontend | Next.js 14 App Router, TypeScript (strict), Tailwind, shadcn/ui |
| Web3 | wagmi v2 + viem v2 + RainbowKit v2 |
| Keeper | TypeScript + viem (single-file, poll + simulate + submit) |
| Monorepo | pnpm + Turborepo |
| Deploy | Vercel (web) + Fly.io (keeper) |
| Monitoring | Tenderly + Sentry |

## V4 Dependency Pins

`v4-core`, `v4-periphery`, and `permit2` are pinned by commit SHA in
`.gitmodules`. **Do not bump during the MVP** (PRD §Day 1 anti-goal).

| Submodule | SHA | Date | Version |
|---|---|---|---|
| v4-core | `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` | 2025-05-13 | 1.0.2 (post-v4.0.0) |
| v4-periphery | `9dafaaecc1e2e1e824eda9d941085f96517d827b` | 2026-04-02 | main HEAD at pinning |
| permit2 | `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` | — | transitive dep of v4-periphery |

Remappings (`packages/contracts/remappings.txt`):

```
v4-core/=lib/v4-core/src/
v4-periphery/=lib/v4-periphery/src/
permit2/=lib/permit2/src/
```

### Reason-to-bump policy

Bumping v4 submodules during the MVP is an anti-goal. Bump only when ALL of:

1. A security fix is released and documented by Uniswap.
2. An API required by the PRD is missing from the pinned version.
3. The bump is reviewed via commit diff, compiled against the full test suite,
   and approved in a dedicated ADR commit.

Pinned: 2026-04-23.

## Quick Start

```bash
# Clone
git clone https://github.com/ozpool/prism.git
cd prism

# Install
pnpm install

# Contracts
cd packages/contracts
forge build
forge test -vvv

# Web dApp
cd ../../apps/web
pnpm dev
# http://localhost:3000

# Keeper
cd ../keeper
cp .env.example .env  # fill in Base Sepolia RPC + private key
pnpm dev
```

**Prerequisites:** Node ≥ 18, pnpm ≥ 9, Foundry latest, a Base Sepolia RPC URL.

## Repository Structure

```
prism/
├── apps/
│   ├── web/                 Next.js 14 dApp + marketing
│   └── keeper/              TypeScript + viem keeper bot
├── packages/
│   ├── contracts/           Foundry project (Solidity 0.8.25)
│   │   ├── src/{core,strategies,libraries,oracles,interfaces,utils}
│   │   ├── test/{unit, fuzz, invariants}
│   │   └── script/Deploy.s.sol
│   └── shared/              Auto-generated ABIs, per-chain addresses, shared types
├── scripts/                 ABI export, hook-address verification
├── .github/workflows/       CI pipelines
├── CLAUDE.md                Project architectural context
├── PRISM_PRD_v1.0.html      Full product requirements
└── README.md                (this file)
```

## Testing & Quality Gates

Before any commit or PR:

```bash
# Contracts
forge build
forge fmt --check
forge test -vvv
slither . --config-file slither.config.json
aderyn .

# Web / Keeper
pnpm typecheck
pnpm lint
pnpm test
pnpm playwright test   # E2E (web only)
```

CI enforces these on every PR.

## Networks

| Network | Chain ID | Status |
|---|---|---|
| Base Sepolia | 84532 | Primary testnet (M5 launch target) |
| Base mainnet | 8453 | Post-audit, capped soft-launch (not in v1) |

## Contributing

- Branch from `main`; never amend published commits; never force-push shared branches
- Conventional commits: `feat(vault): ...`, `fix(hook): ...`, `test(strategy): ...`
- Tests must pass locally before opening a PR
- Security-sensitive changes (Vault / Hook / Strategy / Oracle) require a `security-auditor` review before merge

Full contributor guide lives in `CONTRIBUTING.md` (forthcoming, tracked in
issue [#70](../../issues/70)). Responsible disclosure lives in
`SECURITY.md` (issue [#71](../../issues/71)).

## License

- **Core contracts:** BUSL-1.1
- **Libraries:** MIT

## Links

- [Product Requirements Document (v1.0)](./PRISM_PRD_v1.0.html) — complete technical spec
- [Architectural context](./CLAUDE.md) — invariants, risk posture, delegation map
- [Open issues](../../issues) — backlog by milestone and layer
- [Project milestones](../../milestones) — M0 → M5

---

*PRISM — liquidity refracted.*
