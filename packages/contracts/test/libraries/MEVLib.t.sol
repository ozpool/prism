// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {MEVLib} from "../../src/libraries/MEVLib.sol";
import {Errors} from "../../src/utils/Errors.sol";

contract MEVLibTest is Test {
    // -------------------------------------------------------------------------
    // deviationBps
    // -------------------------------------------------------------------------

    function test_deviationBps_zero() public pure {
        uint160 sp = 1 << 96; // arbitrary nonzero
        assertEq(MEVLib.deviationBps(sp, sp), 0);
    }

    function test_deviationBps_oneHundredBps() public pure {
        // pool 1% above oracle. Allow ±1 bps for integer-division rounding.
        uint160 oracle = 1 << 96;
        uint160 pool = uint160((uint256(oracle) * 10_100) / 10_000);
        uint256 d = MEVLib.deviationBps(pool, oracle);
        assertGe(d, 99);
        assertLe(d, 100);
    }

    function test_deviationBps_symmetric() public pure {
        uint160 oracle = 1 << 96;
        uint160 poolUp = uint160((uint256(oracle) * 10_050) / 10_000);
        uint160 poolDn = uint160((uint256(oracle) * 9950) / 10_000);
        uint256 dUp = MEVLib.deviationBps(poolUp, oracle);
        uint256 dDn = MEVLib.deviationBps(poolDn, oracle);
        // Both round to 49 or 50 bps under integer division.
        assertGe(dUp, 49);
        assertLe(dUp, 50);
        assertGe(dDn, 49);
        assertLe(dDn, 50);
    }

    function test_deviationBps_revertsOnZeroOracle() public {
        vm.expectRevert(Errors.MathOverflow.selector);
        MEVLib.deviationBps(1 << 96, 0);
    }

    function testFuzz_deviationBps_neverReverts(uint160 pool, uint160 oracle) public pure {
        vm.assume(oracle > 0);
        // Should not revert; output is bounded.
        uint256 d = MEVLib.deviationBps(pool, oracle);
        // Sanity: deviation is always non-negative, no implicit overflow.
        assertLe(d, type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // shouldBackrun
    // -------------------------------------------------------------------------

    function test_shouldBackrun_unhealthyOracleAlwaysFalse() public pure {
        assertFalse(MEVLib.shouldBackrun(false, 1000, 50));
    }

    function test_shouldBackrun_belowThresholdFalse() public pure {
        assertFalse(MEVLib.shouldBackrun(true, 49, 50));
    }

    function test_shouldBackrun_atThresholdTrue() public pure {
        assertTrue(MEVLib.shouldBackrun(true, 50, 50));
    }

    function test_shouldBackrun_implausibleDeviationFalse() public pure {
        // 10% deviation = MAX_PLAUSIBLE → false.
        assertFalse(MEVLib.shouldBackrun(true, 1000, 50));
        // Above 10% also false.
        assertFalse(MEVLib.shouldBackrun(true, 1500, 50));
    }

    function test_shouldBackrun_normalCase() public pure {
        assertTrue(MEVLib.shouldBackrun(true, 100, 50)); // 1% > 0.5% threshold
    }
}
