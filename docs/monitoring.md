# PRISM Monitoring Setup

Configuration of Tenderly alerts and Sentry projects for the testnet launch. This doc is the source of truth for what should exist in those external systems; create or update them by hand against this spec.

## Sentry

Two projects, both under the `prism` org:

| Project slug | SDK | What it captures |
|---|---|---|
| `prism-web` | `@sentry/nextjs` | Browser render errors, route boundary errors, server-side route handler errors |
| `prism-keeper` | `@sentry/node` | Unhandled exceptions, poll-loop errors, shutdown failures |

### Project settings

For each project:

- **Sample rate**: 100% errors, 0% performance traces. PRISM is low-volume; we want everything.
- **Issue grouping**: default fingerprinting. Override for known noisy errors (e.g. `connectorChanged` from RainbowKit on locale switch).
- **Inbound filters**: drop browser errors from the `MetaMaskRPC` transport when the user rejects a tx — that's not an app bug.
- **Releases**: `SENTRY_RELEASE` env var (set to git sha at deploy time). Wired via `withSentryConfig` for the web app and `initSentry({release})` for the keeper.

### Alert rules (Sentry)

| Name | Trigger | Channel |
|---|---|---|
| keeper crash | `prism-keeper`: any unresolved issue with tag `phase:startup` or `phase:shutdown` | #prism-incidents |
| keeper poll spike | `prism-keeper`: >5 events/hour for any single issue | #prism-incidents |
| frontend boundary spike | `prism-web`: >10 events/hour with tag `boundary:global` | #prism-engineering |
| stuck on a release | any project: same issue persisting across 3 consecutive releases | #prism-engineering |

## Tenderly

One project per chain (`prism-base-sepolia`, `prism-base` once mainnet ships). Watched contracts: VaultFactory + every deployed Vault + ProtocolHook + ChainlinkAdapter.

### Watched contracts

Imported from `addresses.json`. Re-run import after each post-deploy:

```bash
pnpm post-deploy --chain base-sepolia   # writes addresses.json
# Then in Tenderly: Project → Contracts → Import via JSON
```

### Alert rules (Tenderly)

Each rule routes to the same channel as the corresponding Sentry alert (start with one Slack channel; split when volume justifies).

| Name | Filter | Channel |
|---|---|---|
| **Vault rebalance reverted** | Failed transactions where `to` matches any deployed Vault and the called function selector is `rebalance(...)` | #prism-incidents |
| **Vault deposit reverted** | Failed transactions where the called function is `deposit(...)` and the caller is not a known dust account | #prism-incidents |
| **Vault withdraw reverted** | Failed transactions where the called function is `withdraw(...)` | #prism-incidents (SEV-1: withdraw should never revert per invariant 6) |
| **Oracle staleness** | Successful `read()` calls on `ChainlinkAdapter` whose returned `stale` flag is `true` for >15 min continuous | #prism-engineering |
| **Hook bypassed** | Successful `swap` against a watched pool where the hook's `afterSwap` did not fire (compare event count to swap count over a 1h window) | #prism-incidents |
| **Keeper inactive** | No tx from the keeper EOA against the factory or any vault for >10 minutes during a known-active window | #prism-engineering |

### Channel routing

- Slack via Tenderly's built-in integration (one webhook per channel).
- Email fallback for SEV-1 channels in case Slack is down.

### Drill procedure

Once per quarter, intentionally trigger a low-stakes revert (e.g. call `deposit` with insufficient allowance from a clean test EOA) and confirm:

1. Tenderly alert fires within 60s.
2. Slack message lands in the right channel.
3. Sentry shows the corresponding error from the frontend (if the user-facing flow originated the call).

## What's not monitored here

- **Gas/perf**: not in scope for testnet. Add Grafana + a public RPC dashboard before mainnet.
- **TVL drift / vault health**: keeper emits these as structured logs (`metric snapshot`) and can be tailed via `fly logs`. A real dashboard ships with the marketing landing page (#48).
- **Off-chain key compromise**: not an alert problem; covered in `docs/runbook.md` §"Keeper compromised".
