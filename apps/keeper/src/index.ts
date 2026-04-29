import {createPublicClient, createWalletClient, http, type Address} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import {baseSepolia} from "viem/chains";
import pino from "pino";

import {loadConfig} from "./config.js";
import {runPollLoop} from "./poll.js";

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

  const stop = runPollLoop({
    client: publicClient,
    factory: config.VAULT_FACTORY_ADDRESS as Address,
    poolManager: config.POOL_MANAGER_ADDRESS as Address,
    account: account.address,
    intervalMs: config.POLL_INTERVAL_MS,
    logger,
  });

  // #58 will replace this park-forever with proper tx submission +
  // confirmation tracking. #60 adds /health + graceful SIGTERM.
  await new Promise<void>((resolve) => {
    process.on("SIGTERM", () => {
      logger.info("SIGTERM received — draining in-flight cycle");
      stop().then(resolve);
    });
  });

  // Suppress unused-var lint for walletClient — #58 wires it for tx submit.
  void walletClient;
}

main().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err);
  process.exit(1);
});
