# ADR-007: Gas Budget Allocation

**Status:** accepted
**Date:** 2026-04-29
**Issue:** [#14](https://github.com/ozpool/prism/issues/14)

## Context

Every PRISM hook callback runs on the swap hot-path. PoolManager forwards
control to ProtocolHook on each `swap()`, and any gas spent there is paid
by the swapper, not the LPs. If the hook is too expensive, swappers route
around the pool and the volatility-fee mechanism never observes the trade
it was meant to regulate.

Three independent gas budgets shape PRISM's design surface:

1. **Hook overhead per swap.** Cost of `beforeSwap` + `afterSwap` together.
2. **Rebalance ceiling.** Cost of a full `Vault.rebalance()` cycle.
3. **Keeper economics.** Whether the rebalance bonus covers gas + opportunity cost.

This ADR fixes the budgets so individual implementation issues (#34, #35,
#36, #29) can be checked against a single source of truth.

## Decision

### 1. Hook overhead per swap

| Callback     | Budget      | Rationale                                                  |
|--------------|------------:|------------------------------------------------------------|
| `beforeSwap` | **12,000**  | Two SLOAD + EWMA short/long update + dynamic fee compute   |
| `afterSwap`  | **18,000**  | One Chainlink read (~5k) + deviation math + event (3 args) |
| **Combined** | **≤ 30,000**| ~10% of a typical V4 swap (~300k); acceptable spread       |

**Hard rules:**

- `beforeSwap` MUST stay under **12,000 gas** in the steady state. Issue #35
  must include a Foundry gas snapshot test that fails the build on regression.
- `afterSwap` MUST stay under **18,000 gas** in the steady state. Issue #36
  must include the symmetric snapshot test.
- The combined budget is the contractual upper bound for the swap UX gate.
  If swappers see a gas tax above this they will route around our pool —
  this is the SLA the volatility-fee mechanism lives or dies by.

**Where the budget goes (beforeSwap):**

- 1 transient SLOAD (last update timestamp): ~100
- 1 SLOAD (EWMA state, packed): ~2,100 (cold) / ~100 (warm)
- EWMA short + long update math (no log/exp, fixed-point only): ~3,000
- Dynamic fee compute + clamp: ~1,500
- Storage write back (single packed SSTORE): ~5,000
- IHooks return + selector overhead: ~300

**Where the budget goes (afterSwap):**

- Chainlink `latestRoundData` external call: ~5,000
- Sequencer uptime feed read: ~5,000
- Deviation comparison + threshold check: ~1,500
- `SwapObserved` event (4 indexed + 2 data): ~3,750
- Hot-path memory allocation + return shape: ~2,000
- Buffer for cold-slot edge cases: ~750

### 2. Rebalance ceiling

A single `Vault.rebalance()` is one PoolManager unlock containing:

- N × `modifyLiquidity` (remove existing positions)
- 0–1 × internal swap
- M × `modifyLiquidity` (deploy new positions)
- 1 × `_settleDeltas`

Empirical ceiling for **N = M = 7** (PRISM v1.0 bell curve):

| Phase                        | Budget    |
|------------------------------|----------:|
| Remove 7 positions           |  220,000  |
| Internal swap (when needed)  |  140,000  |
| Deploy 7 new positions       |  280,000  |
| Settle deltas + accounting   |   60,000  |
| **Total ceiling**            |**700,000**|

A keeper transaction at 0.1 gwei on Base ≈ **0.00007 ETH gas**. Safe under
Base's 30M block gas limit (≈4% of a block).

**Hard rules:**

- `Vault.rebalance()` MUST revert with `RebalanceGasOverrun()` if
  `gasleft() > 1_500_000` is breached at entry (sanity gate, not target).
- The 700k ceiling is the design target. Issue #29 must include a forge gas
  snapshot covering N = 7 with and without internal swap.

### 3. Keeper economics

Rebalance bonus is paid in shares minted to `msg.sender` of `rebalance()`.
Bonus formula (locked here, implemented in #33):

```
bonusShares = totalSupply * BONUS_BPS / 10_000
BONUS_BPS = 5  // 0.05% of vault on each rebalance
```

**Keeper math at v1.0 launch assumptions:**

- Vault TVL: $50,000 (seed)
- Bonus per rebalance: $25 worth of shares
- Gas at 0.1 gwei × 700k = $0.07 of ETH
- Keeper margin per call: ~$24.93 gross

Even at a 10× gas spike (1 gwei), keeper margin stays positive. If TVL
drops below ~$5,000, bonus < $2.50 and keepers may stop calling — at
which point the **24h fallback** in `shouldRebalance` triggers and the
keeper's bonus rises to whatever has accumulated. This is the natural
liveness backstop: low-TVL vaults rebalance daily, regardless of price drift.

**Hard rule:**

- The bonus mechanism MUST be honoured in `Vault.rebalance()`. There is no
  allowlist or auction — any address that successfully calls `rebalance()`
  receives the bonus. Permissionlessness is non-negotiable.

## Consequences

**Positive:**
- Single source of truth for gas budgets. Implementation PRs can cite this ADR.
- Snapshot tests in #29, #35, #36 enforce the ceilings at CI time.
- Keeper economics survive a 10× gas regime.

**Negative:**
- The 12k beforeSwap budget excludes any oracle read. Volatility math must
  be self-contained (no external calls in `beforeSwap`). This is the reason
  oracle work happens in `afterSwap` (ADR-003) rather than `beforeSwap`.
- The 700k rebalance ceiling caps the strategy at ~7 active positions. A
  future "mega-bell" with 15 positions would need a separate ADR.

**Neutral:**
- Bonus is a flat 5 bps. Future ADRs may revisit this once we have telemetry
  on how often vaults at different TVLs are actually rebalanced.

## References

- ADR-002 — Hook scoping (singleton blast radius affects whose budget pays)
- ADR-003 — Oracle strategy (afterSwap budget includes Chainlink read)
- ADR-004 — Flash accounting (rebalance unlock cost composition)
- Issue #29 — Vault.rebalance implementation
- Issue #35 — ProtocolHook.beforeSwap implementation
- Issue #36 — ProtocolHook.afterSwap implementation
