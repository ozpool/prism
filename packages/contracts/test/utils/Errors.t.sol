// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Errors} from "../../src/utils/Errors.sol";

/// @notice Selector regression + revert-shape tests for `Errors`.
/// @dev `Errors` is a pure declaration library — there is no behaviour to
///      exercise other than:
///      1. Selectors are stable across refactors. Third parties index
///         reverts by selector; an accidental signature change is a
///         consumer-breaking bug. Snapshotted explicitly here.
///      2. Encoded args round-trip through `abi.decode`. Catches the
///         "I added a uint256 arg but consumers still encode for an
///         empty error" class of mistake.
contract ErrorsTest is Test {
    // -------------------------------------------------------------------------
    // Selector snapshots
    // -------------------------------------------------------------------------
    //
    // To regenerate after intentional signature changes:
    //
    //   forge inspect Errors errors --json | jq
    //
    // and update the constants below. Bumping any of these is a breaking
    // change for downstream indexers — bump the major version.

    function test_selector_OnlyOwner() external pure {
        assertEq(Errors.OnlyOwner.selector, bytes4(keccak256("OnlyOwner()")));
    }

    function test_selector_OnlyKeeper() external pure {
        assertEq(Errors.OnlyKeeper.selector, bytes4(keccak256("OnlyKeeper()")));
    }

    function test_selector_OnlyPoolManager() external pure {
        assertEq(Errors.OnlyPoolManager.selector, bytes4(keccak256("OnlyPoolManager()")));
    }

    function test_selector_ZeroAddress() external pure {
        assertEq(Errors.ZeroAddress.selector, bytes4(keccak256("ZeroAddress()")));
    }

    function test_selector_SlippageExceeded() external pure {
        assertEq(Errors.SlippageExceeded.selector, bytes4(keccak256("SlippageExceeded(uint256,uint256)")));
    }

    function test_selector_TVLCapExceeded() external pure {
        assertEq(Errors.TVLCapExceeded.selector, bytes4(keccak256("TVLCapExceeded(uint256,uint256)")));
    }

    function test_selector_DepositsPaused() external pure {
        assertEq(Errors.DepositsPaused.selector, bytes4(keccak256("DepositsPaused()")));
    }

    function test_selector_ZeroShares() external pure {
        assertEq(Errors.ZeroShares.selector, bytes4(keccak256("ZeroShares()")));
    }

    function test_selector_InvalidShareAmount() external pure {
        assertEq(Errors.InvalidShareAmount.selector, bytes4(keccak256("InvalidShareAmount()")));
    }

    function test_selector_WeightsDoNotSum() external pure {
        assertEq(Errors.WeightsDoNotSum.selector, bytes4(keccak256("WeightsDoNotSum(uint256)")));
    }

    function test_selector_MaxPositionsExceeded() external pure {
        assertEq(Errors.MaxPositionsExceeded.selector, bytes4(keccak256("MaxPositionsExceeded(uint256)")));
    }

    function test_selector_InvalidTickRange() external pure {
        assertEq(Errors.InvalidTickRange.selector, bytes4(keccak256("InvalidTickRange(int24,int24)")));
    }

    function test_selector_RebalanceNotNeeded() external pure {
        assertEq(Errors.RebalanceNotNeeded.selector, bytes4(keccak256("RebalanceNotNeeded()")));
    }

    function test_selector_HookNotPermissioned() external pure {
        assertEq(Errors.HookNotPermissioned.selector, bytes4(keccak256("HookNotPermissioned(uint160,uint160)")));
    }

    function test_selector_OracleStale() external pure {
        assertEq(Errors.OracleStale.selector, bytes4(keccak256("OracleStale(uint256)")));
    }

    function test_selector_OracleDeviation() external pure {
        assertEq(Errors.OracleDeviation.selector, bytes4(keccak256("OracleDeviation(uint256)")));
    }

    function test_selector_UnknownOp() external pure {
        assertEq(Errors.UnknownOp.selector, bytes4(keccak256("UnknownOp()")));
    }

    function test_selector_DeltaUnsettled() external pure {
        assertEq(Errors.DeltaUnsettled.selector, bytes4(keccak256("DeltaUnsettled()")));
    }

    function test_selector_Reentrancy() external pure {
        assertEq(Errors.Reentrancy.selector, bytes4(keccak256("Reentrancy()")));
    }

    function test_selector_MathOverflow() external pure {
        assertEq(Errors.MathOverflow.selector, bytes4(keccak256("MathOverflow()")));
    }

    function test_selector_ValueOutOfBounds() external pure {
        assertEq(Errors.ValueOutOfBounds.selector, bytes4(keccak256("ValueOutOfBounds(uint256,uint256)")));
    }

    // -------------------------------------------------------------------------
    // Revert shape (round-trip)
    // -------------------------------------------------------------------------

    function test_revertShape_SlippageExceeded() external {
        vm.expectRevert(abi.encodeWithSelector(Errors.SlippageExceeded.selector, uint256(99), uint256(100)));
        _throwSlippage(99, 100);
    }

    function test_revertShape_WeightsDoNotSum(uint256 actual) external {
        vm.expectRevert(abi.encodeWithSelector(Errors.WeightsDoNotSum.selector, actual));
        _throwWeights(actual);
    }

    function test_revertShape_HookNotPermissioned(uint160 expected, uint160 actual) external {
        vm.expectRevert(abi.encodeWithSelector(Errors.HookNotPermissioned.selector, expected, actual));
        _throwHook(expected, actual);
    }

    function test_revertShape_DepositsPaused() external {
        vm.expectRevert(Errors.DepositsPaused.selector);
        _throwPaused();
    }

    // -------------------------------------------------------------------------
    // Throwers — kept tiny so the tests stay focused on the library itself
    // -------------------------------------------------------------------------

    function _throwSlippage(uint256 actual, uint256 min) internal pure {
        revert Errors.SlippageExceeded(actual, min);
    }

    function _throwWeights(uint256 actual) internal pure {
        revert Errors.WeightsDoNotSum(actual);
    }

    function _throwHook(uint160 expected, uint160 actual) internal pure {
        revert Errors.HookNotPermissioned(expected, actual);
    }

    function _throwPaused() internal pure {
        revert Errors.DepositsPaused();
    }
}
