# Security Policy

PRISM is a permissionless ALM protocol on Uniswap V4. The contracts
are immutable by design (no proxies — see [ADR-006](./docs/adrs/ADR-006-immutable-core.md));
the only response to a critical bug is the migration playbook.

## Reporting a vulnerability

**Do not open a public issue.** Use a private channel.

| Severity | Channel |
|---|---|
| Funds at risk, oracle / hook / vault compromise | Email **security@ozpool.dev** with PGP if you have it |
| Logic bugs without immediate funds risk | Email **security@ozpool.dev** |
| Frontend / keeper / docs (non-custody) | GitHub security advisory (private) |

We aim to:

- Acknowledge within **48 hours**.
- Provide a status update within **5 business days**.
- Coordinate a disclosure timeline with you before any public mention.

If you do not hear back, escalate via direct message to a maintainer
listed in `CODEOWNERS` (forthcoming) or, failing that, by opening a
public *minimal-detail* issue requesting a private channel — but do
not include the vulnerability details there.

## Scope

**In scope (please report):**

- `packages/contracts/src/core/Vault.sol` — custody, accounting, share math
- `packages/contracts/src/core/VaultFactory.sol` — CREATE2 deployment, hook-address mining
- `packages/contracts/src/strategies/BellStrategy.sol` — purity, weight-sum invariant
- `packages/contracts/src/hooks/ProtocolHook.sol` — V4 hook callbacks, gas budget, oracle
- `packages/contracts/src/oracles/ChainlinkAdapter.sol` — staleness, sequencer gate
- `packages/contracts/src/libraries/{PositionLib,FeeLib,MEVLib,HookMiner}.sol`
- `packages/contracts/src/utils/{Errors,ReentrancyGuardTransient}.sol`
- Deploy scripts (`packages/contracts/script/Deploy.s.sol`) — wiring, hook-bit assertions

**Boundary cases (please report, but lower priority):**

- Frontend (`apps/web`) — wallet handling, address display, network gates
- Keeper (`apps/keeper`) — tx submission, simulation gate
- CI workflows — hook-address verification, deploy automation

**Out of scope:**

- Bugs requiring a malicious or compromised RPC.
- Issues in pinned upstream dependencies (`v4-core`, `v4-periphery`,
  `permit2`) — report those upstream first; we'll mirror the disclosure.
- Theoretical attacks against the protocol economic model that require
  the attacker to control the price feed or majority of pool liquidity.
- "DoS via griefing"-style reports against permissionless functions
  (e.g., calling `rebalance()` to deny a competitor's bonus). These
  are part of the design, not vulnerabilities.

## Severity classification

| Severity | Definition |
|---|---|
| **Critical** | Direct loss of user funds. Hook callback bypass, vault accounting break, mint-without-deposit. |
| **High** | Indirect loss of funds (e.g., manipulated oracle ⇒ bad rebalance). Loss of withdraw guarantee. |
| **Medium** | Loss of fees/MEV that should accrue to LPs. Recoverable inconsistency. |
| **Low** | Off-chain / UX issues that mislead users but don't lose funds. |
| **Info** | Hardening suggestions, gas optimisations without security impact. |

## Bug bounty

PRISM is pre-launch (M0). There is **no formal bug bounty programme yet**.

Once the post-audit mainnet launch ships (post-M5), we will publish a
bug bounty programme on [Immunefi](https://immunefi.com) or equivalent,
with severity-tiered rewards covering the in-scope contracts above.
Until then, security reports are accepted in good faith and we will
acknowledge contributions in the eventual public bounty announcement.

If a critical issue is reported during the testnet phase, we may make
ad-hoc rewards available — coordinate with the maintainer team via the
private channel.

## Migration playbook

If a bug requires the contracts to be replaced rather than fixed:

1. Disclosure is coordinated under a private channel.
2. New contracts are deployed at fresh addresses.
3. A frozen withdraw window is announced — the old vaults remain
   pause-immune, so users can always recover funds.
4. Users withdraw from old vaults and re-deposit into new vaults.
5. Old vault addresses are marked deprecated in the dApp; the contracts
   themselves remain on-chain (immutability is a feature).

Full procedure: [ADR-006 — Immutable Core v1](./docs/adrs/ADR-006-immutable-core.md).

## Audit status

| Phase | Status |
|---|---|
| M0 — Foundations | In progress (this is the work that gets audited) |
| External audit | Scheduled before M5 mainnet launch |
| Post-audit re-review | Required if contracts change after audit sign-off |
| Bug bounty | Launches with M5 mainnet |

We will publish audit reports in `docs/audits/` once available.
