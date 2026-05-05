import {createPublicClient, createWalletClient, http, type Address} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import {baseSepolia} from "viem/chains";
import pino from "pino";

import {loadConfig} from "./config.js";
import {startHealthServer, stopHealthServer} from "./health.js";
import {Metrics} from "./metrics.js";
import {runPollLoop} from "./poll.js";
import {captureException, flushSentry, initSentry} from "./sentry.js";
import {gweiToWei} from "./submit.js";

const METRIC_SNAPSHOT_INTERVAL_MS = 60_000;

async function main() {
  const config = loadConfig();
  initSentry({release: process.env.SENTRY_RELEASE, environment: process.env.NODE_ENV});
  const logger = pino({level: config.LOG_LEVEL});

  const account = privateKeyToAccount(config.KEEPER_PRIVATE_KEY as `0x${string}`);

  const publicClient = createPublicClient({
    chain: baseSepolia,
    transport: http(config.BASE_SEPOLIA_RPC_URL),
  });

  const walletClient = createWalletClient({
    account,
    chain: baseSepolia,
    transport: http(config.BASE_SEPOLIA_RPC_URL),
  });

  const blockNumber = await publicClient.getBlockNumber();
  logger.info(
    {
      keeper: account.address,
      factory: config.VAULT_FACTORY_ADDRESS,
      poolManager: config.POOL_MANAGER_ADDRESS,
      pollIntervalMs: config.POLL_INTERVAL_MS,
      maxGasPriceGwei: config.MAX_GAS_PRICE_GWEI,
      blockNumber: blockNumber.toString(),
    },
    "PRISM keeper online",
  );

  // The poll loop needs both read methods (readContract, simulateContract,
  // get*) and write methods (writeContract). Wrap the two clients in one
  // structural object so the caller doesn't need to plumb both through.
  // Cast through `unknown` because viem's writeContract has rich generic
  // overloads that don't match our intentionally-narrow ReadClient slice;
  // at runtime the call shape is identical.
  const client = {
    readContract: publicClient.readContract,
    simulateContract: publicClient.simulateContract,
    getTransactionCount: publicClient.getTransactionCount,
    estimateFeesPerGas: publicClient.estimateFeesPerGas,
    waitForTransactionReceipt: publicClient.waitForTransactionReceipt,
    writeContract: walletClient.writeContract,
  } as unknown as Parameters<typeof runPollLoop>[0]["client"];

  const metrics = new Metrics();
  const healthServer = startHealthServer({port: config.HEALTH_PORT, logger, metrics});

  const stop = runPollLoop({
    client,
    factory: config.VAULT_FACTORY_ADDRESS as Address,
    poolManager: config.POOL_MANAGER_ADDRESS as Address,
    account: account.address,
    maxFeePerGasCap: gweiToWei(config.MAX_GAS_PRICE_GWEI),
    txAttemptTimeoutMs: 60_000,
    maxSubmitAttempts: 3,
    intervalMs: config.POLL_INTERVAL_MS,
    logger,
    metrics,
  });

  // Periodic metric snapshot — emits one structured log line per minute
  // with cycle counts + p50/p99 latency. /metrics HTTP endpoint that
  // exposes the same numbers lands in #60.
  const metricTimer = setInterval(() => {
    logger.info({metrics: metrics.snapshot()}, "metric snapshot");
  }, METRIC_SNAPSHOT_INTERVAL_MS);

  // Graceful shutdown: drain the in-flight cycle, stop the metric
  // snapshot timer, then close the health server. SIGTERM is what
  // platforms (Fly.io, k8s) send for orderly stops; SIGINT is Ctrl-C
  // in dev. We treat both identically.
  await new Promise<void>((resolve) => {
    let shuttingDown = false;
    const shutdown = async (signal: string): Promise<void> => {
      if (shuttingDown) return;
      shuttingDown = true;
      logger.info({signal}, "received shutdown signal — draining");
      clearInterval(metricTimer);
      try {
        await stop();
        await stopHealthServer(healthServer);
      } catch (err) {
        logger.error({err}, "shutdown error");
        captureException(err, {phase: "shutdown"});
      }
      await flushSentry();
      logger.info({metrics: metrics.snapshot()}, "shutdown complete");
      resolve();
    };
    process.on("SIGTERM", () => void shutdown("SIGTERM"));
    process.on("SIGINT", () => void shutdown("SIGINT"));
  });
}

main().catch(async (err) => {
  // eslint-disable-next-line no-console
  console.error(err);
  captureException(err, {phase: "startup"});
  await flushSentry();
  process.exit(1);
});
