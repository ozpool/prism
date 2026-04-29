import {createPublicClient, createWalletClient, http} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import {baseSepolia} from "viem/chains";
import pino from "pino";

import {loadConfig} from "./config.js";

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
      pollIntervalMs: config.POLL_INTERVAL_MS,
      maxGasPriceGwei: config.MAX_GAS_PRICE_GWEI,
      blockNumber: blockNumber.toString(),
    },
    "PRISM keeper online — poll loop lands in #56",
  );

  // #56 wires the actual poll loop: enumerate vaults, evaluate
  // shouldRebalance per vault, simulate via eth_call (#57), submit
  // (#58), retry on reprice. Health endpoint + SIGTERM in #60.
  await new Promise<void>(() => {
    // park forever; #60 replaces with proper lifecycle.
    setInterval(() => {
      logger.debug("keeper alive");
    }, config.POLL_INTERVAL_MS);
  });

  // Mark walletClient as used so TS doesn't drop it from the bundle.
  void walletClient;
}

main().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err);
  process.exit(1);
});
