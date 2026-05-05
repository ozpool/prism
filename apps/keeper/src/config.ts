import {z} from "zod";

const envSchema = z.object({
  BASE_SEPOLIA_RPC_URL: z.string().url(),
  KEEPER_PRIVATE_KEY: z
    .string()
    .regex(/^0x[a-fA-F0-9]{64}$/, "KEEPER_PRIVATE_KEY must be 0x-prefixed 32-byte hex"),
  VAULT_FACTORY_ADDRESS: z
    .string()
    .regex(/^0x[a-fA-F0-9]{40}$/, "VAULT_FACTORY_ADDRESS must be a 0x-prefixed address"),
  POOL_MANAGER_ADDRESS: z
    .string()
    .regex(/^0x[a-fA-F0-9]{40}$/, "POOL_MANAGER_ADDRESS must be a 0x-prefixed address"),
  POLL_INTERVAL_MS: z.coerce.number().int().positive().default(30_000),
  MAX_GAS_PRICE_GWEI: z.coerce.number().int().positive().default(10),
  HEALTH_PORT: z.coerce.number().int().positive().default(8080),
  LOG_LEVEL: z
    .enum(["trace", "debug", "info", "warn", "error", "fatal"])
    .default("info"),
});

export type Config = z.infer<typeof envSchema>;

export function loadConfig(): Config {
  const parsed = envSchema.safeParse(process.env);
  if (!parsed.success) {
    const issues = parsed.error.issues
      .map((i) => `  - ${i.path.join(".")}: ${i.message}`)
      .join("\n");
    throw new Error(`Invalid keeper environment:\n${issues}`);
  }
  return parsed.data;
}
