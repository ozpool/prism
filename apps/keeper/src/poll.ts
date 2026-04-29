import type {Address, Hex} from "viem";
import type {Logger} from "pino";

import {strategyAbi, vaultAbi, vaultFactoryAbi} from "./abi.js";
import {readSlot0, toPoolId} from "./pool.js";
import {gatedSimulate, type SimulateClient, type SimulateResult} from "./simulate.js";

/// Minimal slice of viem's PublicClient that the poll loop needs. Typing
/// as a structural slice avoids cross-version PublicClient incompatibilities
/// when the keeper, shared, and web packages each resolve viem differently.
export interface ReadClient extends SimulateClient {
  readContract: (args: {
    address: Address;
    abi: readonly unknown[];
    functionName: string;
    args?: readonly unknown[];
  }) => Promise<unknown>;
}

export interface VaultEvaluation {
  vault: Address;
  poolId: Hex;
  currentTick: number;
  shouldRebalance: boolean;
  /// Set when shouldRebalance is true and we ran the eth_call sim gate.
  /// Undefined when the sim was skipped (e.g., shouldRebalance was false).
  simulation?: SimulateResult;
}

export interface PollDeps {
  client: ReadClient;
  factory: Address;
  poolManager: Address;
  /// Keeper account used as the `from` for sim eth_call. Submission
  /// reuses the same account in #58.
  account: Address;
  logger: Logger;
}

/// One pass of the keeper poll loop.
///
/// 1. Fetch the active vault list from `VaultFactory.allVaults`.
/// 2. Per vault: read pool slot0, the strategy address, and the last
///    rebalance bookkeeping; ask the strategy `shouldRebalance`.
/// 3. Return the per-vault evaluation. Submission lands in #58.
///
/// Errors per vault are caught + logged so a single bad vault does not
/// abort the cycle. The cycle itself does not throw.
export async function evaluateVaults(deps: PollDeps): Promise<VaultEvaluation[]> {
  const {client, factory, poolManager, account, logger} = deps;

  const vaults = (await client.readContract({
    address: factory,
    abi: vaultFactoryAbi,
    functionName: "allVaults",
  })) as readonly Address[];

  const results: VaultEvaluation[] = [];
  for (const vault of vaults) {
    try {
      const evaluation = await evaluateVault({client, poolManager, account, logger, vault});
      results.push(evaluation);
    } catch (err) {
      logger.warn({vault, err: errMsg(err)}, "vault evaluation failed");
    }
  }
  return results;
}

interface EvaluateOne {
  client: ReadClient;
  poolManager: Address;
  account: Address;
  logger: Logger;
  vault: Address;
}

interface PoolKeyOnChain {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

async function evaluateVault({client, poolManager, account, logger, vault}: EvaluateOne): Promise<VaultEvaluation> {
  // Pull pool key + strategy + last-rebalance bookkeeping in parallel —
  // four reads against the same vault contract.
  const [poolKey, strategy, lastTick, lastTimestamp] = await Promise.all([
    client.readContract({address: vault, abi: vaultAbi, functionName: "poolKey"}) as Promise<PoolKeyOnChain>,
    client.readContract({address: vault, abi: vaultAbi, functionName: "strategy"}) as Promise<Address>,
    safeRead(client, vault, "lastRebalanceTick", 0),
    safeRead(client, vault, "lastRebalanceTimestamp", 0n),
  ]);

  const poolId = toPoolId({
    currency0: poolKey.currency0,
    currency1: poolKey.currency1,
    fee: poolKey.fee,
    tickSpacing: poolKey.tickSpacing,
    hooks: poolKey.hooks,
  });

  const {tick: currentTick} = await readSlot0(client, poolManager, poolId);

  const shouldRebalance = (await client.readContract({
    address: strategy,
    abi: strategyAbi,
    functionName: "shouldRebalance",
    args: [currentTick, Number(lastTick), BigInt(lastTimestamp)],
  })) as boolean;

  if (!shouldRebalance) {
    return {vault, poolId, currentTick, shouldRebalance};
  }

  logger.info({vault, currentTick, lastTick, lastTimestamp: lastTimestamp.toString()}, "vault due for rebalance");

  // #57 sim gate: run eth_call against the pending block before #58
  // submits. A reverting simulation signals the keeper would burn gas
  // without landing — defer to the next cycle so the bonus invariant
  // (ADR-007 §rebalance) holds.
  const simulation = await gatedSimulate({client, vault, account, logger});

  return {vault, poolId, currentTick, shouldRebalance, simulation};
}

/// Vault scaffold (#26) does not yet expose lastRebalanceTick /
/// lastRebalanceTimestamp; #29 adds them. Treat a missing function as
/// "no prior rebalance" rather than aborting the whole cycle.
async function safeRead<T extends number | bigint>(
  client: ReadClient,
  vault: Address,
  fn: "lastRebalanceTick" | "lastRebalanceTimestamp",
  fallback: T,
): Promise<T> {
  try {
    const result = await client.readContract({address: vault, abi: vaultAbi, functionName: fn});
    return result as T;
  } catch {
    return fallback;
  }
}

function errMsg(err: unknown): string {
  if (err instanceof Error) return err.message;
  return String(err);
}

/// Run the poll loop forever with the configured cadence. Returns a
/// stop function that resolves after the in-flight cycle completes.
export function runPollLoop(deps: PollDeps & {intervalMs: number}): () => Promise<void> {
  const {logger, intervalMs} = deps;
  let stopped = false;
  let inflight: Promise<void> = Promise.resolve();

  const tick = async (): Promise<void> => {
    if (stopped) return;
    const cycleId = Date.now().toString(36);
    const cycleLogger = logger.child({cycle: cycleId});
    const start = Date.now();
    try {
      const evaluations = await evaluateVaults({...deps, logger: cycleLogger});
      const dueCount = evaluations.filter((e) => e.shouldRebalance).length;
      const submittableCount = evaluations.filter((e) => e.simulation?.ok === true).length;
      cycleLogger.info(
        {
          vaultCount: evaluations.length,
          dueCount,
          submittableCount,
          ms: Date.now() - start,
        },
        "poll cycle complete",
      );
    } catch (err) {
      cycleLogger.error({err: errMsg(err), ms: Date.now() - start}, "poll cycle failed");
    }
  };

  const schedule = (): void => {
    if (stopped) return;
    inflight = tick().finally(() => {
      if (!stopped) setTimeout(schedule, intervalMs);
    });
  };

  schedule();

  return async () => {
    stopped = true;
    await inflight;
  };
}
