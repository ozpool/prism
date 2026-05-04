import {createPublicClient, createWalletClient, http, type Address} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import {baseSepolia} from "viem/chains";
import pino from "pino";

import {loadConfig} from "./config.js";
import {Metrics} from "./metrics.js";
import {runPollLoop} from "./poll.js";
import {gweiToWei} from "./submit.js";

const METRIC_SNAPSHOT_INTERVAL_MS = 60_000;

async function main() {
  const config = loadConfig();
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

  // #60 hardens this further: /health endpoint + structured shutdown
  // semantics on both SIGTERM + SIGINT.
  await new Promise<void>((resolve) => {
    process.on("SIGTERM", () => {
      logger.info("SIGTERM received — draining in-flight cycle");
      clearInterval(metricTimer);
      stop().then(resolve);
    });
  });
}

main().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err);
  process.exit(1);
});
