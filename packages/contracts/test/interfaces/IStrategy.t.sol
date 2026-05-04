// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IStrategy} from "../../src/interfaces/IStrategy.sol";

/// @notice Compile-time + selector-stability tests for `IStrategy`.
contract IStrategyMock is IStrategy {
    /// @dev Returns one whole-pool position to exercise the round-trip.
    function computePositions(
        int24, /* currentTick */
        int24, /* tickSpacing */
        uint256, /* amount0 */
        uint256 /* amount1 */
    )
        external
        pure
        returns (TargetPosition[] memory positions)
    {
        positions = new TargetPosition[](1);
        positions[0] = TargetPosition({tickLower: -887_220, tickUpper: 887_220, weight: 10_000});
    }

    function shouldRebalance(
        int24, /* currentTick */
        int24, /* lastRebalanceTick */
        uint256 /* lastRebalanceTimestamp */
    )
        external
        pure
        returns (bool)
    {
        return false;
    }
}

contract IStrategyTest is Test {
    // -------------------------------------------------------------------------
    // Mock — implementable end-to-end
    // -------------------------------------------------------------------------

    function test_mock_returnsValidPosition() external {
        IStrategyMock m = new IStrategyMock();
        IStrategy.TargetPosition[] memory ps = m.computePositions(0, 60, 1 ether, 1 ether);

        assertEq(ps.length, 1);
        assertEq(int256(ps[0].tickLower), int256(-887_220));
        assertEq(int256(ps[0].tickUpper), int256(887_220));
        assertEq(ps[0].weight, 10_000);

        assertEq(m.shouldRebalance(0, 0, block.timestamp), false);
    }

    // -------------------------------------------------------------------------
    // Selector snapshots
    // -------------------------------------------------------------------------

    function test_selector_computePositions() external pure {
        assertEq(
            IStrategy.computePositions.selector, bytes4(keccak256("computePositions(int24,int24,uint256,uint256)"))
        );
    }

    function test_selector_shouldRebalance() external pure {
        assertEq(IStrategy.shouldRebalance.selector, bytes4(keccak256("shouldRebalance(int24,int24,uint256)")));
    }

    // -------------------------------------------------------------------------
    // Invariant #2 — strategies that follow the contract sum to 10_000.
    //                Verified here against the mock; production strategies
    //                (BellStrategy, etc.) get their own invariant fuzz.
    // -------------------------------------------------------------------------

    function test_invariant_weightSum_mock(int24 tick, int24 spacing, uint256 a0, uint256 a1) external {
        // Mock returns a single full-range position with weight 10_000;
        // any inputs should preserve the sum.
        IStrategyMock m = new IStrategyMock();
        IStrategy.TargetPosition[] memory ps = m.computePositions(tick, spacing, a0, a1);
        uint256 sum;
        for (uint256 i; i < ps.length; ++i) {
            sum += ps[i].weight;
        }
        assertEq(sum, 10_000);
    }
}
