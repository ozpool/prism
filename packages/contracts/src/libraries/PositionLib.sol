// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";

import {Errors} from "../utils/Errors.sol";

/// @title PositionLib
/// @notice Tick-range validation and liquidity ↔ amount conversions
///         shared across `Vault`, `IStrategy` implementations, and the
///         off-chain keeper simulation.
/// @dev Wraps `v4-core` (`TickMath`, `SqrtPriceMath`) and `v4-periphery`
///      (`LiquidityAmounts`) with a thin PRISM-specific surface:
///        - tick ranges are aligned to the pool's `tickSpacing` and
///          clamped to `[minUsableTick, maxUsableTick]`.
///        - reverts use the canonical `Errors.InvalidTickRange`
///          selector instead of inline strings.
///        - amount-aggregation helpers operate on the `Position` shape
///          the vault and the IVault interface use.
///
///      Pure library — no mutable storage, no external calls.
library PositionLib {
    /// @notice Validate a tick range against the pool's `tickSpacing`
    ///         and the absolute V4 bounds.
    /// @dev Reverts with `Errors.InvalidTickRange(lower, upper)` when:
    ///        - `lower >= upper` (zero or inverted range), OR
    ///        - either tick is not a multiple of `tickSpacing`, OR
    ///        - either tick is outside `[minUsableTick, maxUsableTick]`
    ///          for the supplied `tickSpacing`. The bounds collapse the
    ///          ABI-level [`MIN_TICK`, `MAX_TICK`] into the largest
    ///          range the pool can legally expose at the given spacing.
    /// @param tickLower Lower tick of the position.
    /// @param tickUpper Upper tick of the position.
    /// @param tickSpacing Pool's tick spacing (per `PoolKey`).
    function validateRange(int24 tickLower, int24 tickUpper, int24 tickSpacing) internal pure {
        if (tickLower >= tickUpper) revert Errors.InvalidTickRange(tickLower, tickUpper);

        if (tickLower % tickSpacing != 0 || tickUpper % tickSpacing != 0) {
            revert Errors.InvalidTickRange(tickLower, tickUpper);
        }

        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);
        if (tickLower < minUsable || tickUpper > maxUsable) {
            revert Errors.InvalidTickRange(tickLower, tickUpper);
        }
    }

    /// @notice Round a tick down to the nearest multiple of
    ///         `tickSpacing` while staying within usable bounds.
    /// @dev Useful when a strategy expresses its target as a continuous
    ///      drift band and the vault must snap to legal ticks before
    ///      handing positions to the PoolManager. Negative ticks round
    ///      *down* (toward `-infinity`), matching V4's semantics for
    ///      `tickLower` placement.
    /// @param tick Raw tick value.
    /// @param tickSpacing Pool's tick spacing.
    /// @return aligned `tick` rounded down to a `tickSpacing` multiple
    ///         and clamped into `[minUsableTick, maxUsableTick]`.
    function alignDown(int24 tick, int24 tickSpacing) internal pure returns (int24 aligned) {
        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);

        // Clamp first — keeps subsequent arithmetic inside int24's
        // representable range even for adversarial tick inputs.
        if (tick < minUsable) return minUsable;
        if (tick > maxUsable) return maxUsable;

        // Solidity floor division for negatives rounds toward zero;
        // adjust manually to round toward -infinity (V4 lower-tick
        // semantics) when the remainder is non-zero.
        int24 remainder = tick % tickSpacing;
        if (remainder != 0 && tick < 0) {
            aligned = tick - remainder - tickSpacing;
        } else {
            aligned = tick - remainder;
        }

        // After alignment a negative tick may sit one spacing below
        // minUsable; clamp the tail.
        if (aligned < minUsable) aligned = minUsable;
        if (aligned > maxUsable) aligned = maxUsable;
    }

    /// @notice Compute the maximum liquidity a position can host given
    ///         the current pool sqrt-price and the desired token
    ///         amounts.
    /// @dev Wraps `LiquidityAmounts.getLiquidityForAmounts`. Validates
    ///      the tick range first; reverts via `Errors.InvalidTickRange`
    ///      on malformed input. Returns the smaller of the two
    ///      single-side liquidity amounts when the current price sits
    ///      inside the range.
    /// @param sqrtPriceX96 Current pool sqrt-price (Q64.96).
    /// @param tickLower Lower tick of the position.
    /// @param tickUpper Upper tick of the position.
    /// @param tickSpacing Pool's tick spacing.
    /// @param amount0 Available token0.
    /// @param amount1 Available token1.
    /// @return liquidity Maximum V4 liquidity units the position can host.
    function liquidityForAmounts(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        int24 tickSpacing,
        uint256 amount0,
        uint256 amount1
    )
        internal
        pure
        returns (uint128 liquidity)
    {
        validateRange(tickLower, tickUpper, tickSpacing);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
    }

    /// @notice Compute token0 / token1 amounts represented by a given
    ///         liquidity amount in a tick range at the current pool
    ///         sqrt-price.
    /// @dev Reproduces the V3 / V4 piecewise formula:
    ///        - price ≤ lower → all amount0
    ///        - price ≥ upper → all amount1
    ///        - in-range      → mixed
    ///      Used for `getTotalAmounts` and for slippage-bound
    ///      computation on rebalance.
    /// @param sqrtPriceX96 Current pool sqrt-price (Q64.96).
    /// @param tickLower Lower tick of the position.
    /// @param tickUpper Upper tick of the position.
    /// @param tickSpacing Pool's tick spacing.
    /// @param liquidity V4 liquidity units in the position.
    /// @return amount0 Token0 representation of the position's value.
    /// @return amount1 Token1 representation of the position's value.
    function amountsForLiquidity(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        int24 tickSpacing,
        uint128 liquidity
    )
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        validateRange(tickLower, tickUpper, tickSpacing);
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);

        if (sqrtPriceX96 <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, false);
        } else if (sqrtPriceX96 >= sqrtB) {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, false);
        } else {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtB, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtPriceX96, liquidity, false);
        }
    }
}
