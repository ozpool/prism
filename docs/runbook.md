# PRISM Incident Runbook

What to do when alerts fire. Optimised for the testnet launch on Base Sepolia. Mainnet adds the deploy-script gate from `docs/deploy-runbook.md`.

## Severity matrix

| Sev | Definition | Examples | Response time | Comms |
|---|---|---|---|---|
| **SEV-1** | User funds at risk **or** non-recoverable bug | Reentrancy, share-supply mismatch, hook bypassing fee gate, oracle stuck | Immediate | All-hands + status page |
| **SEV-2** | Functionality broken, users blocked | Keeper down >5min, deposit/withdraw reverting consistently, frontend can't read vault state | < 30 min | Status page + Discord |
| **SEV-3** | Degraded but workable | Stale oracle (deviates within tolerance), keeper falling behind by 1–2 cycles, frontend latency | < 4h | Engineering Slack |
| **SEV-4** | Cosmetic / observability | Missing telemetry, log noise, unused alert rules | Next sprint | Backlog |

## On-call

- **Primary on-call** is the deploy operator for the active testnet (rotation in `docs/oncall.md` once team grows; for now, the deployer holds the pager).
- Pager target: Sentry + Tenderly both route to the same email/Slack channel. See `docs/monitoring.md` for channel config.
- Escalation: → engineering lead → multisig signers (only for SEV-1 actions that need on-chain control).

## Step 0: Triage (within 5 min)

1. Acknowledge the alert in the channel. Stop other work.
2. Open the relevant dashboard:
   - Sentry web project — frontend errors
   - Sentry keeper project — backend errors
   - Tenderly dashboard for the deployed contracts — on-chain reverts
   - Basescan for the deployed factory + hook
3. Severity-set the incident based on the matrix above.

## Sev-1 playbooks

### Bug in deployed contract (reentrancy, math, hook)

Contracts are immutable per ADR-006. There is no upgrade path.

1. **Halt the keeper.** `fly scale count 0 --app prism-keeper-sepolia`. This stops new rebalances; users can still `deposit` / `withdraw` independently.
2. **Communicate the affected addresses** in the incident channel + status page. Reference the verified contract on Basescan.
3. **Withdraw guarantee.** `withdraw()` is never pausable (invariant 6). Confirm users can still exit by simulating a withdraw against the affected vault from a script: `cast call <vault> "withdraw(...)" ...`.
4. **Migration plan.** If a redeploy is needed, follow `docs/deploy-runbook.md` §6 (Rollback). The new vault has new addresses; users redeposit manually.
5. **Postmortem.** Within 72h, write up root cause, timeline, mitigations.

### Keeper compromised (private key leak)

1. **Burn the keeper key.** Drain any remaining bonus shares to the treasury multisig: `cast send <vault> "transfer(...)" ...` for each affected vault.
2. **Rotate.** Generate a new key, set via `fly secrets set KEEPER_PRIVATE_KEY=...`, redeploy.
3. **Audit.** Search `apps/keeper`'s recent logs for unusual tx patterns. The compromise window starts at the earliest unauthorized tx.

### Oracle stuck or feeding a bad price

1. **Confirm.** Read `ChainlinkAdapter.read()` directly via `cast call`. Compare to the expected feed value on the Chainlink dashboard. If the contract is fail-soft-degrading (returning the stale flag), the rebalance gate already blocks.
2. **No action required** while `staleness > heartbeat` — the hook + strategy refuse to rebalance. Document the duration in the incident.
3. **Escalate to Chainlink** if the underlying feed is the issue.

## Sev-2 playbooks

### Keeper down

1. `fly status --app prism-keeper-sepolia` → check task health.
2. `fly logs --app prism-keeper-sepolia` for the crash signature.
3. If transient (RPC throttled, node OOM): `fly machine restart <id>`.
4. If persistent (logic crash): roll back to the last green git sha (`fly deploy --image-label <prev-sha>`).
5. Sentry will have the captured exception; link it in the incident.

### Frontend serving wrong vault data

1. Confirm `addresses.json` matches the on-chain factory. Run `pnpm verify-hook --chain base-sepolia`.
2. If addresses drifted (e.g. someone re-ran post-deploy on a stale broadcast): re-run the post-deploy script against the canonical broadcast.
3. Redeploy the web app.

## Routine drills

Run quarterly:

- [ ] Fire a fake Sentry event from the web app and confirm it lands in the configured channel.
- [ ] Trigger a Tenderly alert (e.g. a manual `cast send` that reverts) and confirm the channel routing.
- [ ] Restore the keeper from `fly machine restart` and confirm health probes go green within 60s.
- [ ] Review the alert rules for any that have not fired in 90 days — either still relevant, or delete.

## What stays out of this runbook

- Day-2 product decisions (paused vaults, fee changes) — those go through the multisig governance flow, not the on-call.
- Routine deploys — see `docs/deploy-runbook.md`.
- Smart contract upgrade procedures — there are none. ADR-006.
