import type {Address} from "viem";
import type {Logger} from "pino";

import {vaultAbi} from "./abi.js";

/// Minimal slice of viem's PublicClient we need for a single-call eth_call
/// simulation against the pending block.
export interface SimulateClient {
  simulateContract: (args: {
    address: Address;
    abi: readonly unknown[];
    functionName: string;
    args?: readonly unknown[];
    account: Address;
  }) => Promise<{result: unknown}>;
}

export type SimulateResult =
  | {ok: true}
  | {ok: false; reason: string};

/// Simulate `Vault.rebalance()` against the pending block via eth_call.
/// Returns a typed verdict the caller can use as a submission gate.
///
/// Uses `simulateContract` (which under the hood is `eth_call` with the
/// keeper's account as `from`) so the simulated state matches what the
/// real submission would see — same account, same gas-pricing context,
/// same in-flight nonces. Any revert surfaces as `ok: false` with the
/// decoded error string when viem can recover one.
///
/// Per ADR-007 the keeper's submission budget is tight; skipping a
/// simulated revert preserves the rebalance-bonus invariant (the
/// keeper does not waste gas on a tx that can't land).
export async function simulateRebalance(
  client: SimulateClient,
  vault: Address,
  account: Address,
): Promise<SimulateResult> {
  try {
    await client.simulateContract({
      address: vault,
      abi: vaultAbi,
      functionName: "rebalance",
      account,
    });
    return {ok: true};
  } catch (err) {
    return {ok: false, reason: errMsg(err)};
  }
}

/// Convenience wrapper that logs the simulation outcome consistently
/// across all callers. Returns the verdict so callers can also branch.
export async function gatedSimulate(
  deps: {client: SimulateClient; vault: Address; account: Address; logger: Logger},
): Promise<SimulateResult> {
  const verdict = await simulateRebalance(deps.client, deps.vault, deps.account);
  if (verdict.ok) {
    deps.logger.info({vault: deps.vault}, "rebalance simulation passed");
  } else {
    deps.logger.warn({vault: deps.vault, reason: verdict.reason}, "rebalance simulation reverted — skipping submission");
  }
  return verdict;
}

function errMsg(err: unknown): string {
  if (typeof err === "object" && err !== null) {
    const anyErr = err as {shortMessage?: string; message?: string; details?: string};
    return anyErr.shortMessage ?? anyErr.message ?? anyErr.details ?? String(err);
  }
  return String(err);
}
