// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {FeeLib} from "../../src/libraries/FeeLib.sol";

/// @notice Behaviour + fuzz tests for `FeeLib`.
/// @dev `FeeLib` is a library that mutates storage on a caller-supplied
///      reference. We host the state in a tiny harness contract so the
///      tests can exercise SLOAD/SSTORE paths.
contract Harness {
    FeeLib.VolatilityState public state;

    function update(int24 currentTick) external {
        FeeLib.update(state, currentTick);
    }

    function calculate() external view returns (uint24) {
        return FeeLib.calculate(state);
    }

    function snapshot() external view returns (int24, uint256, uint256, uint256) {
        return (state.lastTick, state.lastTimestamp, state.ewmaShort, state.ewmaLong);
    }
}

contract FeeLibTest is Test {
    Harness internal h;

    function setUp() public {
        h = new Harness();
    }

    // -------------------------------------------------------------------------
    // calculate — golden values
    // -------------------------------------------------------------------------

    function test_calculate_coldState_returnsBaseFee() external view {
        // No swaps recorded → ewmaLong == 0 → BASE_FEE.
        assertEq(uint256(h.calculate()), uint256(FeeLib.BASE_FEE));
    }

    function test_calculate_steadyState_returnsBaseFee() external {
        // Apply a sequence of *equal* tick steps. ewmaShort and ewmaLong
        // both converge toward the same dt^2 value, so their ratio
        // stabilises near 1.0 and the fee returns to BASE_FEE. Verify
        // with a long warmup.
        for (uint256 i; i < 500; ++i) {
            int24 t = int24(int256(i)) * 60;
            h.update(t);
        }
        uint24 fee = h.calculate();
        // Allow a small drift because half-lives are unequal — but the
        // fee should land within ±20% of BASE_FEE under steady ticks.
        assertGt(uint256(fee), uint256(FeeLib.BASE_FEE) * 80 / 100);
        assertLt(uint256(fee), uint256(FeeLib.BASE_FEE) * 120 / 100);
    }

    function test_calculate_volatilitySpike_raisesFee() external {
        // Warm the long EWMA with small steps.
        for (uint256 i; i < 200; ++i) {
            h.update(int24(int256(i)));
        }
        uint24 baselineFee = h.calculate();

        // Then introduce a sharp jump in tick — short EWMA spikes,
        // long EWMA lags, fee rises.
        h.update(int24(50_000));
        uint24 spikedFee = h.calculate();

        assertGt(uint256(spikedFee), uint256(baselineFee), "fee did not rise on volatility spike");
    }

    function test_calculate_clampedToMaxFee() external {
        // Construct an extreme regime that would push raw above MAX_FEE
        // and verify the clamp.
        h.update(int24(0));
        // Crash short EWMA to a huge value via a maximal tick jump.
        h.update(int24(800_000));
        h.update(int24(-800_000));
        h.update(int24(800_000));
        h.update(int24(-800_000));
        uint24 fee = h.calculate();
        assertLe(uint256(fee), uint256(FeeLib.MAX_FEE));
    }

    function test_calculate_clampedToMinFee() external {
        // After a long quiet period of zero deltas (same tick repeatedly),
        // both EWMAs decay toward the same value — but ewmaLong decays
        // slower. Construct a state where ewmaShort drops below ewmaLong
        // by enough to push the raw fee below MIN_FEE, then verify clamp.
        // Easier path: directly populate state via low-level write.
        bytes32 ewmaShortSlot = bytes32(uint256(2)); // 3rd field of Harness.state
        bytes32 ewmaLongSlot = bytes32(uint256(3));
        vm.store(address(h), ewmaShortSlot, bytes32(uint256(1))); // 1 wei of variance
        vm.store(address(h), ewmaLongSlot, bytes32(uint256(1e30))); // huge baseline
        uint24 fee = h.calculate();
        assertEq(uint256(fee), uint256(FeeLib.MIN_FEE));
    }

    // -------------------------------------------------------------------------
    // update — state mutation
    // -------------------------------------------------------------------------

    function test_update_writesAllFields() external {
        vm.warp(1_000_000);
        h.update(int24(120));

        (int24 lastTick, uint256 lastTs, uint256 short_, uint256 long_) = h.snapshot();
        assertEq(int256(lastTick), int256(120));
        assertEq(lastTs, 1_000_000);
        assertGt(short_, 0);
        assertGt(long_, 0);
    }

    function test_update_zeroDelta_doesNotIncreaseEwma() external {
        h.update(int24(60));
        (,, uint256 firstShort,) = h.snapshot();
        // Same tick again — dt == 0, so EWMA decays toward zero.
        h.update(int24(60));
        (,, uint256 secondShort,) = h.snapshot();
        assertLe(secondShort, firstShort, "EWMA grew on zero-delta tick step");
    }

    // -------------------------------------------------------------------------
    // Fuzz — monotonicity of fee in volatility
    // -------------------------------------------------------------------------

    /// @dev Symmetric tick deltas (positive vs negative same magnitude)
    ///      produce identical EWMAs because the formula squares the
    ///      delta. Verify this property — a bug introducing
    ///      sign-dependence in `update` would catch here.
    function testFuzz_update_signSymmetric(int24 baseTick, int24 magnitude) external {
        magnitude = int24(bound(int256(magnitude), 1, 800_000));
        baseTick = int24(bound(int256(baseTick), -800_000, 800_000));

        Harness h1 = new Harness();
        Harness h2 = new Harness();

        h1.update(baseTick);
        h1.update(baseTick + magnitude);
        (,, uint256 short1, uint256 long1) = h1.snapshot();

        h2.update(baseTick);
        h2.update(baseTick - magnitude);
        (,, uint256 short2, uint256 long2) = h2.snapshot();

        assertEq(short1, short2, "EWMA short is sign-dependent");
        assertEq(long1, long2, "EWMA long is sign-dependent");
    }

    /// @dev Larger magnitudes always produce ewmaShort ≥ smaller
    ///      magnitudes (monotonicity). Bug introducing non-monotonic
    ///      behaviour caught here.
    function testFuzz_update_monotonicInDelta(int24 smaller, int24 larger) external {
        smaller = int24(bound(int256(smaller), 0, 100_000));
        larger = int24(bound(int256(larger), int256(smaller), 200_000));

        Harness h1 = new Harness();
        Harness h2 = new Harness();

        h1.update(0);
        h1.update(smaller);

        h2.update(0);
        h2.update(larger);

        (,, uint256 short1,) = h1.snapshot();
        (,, uint256 short2,) = h2.snapshot();
        assertGe(short2, short1);
    }

    /// @dev Fee is always within `[MIN_FEE, MAX_FEE]` regardless of
    ///      input sequence. Ultimate clamp safety check.
    function testFuzz_calculate_alwaysClamped(int24 t1, int24 t2, int24 t3) external {
        t1 = int24(bound(int256(t1), -800_000, 800_000));
        t2 = int24(bound(int256(t2), -800_000, 800_000));
        t3 = int24(bound(int256(t3), -800_000, 800_000));

        h.update(t1);
        h.update(t2);
        h.update(t3);
        uint24 fee = h.calculate();
        assertGe(uint256(fee), uint256(FeeLib.MIN_FEE));
        assertLe(uint256(fee), uint256(FeeLib.MAX_FEE));
    }

    // -------------------------------------------------------------------------
    // Gas budget — beforeSwap must stay under 12k for update + calculate
    // -------------------------------------------------------------------------

    /// @dev The PRD's `beforeSwap` budget is 12k gas. After warmup (so
    ///      the four SSTOREs are warm), one update + one calculate
    ///      cycle MUST fit under that ceiling. Generous margin to
    ///      absorb test-harness overhead.
    function test_gas_warmUpdate_underBudget() external {
        // Warmup — pay the cold-slot init cost outside the measurement.
        h.update(int24(60));

        uint256 g0 = gasleft();
        h.update(int24(120));
        uint24 fee = h.calculate();
        uint256 used = g0 - gasleft();

        // Smoke check the call still works.
        assertGt(uint256(fee), 0);

        // 12k budget + ~2k harness overhead.
        assertLt(used, 14_000, "FeeLib hot-path exceeded the 12k beforeSwap budget");
    }
}
