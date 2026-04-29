// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IStrategy
/// @notice Pluggable rebalance-shape API. A strategy decides
///         (a) the tick-range positions a vault should hold given the
///         current pool tick and the vault's available assets, and
///         (b) when the vault should rebalance into a new shape.
/// @dev Implementations MUST satisfy the purity contract codified in
///      ADR-005: deterministic, stateless, vault-agnostic. Concretely:
///        - `computePositions` and `shouldRebalance` are `view` and
///          MUST NOT read mutable storage on the strategy or any other
///          contract.
///        - Repeated calls with identical inputs MUST return identical
///          outputs. No `block.*`, `tx.origin`, oracle reads, or vault
///          storage reads.
///        - `block.timestamp` is permitted only inside `shouldRebalance`
///          and only as an input to the 24h liveness fallback.
///        - The strategy contract MUST NOT contain SSTORE in its
///          runtime bytecode (immutables and constants only). Enforced
///          by CI bytecode scan.
///
///      The vault is the trust boundary. After every call to
///      `computePositions`, the vault re-checks invariants (#2 weight
///      sum == 10_000, #3 length <= MAX_POSITIONS) and reverts via
///      `Errors.WeightsDoNotSum` / `Errors.MaxPositionsExceeded` if the
///      strategy returns malformed output.
interface IStrategy {
    /// @notice One target position the strategy wants the vault to hold.
    /// @param tickLower Lower tick — MUST be aligned to the pool's
    ///        `tickSpacing` and strictly less than `tickUpper`.
    /// @param tickUpper Upper tick — MUST be aligned and strictly greater
    ///        than `tickLower`.
    /// @param weight Share of total vault liquidity assigned to this
    ///        position, in basis points. Σ `weight` over all returned
    ///        positions MUST equal exactly 10_000 (invariant #2). Any
    ///        rounding remainder must be absorbed by the strategy
    ///        before returning.
    struct TargetPosition {
        int24 tickLower;
        int24 tickUpper;
        uint256 weight;
    }

    /// @notice Compute the target liquidity shape given the current pool
    ///         tick, the pool's tick spacing, and the vault's available
    ///         token0 / token1.
    /// @dev Pure function: deterministic, reads no mutable state. The
    ///      vault calls this from inside its `unlockCallback` (per
    ///      ADR-004) so the function MUST be cheap — `BellStrategy`
    ///      sits at ~50k gas for N=7.
    ///
    ///      Returns no more than `MAX_POSITIONS` (= 30) positions; the
    ///      vault enforces the cap independently. Returning more is
    ///      not undefined — it is rejected with
    ///      `Errors.MaxPositionsExceeded`.
    ///
    ///      `currentTick` and `tickSpacing` come from
    ///      `IPoolManager.getSlot0` / `PoolKey.tickSpacing`. `amount0`
    ///      and `amount1` are the vault's totals at the moment of the
    ///      call. The strategy treats these as opaque numbers; provenance
    ///      is the vault's concern (ADR-005 §vault-agnosticism).
    /// @param currentTick The pool's current tick.
    /// @param tickSpacing The pool's tick spacing.
    /// @param amount0 Vault's total token0 (idle + position-equivalent).
    /// @param amount1 Vault's total token1 (idle + position-equivalent).
    /// @return positions The target tick-range positions and their weights.
    function computePositions(
        int24 currentTick,
        int24 tickSpacing,
        uint256 amount0,
        uint256 amount1
    )
        external
        view
        returns (TargetPosition[] memory positions);

    /// @notice Decide whether the vault should rebalance now.
    /// @dev `view`; called by the vault and off-chain by the keeper as a
    ///      simulation gate before submission. Implementations typically
    ///      return true when:
    ///        - tick has drifted by more than the strategy's threshold,
    ///          OR
    ///        - more than the strategy's `timeFallback` seconds have
    ///          elapsed since the last rebalance (24h liveness floor).
    ///
    ///      `block.timestamp` MAY be read here, and ONLY here within the
    ///      strategy, exclusively for the time-fallback comparison.
    ///      No other implicit input (oracle, vault state, etc.).
    /// @param currentTick Pool's current tick from `getSlot0`.
    /// @param lastRebalanceTick Tick at the most recent rebalance (vault
    ///        bookkeeping).
    /// @param lastRebalanceTimestamp `block.timestamp` of the most recent
    ///        rebalance (vault bookkeeping).
    /// @return rebalance Whether the vault should rebalance.
    function shouldRebalance(
        int24 currentTick,
        int24 lastRebalanceTick,
        uint256 lastRebalanceTimestamp
    )
        external
        view
        returns (bool rebalance);
}
