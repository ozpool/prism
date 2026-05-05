// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

/// @title IProtocolHook
/// @notice PRISM's V4 hook surface — dynamic fees in `beforeSwap`, MEV
///         observation in `afterSwap`, lightweight position-state
///         cleanup in `afterAddLiquidity` / `afterRemoveLiquidity`, and
///         the per-pool / per-vault read accessors used by the dApp
///         and keeper.
/// @dev Inherits `v4-core/IHooks` so all four V4 callbacks PRISM uses
///      keep their canonical selectors and ABI shape — implementations
///      override the `IHooks` methods directly. The four callbacks
///      PRISM ENABLES are bits 6, 7, 8, 10 (`afterSwap`, `beforeSwap`,
///      `afterRemoveLiquidity`, `afterAddLiquidity`); the deployed hook
///      address satisfies `address & 0x3FFF == 0x05C0` per ADR-002.
///
///      A bug in `afterAddLiquidity` or `afterRemoveLiquidity` MUST NOT
///      revert (ADR-002 §hard rule). Those callbacks sit on the
///      withdraw hot path; reverting them violates invariant 6.
///      Implementations are emit-only or pure state cleanup.
///
///      The hook is a singleton (ADR-002): a single deployed instance
///      services every PRISM vault. State is sharded by `PoolId` and
///      vault address inside the implementation.
interface IProtocolHook is IHooks {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when `beforeSwap` recomputes the dynamic fee for
    ///         a pool.
    /// @param poolId Indexed `PoolId` (cast to bytes32 for indexer
    ///        ergonomics — V4's `PoolId` is `bytes32` underneath).
    /// @param newFee Fee in pip (1e-6); written as the V4
    ///        `OVERRIDE_FEE_FLAG`-tagged return value.
    /// @param volatility Snapshot of the short-window EWMA used to
    ///        compute the new fee; for dApp / analytics consumers.
    event FeeUpdated(bytes32 indexed poolId, uint24 newFee, uint256 volatility);

    /// @notice Emitted on every swap through the hook — the v1.0 MEV
    ///         capture surface is observation-only.
    /// @param poolId Indexed `PoolId`.
    /// @param tick Pool tick *after* the swap.
    /// @param sqrtPriceX96 Pool sqrt-price after the swap (Q64.96).
    event SwapObserved(bytes32 indexed poolId, int24 tick, uint160 sqrtPriceX96);

    /// @notice Emitted when v1.1 backrun execution captures MEV and
    ///         credits the captured profit to a vault. v1.0 emits no
    ///         MEVCaptured events (observation only); the event lives
    ///         on the interface so v1.1 can ship without a hook
    ///         redeploy of the EVENT topic.
    /// @param vault Indexed vault that received the credit.
    /// @param amount Amount captured, denominated in `isToken0 ? token0 : token1`.
    /// @param isToken0 Which token the captured amount is denominated in.
    event MEVCaptured(address indexed vault, uint256 amount, bool isToken0);

    // -------------------------------------------------------------------------
    // Mutators
    // -------------------------------------------------------------------------

    /// @notice Register a `Vault` against this hook so the hook can
    ///         attribute MEV captures and per-pool state to the right
    ///         vault.
    /// @dev Called by `VaultFactory` immediately after vault deployment
    ///      so the hook learns the `PoolId → vault` mapping. Reverts
    ///      via `Errors.OnlyOwner` (or the access-controlled equivalent
    ///      chosen by the implementation) for non-factory callers.
    /// @param vault The vault address to register against this hook.
    function registerVault(address vault) external;

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice The current dynamic fee the hook will return from
    ///         `beforeSwap` for this pool, in pip (1e-6 units; e.g.
    ///         3_000 = 0.30%). Used by the dApp for fee display and by
    ///         the keeper for simulation.
    /// @param poolId The `PoolId` (V4 hash of the `PoolKey`) cast to
    ///        bytes32.
    /// @return fee Current dynamic fee in pip.
    function currentFee(bytes32 poolId) external view returns (uint24 fee);

    /// @notice Per-vault MEV profit ledger. v1.0 always returns
    ///         `(0, 0)` because v1.0 only observes; v1.1 populates as
    ///         backruns execute.
    /// @dev Returning two amounts (token0 + token1) lets v1.1 capture
    ///      profits in either currency depending on the backrun
    ///      direction without changing the interface surface.
    /// @param vault The vault to read.
    /// @return amount0 MEV profits in token0 awaiting distribution.
    /// @return amount1 MEV profits in token1 awaiting distribution.
    function mevProfits(address vault) external view returns (uint256 amount0, uint256 amount1);

    /// @notice The exact permissions matrix this hook implements.
    /// @dev MUST match the bits encoded in the deployed hook address —
    ///      `PoolManager.initialize` reverts via
    ///      `Hooks.HookAddressNotValid` otherwise (invariant #7,
    ///      ADR-002). PRISM hooks return:
    ///        beforeSwap = true (bit 7)
    ///        afterSwap = true (bit 6)
    ///        afterAddLiquidity = true (bit 10)
    ///        afterRemoveLiquidity = true (bit 8)
    ///      All other flags false. Combined: `0x05C0`.
    /// @return permissions The struct of all 14 V4 hook permission flags.
    function getHookPermissions() external pure returns (Hooks.Permissions memory permissions);
}
