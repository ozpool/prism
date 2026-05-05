// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IStrategy} from "../interfaces/IStrategy.sol";
import {Errors} from "../utils/Errors.sol";

/// @title BellStrategy — fixed-shape bell-curve weight distribution
/// @notice Default PRISM strategy. Returns 7 positions arranged as a
///         symmetric bell around the current tick, with hardcoded
///         weights `[500, 1200, 2100, 2400, 2100, 1200, 500]` (bps).
///
///         This PR (#32) implements `computePositions` only — the
///         `shouldRebalance` gate lands in #33.
///
/// @dev Per ADR-005 the strategy is **pure / stateless / vault-agnostic**:
///        - No SSTORE in runtime bytecode (constants + immutables only)
///        - No reads of mutable state
///        - Deterministic across repeat calls with identical inputs
///
///       The weights sum to exactly 10_000 (invariant #2). The vault
///       independently verifies this and reverts via `Errors.WeightsDoNotSum`
///       on mismatch — defence-in-depth, not redundancy.
///
///       Tick alignment: `currentTick` is rounded down to the nearest
///       `tickSpacing` boundary; each position then extends one
///       `tickSpacing` further out from the previous, so the seven
///       positions cover `[center - 4*ts, center + 4*ts]` total range.
contract BellStrategy is IStrategy {
    /// @notice Number of positions this strategy emits.
    uint256 public constant N_POSITIONS = 7;

    /// @notice Per-position bell weights in basis points. Sum = 10_000.
    /// @dev Hardcoded as immutable constants to satisfy ADR-005 purity
    ///      (no SSTORE in bytecode). Order matches `computePositions`
    ///      output, which goes from leftmost (most negative offset) to
    ///      rightmost.
    uint256 internal constant W0 = 500; // outermost left
    uint256 internal constant W1 = 1200;
    uint256 internal constant W2 = 2100;
    uint256 internal constant W3 = 2400; // center
    uint256 internal constant W4 = 2100;
    uint256 internal constant W5 = 1200;
    uint256 internal constant W6 = 500; // outermost right

    /// @inheritdoc IStrategy
    function computePositions(
        int24 currentTick,
        int24 tickSpacing,
        uint256, /*amount0*/
        uint256 /*amount1*/
    )
        external
        pure
        override
        returns (TargetPosition[] memory positions)
    {
        if (tickSpacing <= 0) revert Errors.InvalidTickRange(0, 0);

        // Round currentTick DOWN to the nearest tickSpacing boundary.
        // For negative ticks Solidity's % preserves sign — subtract the
        // remainder if non-zero to get the floor.
        int24 anchor = _floorToSpacing(currentTick, tickSpacing);

        // Seven adjacent positions of width `tickSpacing` each, centred
        // on the anchor. Position i has range
        //   [anchor + (i - 3) * ts, anchor + (i - 2) * ts]
        // so that i=3 spans [anchor, anchor + ts] (the centre tick).
        int24 ts = tickSpacing;

        positions = new TargetPosition[](N_POSITIONS);
        positions[0] = TargetPosition({tickLower: anchor - 3 * ts, tickUpper: anchor - 2 * ts, weight: W0});
        positions[1] = TargetPosition({tickLower: anchor - 2 * ts, tickUpper: anchor - ts, weight: W1});
        positions[2] = TargetPosition({tickLower: anchor - ts, tickUpper: anchor, weight: W2});
        positions[3] = TargetPosition({tickLower: anchor, tickUpper: anchor + ts, weight: W3});
        positions[4] = TargetPosition({tickLower: anchor + ts, tickUpper: anchor + 2 * ts, weight: W4});
        positions[5] = TargetPosition({tickLower: anchor + 2 * ts, tickUpper: anchor + 3 * ts, weight: W5});
        positions[6] = TargetPosition({tickLower: anchor + 3 * ts, tickUpper: anchor + 4 * ts, weight: W6});
    }

    /// @inheritdoc IStrategy
    /// @dev #33 implements the actual gate (tick drift + time threshold +
    ///      24h fallback). For #32 this returns false so the vault
    ///      compiles against the full interface but never rebalances on
    ///      this stub.
    function shouldRebalance(
        int24, /*currentTick*/
        int24, /*lastRebalanceTick*/
        uint256 /*lastRebalanceTimestamp*/
    )
        external
        view
        override
        returns (bool)
    {
        return false;
    }

    /// @dev Round `tick` down to the nearest multiple of `spacing`.
    ///      Handles negative inputs correctly (Solidity's `%` preserves
    ///      sign on signed types).
    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 rem = tick % spacing;
        if (rem == 0) return tick;
        if (tick > 0) return tick - rem;
        return tick - rem - spacing;
    }
}
