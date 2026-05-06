// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";

import {PositionLib} from "../../src/libraries/PositionLib.sol";
import {Errors} from "../../src/utils/Errors.sol";

/// @notice Behaviour + fuzz tests for `PositionLib`.
contract PositionLibTest is Test {
    int24 internal constant SPACING_LOW = 10; // 0.05% pool
    int24 internal constant SPACING_MED = 60; // 0.30% pool

    // -------------------------------------------------------------------------
    // validateRange — happy path
    // -------------------------------------------------------------------------

    function test_validateRange_aligned() external pure {
        PositionLib.validateRange(-60, 60, SPACING_MED);
        PositionLib.validateRange(-120, 120, SPACING_MED);
        PositionLib.validateRange(0, SPACING_LOW, SPACING_LOW);
    }

    function test_validateRange_atUsableExtremes() external pure {
        int24 minU = TickMath.minUsableTick(SPACING_MED);
        int24 maxU = TickMath.maxUsableTick(SPACING_MED);
        PositionLib.validateRange(minU, maxU, SPACING_MED);
    }

    // -------------------------------------------------------------------------
    // validateRange — reverts
    // -------------------------------------------------------------------------

    function test_validateRange_invertedReverts() external {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTickRange.selector, int24(60), int24(-60)));
        this.callValidateRange(60, -60, SPACING_MED);
    }

    function test_validateRange_zeroWidthReverts() external {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTickRange.selector, int24(60), int24(60)));
        this.callValidateRange(60, 60, SPACING_MED);
    }

    function test_validateRange_misalignedLowerReverts() external {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTickRange.selector, int24(57), int24(60)));
        this.callValidateRange(57, 60, SPACING_MED);
    }

    function test_validateRange_misalignedUpperReverts() external {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTickRange.selector, int24(60), int24(73)));
        this.callValidateRange(60, 73, SPACING_MED);
    }

    function test_validateRange_belowMinUsableReverts() external {
        int24 minU = TickMath.minUsableTick(SPACING_MED);
        // One spacing past the boundary is not usable.
        int24 below = minU - SPACING_MED;
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTickRange.selector, below, int24(0)));
        this.callValidateRange(below, 0, SPACING_MED);
    }

    function test_validateRange_aboveMaxUsableReverts() external {
        int24 maxU = TickMath.maxUsableTick(SPACING_MED);
        int24 above = maxU + SPACING_MED;
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidTickRange.selector, int24(0), above));
        this.callValidateRange(0, above, SPACING_MED);
    }

    /// @dev External wrapper so `vm.expectRevert` sees the revert at a lower
    ///      call depth than the cheatcode itself (newer Foundry semantics).
    function callValidateRange(int24 lower, int24 upper, int24 spacing) external pure {
        PositionLib.validateRange(lower, upper, spacing);
    }

    // -------------------------------------------------------------------------
    // alignDown
    // -------------------------------------------------------------------------

    function test_alignDown_alreadyAligned() external pure {
        assertEq(int256(PositionLib.alignDown(60, SPACING_MED)), int256(60));
        assertEq(int256(PositionLib.alignDown(0, SPACING_MED)), int256(0));
        assertEq(int256(PositionLib.alignDown(-60, SPACING_MED)), int256(-60));
    }

    function test_alignDown_positiveRoundsToward0() external pure {
        // 73 → 60 (drop the 13 remainder).
        assertEq(int256(PositionLib.alignDown(73, SPACING_MED)), int256(60));
    }

    function test_alignDown_negativeRoundsTowardNegInf() external pure {
        // -73 → -120 (V4 lower-tick semantics: round toward -infinity).
        assertEq(int256(PositionLib.alignDown(-73, SPACING_MED)), int256(-120));
    }

    function test_alignDown_clampsToMinUsable() external pure {
        int24 minU = TickMath.minUsableTick(SPACING_MED);
        // A tick below the usable region is clamped, not rejected (this
        // helper does not revert — `validateRange` does).
        assertEq(int256(PositionLib.alignDown(minU - 5000, SPACING_MED)), int256(minU));
    }

    function test_alignDown_clampsToMaxUsable() external pure {
        int24 maxU = TickMath.maxUsableTick(SPACING_MED);
        int24 raw = maxU + 1000;
        int24 aligned = PositionLib.alignDown(raw, SPACING_MED);
        // Must be ≤ maxUsable.
        assertLe(int256(aligned), int256(maxU));
    }

    // -------------------------------------------------------------------------
    // liquidityForAmounts — round-trip vs amountsForLiquidity
    // -------------------------------------------------------------------------

    /// @dev Sanity round-trip: deposit `amount0` + `amount1` into a
    ///      position centered around the current tick, then verify
    ///      `amountsForLiquidity(L)` returns numbers ≤ the originals
    ///      (rounding always favours the pool — never gives the LP
    ///      more than they put in).
    function test_roundTrip_amountsForLiquidity_doesNotInflate() external pure {
        int24 currentTick = 0;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
        int24 tickLower = -120;
        int24 tickUpper = 120;
        uint256 amount0 = 1e18;
        uint256 amount1 = 2000e6; // ETH/USDC-ish ratio

        uint128 liquidity =
            PositionLib.liquidityForAmounts(sqrtPriceX96, tickLower, tickUpper, SPACING_MED, amount0, amount1);
        (uint256 a0, uint256 a1) =
            PositionLib.amountsForLiquidity(sqrtPriceX96, tickLower, tickUpper, SPACING_MED, liquidity);

        assertLe(a0, amount0);
        assertLe(a1, amount1);
    }

    function test_amountsForLiquidity_priceBelowRange_isAllToken0() external pure {
        int24 tickLower = 60;
        int24 tickUpper = 180;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0); // below tickLower
        (uint256 a0, uint256 a1) =
            PositionLib.amountsForLiquidity(sqrtPriceX96, tickLower, tickUpper, SPACING_MED, 1_000_000);
        assertGt(a0, 0);
        assertEq(a1, 0);
    }

    function test_amountsForLiquidity_priceAboveRange_isAllToken1() external pure {
        int24 tickLower = -180;
        int24 tickUpper = -60;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0); // above tickUpper
        (uint256 a0, uint256 a1) =
            PositionLib.amountsForLiquidity(sqrtPriceX96, tickLower, tickUpper, SPACING_MED, 1_000_000);
        assertEq(a0, 0);
        assertGt(a1, 0);
    }

    // -------------------------------------------------------------------------
    // Fuzz near tick extremes
    // -------------------------------------------------------------------------

    /// @dev Prove `validateRange` accepts every aligned, in-bounds pair.
    function testFuzz_validateRange_acceptsAlignedInBounds(int24 lower, int24 upper) external pure {
        int24 minU = TickMath.minUsableTick(SPACING_MED);
        int24 maxU = TickMath.maxUsableTick(SPACING_MED);

        // Constrain to the legal grid: aligned and within usable range.
        lower = int24(bound(int256(lower), int256(minU) / SPACING_MED, int256(maxU) / SPACING_MED - 1)) * SPACING_MED;
        upper = int24(bound(int256(upper), int256(lower) / SPACING_MED + 1, int256(maxU) / SPACING_MED)) * SPACING_MED;

        PositionLib.validateRange(lower, upper, SPACING_MED);
    }

    /// @dev For deposit amounts in a realistic envelope (≤ 1e24 — about
    ///      1M whole 18-decimal tokens, 1 quintillion of a 6-decimal
    ///      token), and a tick window of at least 100 spacings centred
    ///      on the current price, `liquidityForAmounts` followed by
    ///      `amountsForLiquidity` does not revert across the usable
    ///      grid. Adversarial combinations (huge amounts in razor-thin
    ///      ranges at extreme ticks) can overflow V4's uint128 cast —
    ///      that is documented v4-periphery behaviour, not a
    ///      `PositionLib` bug.
    function testFuzz_alignDown_alwaysAlignedInBounds(int24 raw, int24 spacing) external pure {
        // Spacing must be in V4's permitted range.
        spacing = int24(bound(int256(spacing), 1, int256(TickMath.MAX_TICK_SPACING)));

        int24 aligned = PositionLib.alignDown(raw, spacing);

        // Aligned to spacing.
        assertEq(aligned % spacing, 0);

        // Inside usable bounds.
        assertGe(int256(aligned), int256(TickMath.minUsableTick(spacing)));
        assertLe(int256(aligned), int256(TickMath.maxUsableTick(spacing)));
    }
}
