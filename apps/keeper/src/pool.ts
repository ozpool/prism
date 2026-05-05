import {keccak256, encodePacked, type Address, type Hex} from "viem";

import {poolManagerExtsloadAbi} from "./abi.js";

/// Minimal shape of viem's PublicClient we need for slot0 reads.
export interface ExtsloadClient {
  readContract: (args: {
    address: Address;
    abi: readonly unknown[];
    functionName: string;
    args?: readonly unknown[];
  }) => Promise<unknown>;
}

/// V4 PoolKey shape — currency0/currency1/fee/tickSpacing/hooks. The
/// keeper reads this once per vault per cycle and derives the PoolId
/// off-chain so it can extsload slot0 without an extra round-trip.
export interface PoolKey {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

/// Compute the V4 PoolId from a PoolKey. Mirrors `PoolIdLibrary.toId` —
/// `keccak256(abi.encode(poolKey))`.
export function toPoolId(key: PoolKey): Hex {
  return keccak256(
    encodePacked(
      ["address", "address", "uint24", "int24", "address"],
      [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks],
    ),
  );
}

/// Compute the storage slot for `pools[poolId]` in PoolManager. PoolManager
/// declares `pools` at slot 6, and the inner Pool.State value sits at
/// `keccak256(poolId, 6)`.
function poolStateSlot(poolId: Hex): Hex {
  return keccak256(encodePacked(["bytes32", "bytes32"], [poolId, "0x".concat("00".repeat(31), "06") as Hex]));
}

/// Decode V4 slot0: bottom 160 bits sqrtPriceX96, next 24 bits signed tick.
export function decodeSlot0(raw: Hex): {sqrtPriceX96: bigint; tick: number} {
  const value = BigInt(raw);
  const sqrtPriceX96 = value & ((1n << 160n) - 1n);
  let tick = Number((value >> 160n) & ((1n << 24n) - 1n));
  // Sign-extend 24-bit tick.
  if (tick >= 1 << 23) tick -= 1 << 24;
  return {sqrtPriceX96, tick};
}

/// Read the post-swap slot0 for a pool. Single extsload — avoids the
/// StateView contract and keeps the keeper bundle minimal.
export async function readSlot0(
  client: ExtsloadClient,
  poolManager: Address,
  poolId: Hex,
): Promise<{sqrtPriceX96: bigint; tick: number}> {
  const slot = poolStateSlot(poolId);
  const raw = (await client.readContract({
    address: poolManager,
    abi: poolManagerExtsloadAbi,
    functionName: "extsload",
    args: [slot],
  })) as Hex;
  return decodeSlot0(raw);
}
