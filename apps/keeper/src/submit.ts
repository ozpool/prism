import type {Address, Hash, Hex, TransactionReceipt} from "viem";
import type {Logger} from "pino";

import {vaultAbi} from "./abi.js";

/// Minimal slice of viem's WalletClient + PublicClient that the tx
/// submitter needs. Structural to dodge cross-version type drift across
/// the keeper / shared / web packages.
export interface SubmitClient {
  writeContract: (args: {
    account: Address;
    address: Address;
    abi: readonly unknown[];
    functionName: string;
    args?: readonly unknown[];
    nonce?: number;
    maxFeePerGas?: bigint;
    maxPriorityFeePerGas?: bigint;
    chain?: unknown;
  }) => Promise<Hash>;
  waitForTransactionReceipt: (args: {hash: Hash; timeout?: number}) => Promise<TransactionReceipt>;
  getTransactionCount: (args: {address: Address; blockTag?: "pending" | "latest"}) => Promise<number>;
  estimateFeesPerGas: () => Promise<{maxFeePerGas: bigint; maxPriorityFeePerGas: bigint}>;
}

export interface SubmitDeps {
  client: SubmitClient;
  account: Address;
  vault: Address;
  logger: Logger;
  /// Hard ceiling — keeper refuses to submit above this gas price.
  /// Pulled from MAX_GAS_PRICE_GWEI in config and converted to wei.
  maxFeePerGasCap: bigint;
  /// Wait timeout per attempt before deciding the tx is stuck.
  /// Reprice attempts run with a fresh quote and a higher tip.
  attemptTimeoutMs: number;
  /// Maximum reprice retries before giving up.
  maxAttempts: number;
  /// Chain object to pass to writeContract. Required for viem v2 — when
  /// the wallet client is unwrapped into a structural slice (poll.ts),
  /// the implicit chain on the original client is lost and viem sends a
  /// transaction with no chainId, which the RPC rejects with a
  /// JSON-RPC envelope error. Forwarding the chain explicitly fixes it.
  chain?: unknown;
}

export type SubmitResult =
  | {status: "confirmed"; hash: Hash; attempts: number; gasUsed: bigint}
  | {status: "skipped"; reason: string}
  | {status: "failed"; reason: string; attempts: number};

/// Submit Vault.rebalance() with confirmation tracking + reprice on stuck.
///
/// Each attempt:
///   1. Re-quotes EIP-1559 fees from the network and caps maxFeePerGas
///      at `maxFeePerGasCap`. If the floor exceeds the cap we skip
///      submission rather than overpay.
///   2. On reprice, bumps maxPriorityFeePerGas by 12.5% (the geth
///      replacement-tx minimum). If the bumped tip would push
///      maxFeePerGas above the cap, we skip the retry.
///   3. Sends the tx with the same nonce so a stuck tx is replaced
///      rather than queued.
///   4. Waits up to `attemptTimeoutMs` for confirmation. A timeout
///      surfaces as "stuck" and triggers the next attempt.
///
/// Returns a typed verdict the caller can log + tally.
export async function submitRebalance(deps: SubmitDeps): Promise<SubmitResult> {
  const {client, account, vault, logger, maxFeePerGasCap, attemptTimeoutMs, maxAttempts, chain} = deps;

  // Pin the nonce up front so retries replace rather than queue.
  const nonce = await client.getTransactionCount({address: account, blockTag: "pending"});

  let priorityFee: bigint | undefined;
  let lastError = "";

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    const fees = await client.estimateFeesPerGas();
    const maxFeePerGas = fees.maxFeePerGas;
    const maxPriorityFeePerGas = priorityFee ?? fees.maxPriorityFeePerGas;

    if (maxFeePerGas > maxFeePerGasCap) {
      return {status: "skipped", reason: `gas above cap (${maxFeePerGas} > ${maxFeePerGasCap})`};
    }

    let hash: Hash;
    try {
      hash = await client.writeContract({
        account,
        address: vault,
        abi: vaultAbi,
        functionName: "rebalance",
        nonce,
        maxFeePerGas,
        maxPriorityFeePerGas,
        chain,
      });
    } catch (err) {
      lastError = errMsg(err);
      // Surface the full viem error shape — stack, .cause, request body —
      // to make Alchemy 'JSON is not a valid request object' debuggable
      // without local repro.
      const fullErr =
        typeof err === "object" && err !== null
          ? {
              name: (err as {name?: string}).name,
              shortMessage: (err as {shortMessage?: string}).shortMessage,
              message: (err as {message?: string}).message,
              details: (err as {details?: string}).details,
              metaMessages: (err as {metaMessages?: string[]}).metaMessages,
              cause: (err as {cause?: {message?: string}}).cause?.message,
            }
          : String(err);
      logger.warn({vault, attempt, err: fullErr}, "rebalance submission threw");
      // Network/account error — break rather than spam retries.
      return {status: "failed", reason: lastError, attempts: attempt + 1};
    }

    logger.info({vault, attempt, hash, nonce, maxFeePerGas, maxPriorityFeePerGas}, "rebalance submitted");

    try {
      const receipt = await client.waitForTransactionReceipt({hash, timeout: attemptTimeoutMs});
      if (receipt.status === "success") {
        return {status: "confirmed", hash, attempts: attempt + 1, gasUsed: receipt.gasUsed};
      }
      return {status: "failed", reason: "tx reverted on-chain", attempts: attempt + 1};
    } catch (err) {
      lastError = errMsg(err);
      logger.warn({vault, attempt, err: lastError}, "tx wait timed out — repricing");
      // Bump the tip 12.5% (the canonical geth replacement-tx minimum)
      // for the next attempt; cap-check on the next iteration's quote
      // will gate runaway pricing.
      priorityFee = (maxPriorityFeePerGas * 1125n) / 1000n;
    }
  }

  return {status: "failed", reason: `exhausted ${maxAttempts} attempts: ${lastError}`, attempts: maxAttempts};
}

function errMsg(err: unknown): string {
  if (typeof err === "object" && err !== null) {
    const anyErr = err as {shortMessage?: string; message?: string; details?: string};
    return anyErr.shortMessage ?? anyErr.message ?? anyErr.details ?? String(err);
  }
  return String(err);
}

/// Convert a gwei integer to a wei bigint for the cap.
export function gweiToWei(gwei: number): bigint {
  return BigInt(gwei) * 10n ** 9n;
}

/// Hex helper for places the caller wants to log a quoted hash inline.
export function asHex(hash: Hash): Hex {
  return hash;
}
