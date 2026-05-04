// PRISM contract ABIs.
//
// These are placeholders. Issue #46 (scripts/export-abis.ts) reads the Foundry
// `out/` directory after `forge build` and overwrites this file with the real
// ABIs typed as readonly tuples (so viem/wagmi can infer return + arg types).
//
// Until then each ABI is exported as an empty `readonly []` so consumers can
// import the names without runtime errors. Calling these contracts off these
// stubs will return `unknown` types — that is intentional, the goal is only
// to lock the export shape.

export const VaultAbi = [] as const;
export type VaultAbi = typeof VaultAbi;

export const VaultFactoryAbi = [] as const;
export type VaultFactoryAbi = typeof VaultFactoryAbi;

export const ProtocolHookAbi = [] as const;
export type ProtocolHookAbi = typeof ProtocolHookAbi;

export const BellStrategyAbi = [] as const;
export type BellStrategyAbi = typeof BellStrategyAbi;

export const ChainlinkAdapterAbi = [] as const;
export type ChainlinkAdapterAbi = typeof ChainlinkAdapterAbi;
