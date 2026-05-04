// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {BellStrategy} from "../../src/strategies/BellStrategy.sol";
import {Errors} from "../../src/utils/Errors.sol";

contract BellStrategyTest is Test {
    BellStrategy strat;

    function setUp() public {
        strat = new BellStrategy();
    }

    // -------------------------------------------------------------------------
    // Basic shape
    // -------------------------------------------------------------------------

    function test_computePositions_returns7Positions() public view {
        IStrategy.TargetPosition[] memory ps = strat.computePositions(0, 60, 1e18, 1e18);
        assertEq(ps.length, 7);
    }

    function test_computePositions_weightsSumTo10000() public view {
        IStrategy.TargetPosition[] memory ps = strat.computePositions(0, 60, 0, 0);
        uint256 sum;
        for (uint256 i = 0; i < ps.length; i++) {
            sum += ps[i].weight;
        }
        assertEq(sum, 10_000);
    }

    function test_computePositions_isSymmetric() public view {
        IStrategy.TargetPosition[] memory ps = strat.computePositions(0, 60, 0, 0);
        // Mirrored weights: 0↔6, 1↔5, 2↔4. Centre weight = ps[3].
        assertEq(ps[0].weight, ps[6].weight);
        assertEq(ps[1].weight, ps[5].weight);
        assertEq(ps[2].weight, ps[4].weight);
    }

    function test_computePositions_centerWeightIsLargest() public view {
        IStrategy.TargetPosition[] memory ps = strat.computePositions(0, 60, 0, 0);
        for (uint256 i = 0; i < ps.length; i++) {
            if (i != 3) assertGt(ps[3].weight, ps[i].weight);
        }
    }

    function test_computePositions_revertsOnZeroSpacing() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTickRange.selector, int24(0), int24(0)));
        strat.computePositions(0, 0, 0, 0);
    }

    function test_computePositions_revertsOnNegativeSpacing() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTickRange.selector, int24(0), int24(0)));
        strat.computePositions(0, -1, 0, 0);
    }

    // -------------------------------------------------------------------------
    // Tick alignment
    // -------------------------------------------------------------------------

    function test_computePositions_anchorAlignsAtZero() public view {
        IStrategy.TargetPosition[] memory ps = strat.computePositions(0, 60, 0, 0);
        // Centre position spans [0, 60] when currentTick is 0.
        assertEq(ps[3].tickLower, 0);
        assertEq(ps[3].tickUpper, 60);
    }

    function test_computePositions_alignsPositiveOffTickSpacing() public view {
        // currentTick = 35, spacing = 60 → anchor = 0 (floor).
        IStrategy.TargetPosition[] memory ps = strat.computePositions(35, 60, 0, 0);
        assertEq(ps[3].tickLower, 0);
        assertEq(ps[3].tickUpper, 60);
    }

    function test_computePositions_alignsNegativeOffTickSpacing() public view {
        // currentTick = -10, spacing = 60 → anchor = -60 (floor).
        IStrategy.TargetPosition[] memory ps = strat.computePositions(-10, 60, 0, 0);
        assertEq(ps[3].tickLower, -60);
        assertEq(ps[3].tickUpper, 0);
    }

    function test_computePositions_adjacentPositionsContiguous() public view {
        IStrategy.TargetPosition[] memory ps = strat.computePositions(120, 60, 0, 0);
        for (uint256 i = 1; i < ps.length; i++) {
            assertEq(ps[i].tickLower, ps[i - 1].tickUpper);
        }
    }

    function test_computePositions_widthEqualsSpacing() public view {
        IStrategy.TargetPosition[] memory ps = strat.computePositions(120, 60, 0, 0);
        for (uint256 i = 0; i < ps.length; i++) {
            assertEq(int256(ps[i].tickUpper - ps[i].tickLower), 60);
        }
    }

    function test_computePositions_centeredAroundAnchor() public view {
        IStrategy.TargetPosition[] memory ps = strat.computePositions(180, 60, 0, 0);
        // anchor = 180 (already aligned). Centre i=3 spans [180, 240].
        // Outermost positions: [180 - 3*60, 180 - 2*60] and [180 + 3*60, 180 + 4*60].
        assertEq(ps[0].tickLower, 0);
        assertEq(ps[6].tickUpper, 420);
    }

    // -------------------------------------------------------------------------
    // Determinism (purity contract)
    // -------------------------------------------------------------------------

    function testFuzz_computePositions_deterministic(int24 tick, int8 spacingFactor) public view {
        // tick spacing is positive and bounded — V4 uses values in [1, 16384]
        int24 spacing = int24(uint24(uint8(spacingFactor) | 1)); // odd, non-zero, positive
        if (spacing <= 0) spacing = 1;

        // Bound tick to avoid int24 overflow when computing anchor ± 4*spacing.
        vm.assume(tick > -200_000 && tick < 200_000);

        IStrategy.TargetPosition[] memory a = strat.computePositions(tick, spacing, 1e18, 1e18);
        IStrategy.TargetPosition[] memory b = strat.computePositions(tick, spacing, 1e18, 1e18);

        assertEq(a.length, b.length);
        for (uint256 i = 0; i < a.length; i++) {
            assertEq(a[i].tickLower, b[i].tickLower);
            assertEq(a[i].tickUpper, b[i].tickUpper);
            assertEq(a[i].weight, b[i].weight);
        }
    }

    function testFuzz_computePositions_weightsAlwaysSumTo10000(int24 tick, int8 spacingFactor) public view {
        int24 spacing = int24(uint24(uint8(spacingFactor) | 1));
        if (spacing <= 0) spacing = 1;
        vm.assume(tick > -200_000 && tick < 200_000);

        IStrategy.TargetPosition[] memory ps = strat.computePositions(tick, spacing, 1e18, 1e18);
        uint256 sum;
        for (uint256 i = 0; i < ps.length; i++) {
            sum += ps[i].weight;
        }
        assertEq(sum, 10_000);
    }

    function testFuzz_computePositions_amountsAreOpaque(uint256 a0, uint256 a1) public view {
        // Strategy is vault-agnostic: changing amounts shouldn't change
        // tick layout or weights (only the vault's *liquidity allocation*
        // depends on amounts; the strategy emits weights only).
        IStrategy.TargetPosition[] memory withZero = strat.computePositions(0, 60, 0, 0);
        IStrategy.TargetPosition[] memory withFuzz = strat.computePositions(0, 60, a0, a1);
        for (uint256 i = 0; i < withZero.length; i++) {
            assertEq(withZero[i].tickLower, withFuzz[i].tickLower);
            assertEq(withZero[i].tickUpper, withFuzz[i].tickUpper);
            assertEq(withZero[i].weight, withFuzz[i].weight);
        }
    }

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    function test_constants() public view {
        assertEq(strat.N_POSITIONS(), 7);
        assertEq(strat.TICK_DRIFT_THRESHOLD(), 240);
        assertEq(strat.TIME_THRESHOLD(), 6 hours);
        assertEq(strat.LIVENESS_FALLBACK(), 24 hours);
    }

    // -------------------------------------------------------------------------
    // shouldRebalance — three triggers
    // -------------------------------------------------------------------------

    function test_shouldRebalance_falseWhenAllQuiet() public {
        vm.warp(1_700_000_000);
        // Same tick, just rebalanced.
        assertFalse(strat.shouldRebalance(0, 0, block.timestamp));
    }

    function test_shouldRebalance_firesOnTickDrift() public {
        vm.warp(1_700_000_000);
        // Drift = TICK_DRIFT_THRESHOLD → fires.
        assertTrue(strat.shouldRebalance(240, 0, block.timestamp));
        // Negative-direction drift symmetric.
        assertTrue(strat.shouldRebalance(-240, 0, block.timestamp));
        // Below threshold → no fire.
        assertFalse(strat.shouldRebalance(239, 0, block.timestamp));
    }

    function test_shouldRebalance_firesOnTimeThreshold() public {
        uint256 last = 1_700_000_000;
        vm.warp(last + 6 hours);
        assertTrue(strat.shouldRebalance(0, 0, last));

        vm.warp(last + 6 hours - 1);
        assertFalse(strat.shouldRebalance(0, 0, last));
    }

    function test_shouldRebalance_firesOnLivenessFallback() public {
        uint256 last = 1_700_000_000;
        vm.warp(last + 24 hours);
        // Even with zero tick drift and time-threshold-already-elapsed,
        // the 24h fallback is the strict-largest guarantee.
        assertTrue(strat.shouldRebalance(0, 0, last));
    }

    function test_shouldRebalance_independentTriggers() public {
        uint256 last = 1_700_000_000;
        vm.warp(last + 1);

        // Drift only.
        assertTrue(strat.shouldRebalance(500, 0, last));

        // Time only.
        vm.warp(last + 6 hours);
        assertTrue(strat.shouldRebalance(0, 0, last));
    }
}
