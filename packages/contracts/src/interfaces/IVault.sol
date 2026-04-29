// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @title IVault
/// @notice The PRISM vault interface — a multi-position LP aggregator on top
///         of a single Uniswap V4 pool. Users deposit a pair of tokens, the
///         vault refracts that liquidity into N tick-range positions chosen
///         by an `IStrategy`, and ERC-20 shares track each user's claim.
/// @dev Defined ahead of `Vault.sol` (#26) so mocks, tests, and frontend
///      ABIs compile against a single signature surface. Implementations
///      MUST reuse the function and event signatures verbatim — third
///      parties (indexers, the keeper, the dApp) bind to selectors and
///      topic hashes derived here.
///
///      Behavioural contracts (enforced by implementation, not by the
///      interface):
///        - `deposit` reverts via `Errors.DepositsPaused` when paused;
///          `withdraw` is **never** pausable (PRD invariant 6 + ADR-006).
///        - `rebalance` is permissionless and reverts via
///          `Errors.RebalanceNotNeeded` when the strategy's gate is false.
///        - All state-mutating entry points are `nonReentrantTransient`
///          (ADR-004) and run inside one `PoolManager.unlock`.
///        - `getTotalAmounts` and `getPositions` are `view` and may be
///          called freely by frontends and the keeper.
///
///      Slippage: callers MUST pass non-zero `amount0Min` / `amount1Min`
///      on deposit and withdraw. Implementations revert with
///      `Errors.SlippageExceeded` on violation.
interface IVault is IERC20 {
    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice One tick-range position held by the vault.
    /// @dev Position liquidity is owned by the vault inside the
    ///      PoolManager singleton — `liquidity` here is a snapshot for
    ///      view consumers. Authoritative liquidity lives in
    ///      PoolManager state.
    /// @param tickLower Lower tick (must be aligned to pool tickSpacing).
    /// @param tickUpper Upper tick (strictly greater than `tickLower`).
    /// @param liquidity V4 liquidity units assigned to this position.
    struct Position {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted on every successful `deposit` after settlement.
    /// @param user Recipient of the minted shares (`to` arg).
    /// @param amount0 Token0 actually consumed (≤ `amount0Desired`).
    /// @param amount1 Token1 actually consumed (≤ `amount1Desired`).
    /// @param shares Shares minted to `user`.
    event Deposit(address indexed user, uint256 amount0, uint256 amount1, uint256 shares);

    /// @notice Emitted on every successful `withdraw` after settlement.
    /// @param user Recipient of the withdrawn tokens (`to` arg).
    /// @param amount0 Token0 transferred to `to`.
    /// @param amount1 Token1 transferred to `to`.
    /// @param shares Shares burned from the caller.
    event Withdraw(address indexed user, uint256 amount0, uint256 amount1, uint256 shares);

    /// @notice Emitted when the vault completes a rebalance.
    /// @param tick Current pool tick at the moment positions were redeployed.
    /// @param nPositions Number of `TargetPosition`s deployed by the strategy.
    /// @param gasUsed Approximate gas consumed by the rebalance call body
    ///        (recorded for the keeper to size its gas-price ceiling).
    event Rebalanced(int24 tick, uint256 nPositions, uint256 gasUsed);

    /// @notice Emitted when the vault collects accrued LP fees during
    ///         deposit / withdraw / rebalance.
    /// @param fees0 Token0 fees collected this op.
    /// @param fees1 Token1 fees collected this op.
    event FeesCollected(uint256 fees0, uint256 fees1);

    // -------------------------------------------------------------------------
    // Mutators
    // -------------------------------------------------------------------------

    /// @notice Deposit `amount0Desired` token0 + `amount1Desired` token1 in
    ///         exchange for ERC-20 shares of the vault.
    /// @dev Reverts with:
    ///        - `Errors.DepositsPaused` when paused (per ADR-006).
    ///        - `Errors.SlippageExceeded` when realised amounts fall
    ///          below the user-supplied minimums.
    ///        - `Errors.TVLCapExceeded` when the deposit would push
    ///          notional above the per-vault cap.
    ///        - `Errors.ZeroShares` when this is the first deposit and
    ///          the share count would land below `MIN_SHARES`.
    ///      Token transfers happen inside one `PoolManager.unlock`
    ///      callback per ADR-004 — the caller MUST `approve` both
    ///      tokens to the vault prior to calling.
    /// @param amount0Desired Maximum token0 the caller is willing to spend.
    /// @param amount1Desired Maximum token1 the caller is willing to spend.
    /// @param amount0Min Lower bound on token0 actually consumed.
    /// @param amount1Min Lower bound on token1 actually consumed.
    /// @param to Recipient of the minted shares.
    /// @return shares Shares minted to `to`.
    /// @return amount0 Token0 consumed (= idle deposit + flash-accounted spend).
    /// @return amount1 Token1 consumed.
    function deposit(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    )
        external
        returns (uint256 shares, uint256 amount0, uint256 amount1);

    /// @notice Burn `shares` and receive a proportional slice of every
    ///         position the vault holds, plus a proportional slice of
    ///         any idle balances.
    /// @dev Always callable while the caller holds shares — invariant 6
    ///      (withdrawals never pausable). Reverts with:
    ///        - `Errors.InvalidShareAmount` for zero or > balance.
    ///        - `Errors.SlippageExceeded` when realised amounts fall
    ///          below the user-supplied minimums.
    /// @param shares Share count to burn (must be > 0 and ≤ caller's balance).
    /// @param amount0Min Lower bound on token0 transferred out.
    /// @param amount1Min Lower bound on token1 transferred out.
    /// @param to Recipient of the underlying token transfers.
    /// @return amount0 Token0 transferred to `to`.
    /// @return amount1 Token1 transferred to `to`.
    function withdraw(
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    )
        external
        returns (uint256 amount0, uint256 amount1);

    /// @notice Permissionless rebalance trigger.
    /// @dev Reverts with `Errors.RebalanceNotNeeded` when
    ///      `IStrategy.shouldRebalance` returns false. On success the
    ///      vault removes all current positions, performs an optional
    ///      internal swap (slippage-bounded; per ADR-004), and deploys
    ///      the new `TargetPosition[]` returned by
    ///      `IStrategy.computePositions`, all inside one
    ///      `PoolManager.unlock`. Emits `Rebalanced`.
    function rebalance() external;

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Snapshot of the vault's currently deployed positions.
    /// @dev Order matches `IStrategy.computePositions` output from the
    ///      most recent rebalance. Empty array between deployment and
    ///      first deposit.
    /// @return positions Vault-held tick-range positions.
    function getPositions() external view returns (Position[] memory positions);

    /// @notice Total underlying assets the vault represents — idle
    ///         balances plus the token-equivalent of every position's
    ///         in-range liquidity at the current pool sqrt-price.
    /// @dev Used for share-price computation and for the TVL cap check.
    ///      Returns the same numbers the next deposit / withdraw would
    ///      use as denominators.
    /// @return total0 Token0-equivalent of all vault assets.
    /// @return total1 Token1-equivalent of all vault assets.
    function getTotalAmounts() external view returns (uint256 total0, uint256 total1);

    /// @notice Pool this vault provides liquidity to.
    /// @dev Returned by value — `PoolKey` is a struct, not a hash. The
    ///      hook field is the singleton `ProtocolHook` address per
    ///      ADR-002.
    /// @return key The pool key (currency0, currency1, fee=DYNAMIC,
    ///         tickSpacing, hooks=PROTOCOL_HOOK).
    function poolKey() external view returns (PoolKey memory key);
}
