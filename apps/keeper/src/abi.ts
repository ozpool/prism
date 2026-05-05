// Inline ABI fragments the keeper depends on. The full typed ABIs land
// once #46 (scripts/export-abis.ts) is wired; until then we define only
// the surface this package needs so viem can infer return types.

export const vaultFactoryAbi = [
  {
    type: "function",
    name: "allVaults",
    stateMutability: "view",
    inputs: [],
    outputs: [{name: "", type: "address[]"}],
  },
] as const;

export const vaultAbi = [
  {
    type: "function",
    name: "strategy",
    stateMutability: "view",
    inputs: [],
    outputs: [{name: "", type: "address"}],
  },
  {
    type: "function",
    name: "poolKey",
    stateMutability: "view",
    inputs: [],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          {name: "currency0", type: "address"},
          {name: "currency1", type: "address"},
          {name: "fee", type: "uint24"},
          {name: "tickSpacing", type: "int24"},
          {name: "hooks", type: "address"},
        ],
      },
    ],
  },
  {
    type: "function",
    name: "rebalance",
    stateMutability: "nonpayable",
    inputs: [],
    outputs: [],
  },
  {
    type: "function",
    name: "lastRebalanceTick",
    stateMutability: "view",
    inputs: [],
    outputs: [{name: "", type: "int24"}],
  },
  {
    type: "function",
    name: "lastRebalanceTimestamp",
    stateMutability: "view",
    inputs: [],
    outputs: [{name: "", type: "uint256"}],
  },
] as const;

export const strategyAbi = [
  {
    type: "function",
    name: "shouldRebalance",
    stateMutability: "view",
    inputs: [
      {name: "currentTick", type: "int24"},
      {name: "lastRebalanceTick", type: "int24"},
      {name: "lastRebalanceTimestamp", type: "uint256"},
    ],
    outputs: [{name: "", type: "bool"}],
  },
] as const;

// PoolManager.extsload(bytes32) — used to read slot0 (sqrtPriceX96 + tick)
// without pulling StateView/StateLibrary into the keeper's bundle.
export const poolManagerExtsloadAbi = [
  {
    type: "function",
    name: "extsload",
    stateMutability: "view",
    inputs: [{name: "slot", type: "bytes32"}],
    outputs: [{name: "", type: "bytes32"}],
  },
] as const;
