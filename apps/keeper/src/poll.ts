import type {Address, Hex} from "viem";
import type {Logger} from "pino";

import {strategyAbi, vaultAbi, vaultFactoryAbi} from "./abi.js";
import {readSlot0, toPoolId} from "./pool.js";
import {Metrics} from "./metrics.js";
import {gatedSimulate, type SimulateClient, type SimulateResult} from "./simulate.js";
import {submitRebalance, type SubmitClient, type SubmitResult} from "./submit.js";

/// Minimal slice of viem's PublicClient that the poll loop needs. Typing
/// as a structural slice avoids cross-version PublicClient incompatibilities
/// when the keeper, shared, and web packages each resolve viem differently.
export interface ReadClient extends SimulateClient, SubmitClient {
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
  simulation?: SimulateResult;
  /// Set when sim passed and the keeper submitted (or attempted to).
  submission?: SubmitResult;
}

export interface PollDeps {
  client: ReadClient;
  factory: Address;
  poolManager: Address;
  /// Keeper account used as the `from` for sim eth_call AND as the
  /// signer for submission.
  account: Address;
  /// Hard ceiling on maxFeePerGas — keeper refuses to submit above this.
  maxFeePerGasCap: bigint;
  /// Per-attempt timeout before a stuck tx is repriced.
  txAttemptTimeoutMs: number;
  /// Maximum reprice retries.
  maxSubmitAttempts: number;
  logger: Logger;
  /// Optional shared metrics sink. The lifecycle layer (#60) creates
  /// this at startup and exposes a snapshot via /metrics. When omitted
  /// the loop runs metric-free — keeps unit tests trivial.
  metrics?: Metrics;
  /// Chain object forwarded to writeContract during submission. Without
  /// it viem v2 emits a tx with no chainId — see SubmitDeps.chain.
  chain?: unknown;
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
  const {logger} = deps;

  const length = (await deps.client.readContract({
    address: deps.factory,
    abi: vaultFactoryAbi,
    functionName: "allVaultsLength",
  })) as bigint;

  const vaults: Address[] = [];
  for (let i = 0n; i < length; i++) {
    const vault = (await deps.client.readContract({
      address: deps.factory,
      abi: vaultFactoryAbi,
      functionName: "allVaults",
      args: [i],
    })) as Address;
    vaults.push(vault);
  }

  const results: VaultEvaluation[] = [];
  for (const vault of vaults) {
    try {
      const evaluation = await evaluateVault({...deps, vault});
      results.push(evaluation);
    } catch (err) {
      logger.warn({vault, err: errMsg(err)}, "vault evaluation failed");
    }
  }
  return results;
}

interface EvaluateOne extends PollDeps {
  vault: Address;
}

interface PoolKeyOnChain {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

async function evaluateVault(deps: EvaluateOne): Promise<VaultEvaluation> {
  const {client, poolManager, account, vault, logger} = deps;

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

  // Sim gate (#57): run eth_call against pending before submission.
  const simulation = await gatedSimulate({client, vault, account, logger});
  if (!simulation.ok) {
    return {vault, poolId, currentTick, shouldRebalance, simulation};
  }

  // Submission (#58): writeContract + confirmation wait + reprice on stuck.
  const submission = await submitRebalance({
    client,
    account,
    vault,
    logger,
    maxFeePerGasCap: deps.maxFeePerGasCap,
    attemptTimeoutMs: deps.txAttemptTimeoutMs,
    maxAttempts: deps.maxSubmitAttempts,
    chain: deps.chain,
  });
  if (submission.status === "confirmed") {
    logger.info(
      {vault, hash: submission.hash, attempts: submission.attempts, gasUsed: submission.gasUsed.toString()},
      "rebalance landed",
    );
  } else if (submission.status === "skipped") {
    logger.info({vault, reason: submission.reason}, "rebalance submission skipped");
  } else {
    logger.warn({vault, reason: submission.reason, attempts: submission.attempts}, "rebalance submission failed");
  }

  return {vault, poolId, currentTick, shouldRebalance, simulation, submission};
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

/// Run a single poll cycle: evaluate every vault, submit any due
/// rebalances, record metrics. Always resolves — internal errors are
/// logged + counted as a failed cycle but do not throw. The boolean
/// return is used by the cron one-shot wrapper to decide its exit code:
/// `true` on success, `false` if the cycle itself raised.
export async function runCycle(deps: PollDeps): Promise<boolean> {
  const {logger, metrics} = deps;
  const cycleId = Date.now().toString(36);
  const cycleLogger = logger.child({cycle: cycleId});
  const start = Date.now();
  try {
    const evaluations = await evaluateVaults({...deps, logger: cycleLogger});
    const dueCount = evaluations.filter((e) => e.shouldRebalance).length;
    const submittableCount = evaluations.filter((e) => e.simulation?.ok === true).length;
    const confirmedCount = evaluations.filter((e) => e.submission?.status === "confirmed").length;
    const failedCount = evaluations.filter((e) => e.submission?.status === "failed").length;

    if (metrics) {
      for (const e of evaluations) {
        if (e.simulation?.ok) metrics.rebalanceSimulated();
        if (e.submission?.status === "confirmed") {
          metrics.rebalanceSubmitted();
          metrics.rebalanceConfirmed();
        } else if (e.submission?.status === "failed") {
          metrics.rebalanceSubmitted();
          metrics.rebalanceFailed();
        }
      }
      metrics.cycleCompleted(Date.now() - start);
    }

    cycleLogger.info(
      {
        vaultCount: evaluations.length,
        dueCount,
        submittableCount,
        confirmedCount,
        failedCount,
        ms: Date.now() - start,
      },
      "poll cycle complete",
    );
    return true;
  } catch (err) {
    const ms = Date.now() - start;
    if (metrics) metrics.cycleFailed(ms);
    cycleLogger.error({err: errMsg(err), ms}, "poll cycle failed");
    return false;
  }
}

/// Run the poll loop forever with the configured cadence. Returns a
/// stop function that resolves after the in-flight cycle completes.
export function runPollLoop(deps: PollDeps & {intervalMs: number}): () => Promise<void> {
  const {intervalMs} = deps;
  let stopped = false;
  let inflight: Promise<void> = Promise.resolve();

  const schedule = (): void => {
    if (stopped) return;
    inflight = runCycle(deps).then(() => {
      if (!stopped) setTimeout(schedule, intervalMs);
    });
  };

  schedule();

  return async () => {
    stopped = true;
    await inflight;
  };
}
