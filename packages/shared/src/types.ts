import type { Address, Hex } from "viem";

export interface PoolKey {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

export interface Position {
  tickLower: number;
  tickUpper: number;
  liquidity: bigint;
}

export interface TargetPosition {
  positions: readonly Position[];
  totalLiquidity: bigint;
}

export type TxStatus =
  | { kind: "idle" }
  | { kind: "pending"; hash: Hex }
  | { kind: "success"; hash: Hex }
  | { kind: "error"; error: Error }
  | { kind: "wrong-network"; expectedChainId: number };

export interface VaultTotals {
  totalSupply: bigint;
  totalAmount0: bigint;
  totalAmount1: bigint;
  pricePerShare0: bigint;
  pricePerShare1: bigint;
}

export interface MEVProfits {
  cumulativeProfit0: bigint;
  cumulativeProfit1: bigint;
  lastDistributionAt: bigint;
}

export interface RebalanceEvent {
  vault: Address;
  blockNumber: bigint;
  txHash: Hex;
  oldSqrtPriceX96: bigint;
  newSqrtPriceX96: bigint;
  positionsCleared: number;
  positionsCreated: number;
  feeBps: number;
}
