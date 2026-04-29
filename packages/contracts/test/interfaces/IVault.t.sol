// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {IVault} from "../../src/interfaces/IVault.sol";

/// @notice Compile-time + selector-stability tests for `IVault`.
/// @dev Interfaces have no runtime behaviour to exercise. The tests:
///      1. Force the interface to compile under the Foundry pipeline by
///         instantiating a mock that fully implements it.
///      2. Snapshot every external function selector and event topic so
///         downstream consumers (frontend ABI exporter, keeper, indexer)
///         catch accidental signature drift in CI.
contract IVaultMock is IVault {
    PoolKey internal _poolKey;

    function setPoolKey(PoolKey memory k) external {
        _poolKey = k;
    }

    // -- IERC20 --
    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    // -- IVault --
    function deposit(uint256, uint256, uint256, uint256, address) external pure returns (uint256, uint256, uint256) {
        return (0, 0, 0);
    }

    function withdraw(uint256, uint256, uint256, address) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function rebalance() external pure {}

    function getPositions() external pure returns (Position[] memory) {
        return new Position[](0);
    }

    function getTotalAmounts() external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }
}

contract IVaultTest is Test {
    // -------------------------------------------------------------------------
    // Mock instantiation — proves interface is implementable end-to-end
    // -------------------------------------------------------------------------

    function test_mock_compilesAndRoundTrips() external {
        IVaultMock m = new IVaultMock();

        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 0x800000, // V4 dynamic-fee flag
            tickSpacing: 60,
            hooks: IHooks(address(0xCAFE))
        });
        m.setPoolKey(k);

        PoolKey memory r = m.poolKey();
        assertEq(Currency.unwrap(r.currency0), address(0x1));
        assertEq(Currency.unwrap(r.currency1), address(0x2));
        assertEq(r.tickSpacing, 60);
        assertEq(address(r.hooks), address(0xCAFE));
    }

    // -------------------------------------------------------------------------
    // Selector snapshots
    // -------------------------------------------------------------------------

    function test_selector_deposit() external pure {
        assertEq(IVault.deposit.selector, bytes4(keccak256("deposit(uint256,uint256,uint256,uint256,address)")));
    }

    function test_selector_withdraw() external pure {
        assertEq(IVault.withdraw.selector, bytes4(keccak256("withdraw(uint256,uint256,uint256,address)")));
    }

    function test_selector_rebalance() external pure {
        assertEq(IVault.rebalance.selector, bytes4(keccak256("rebalance()")));
    }

    function test_selector_getPositions() external pure {
        assertEq(IVault.getPositions.selector, bytes4(keccak256("getPositions()")));
    }

    function test_selector_getTotalAmounts() external pure {
        assertEq(IVault.getTotalAmounts.selector, bytes4(keccak256("getTotalAmounts()")));
    }

    function test_selector_poolKey() external pure {
        assertEq(IVault.poolKey.selector, bytes4(keccak256("poolKey()")));
    }

    // -------------------------------------------------------------------------
    // Event topic snapshots
    // -------------------------------------------------------------------------

    function test_event_Deposit_topic() external pure {
        assertEq(IVault.Deposit.selector, keccak256("Deposit(address,uint256,uint256,uint256)"));
    }

    function test_event_Withdraw_topic() external pure {
        assertEq(IVault.Withdraw.selector, keccak256("Withdraw(address,uint256,uint256,uint256)"));
    }

    function test_event_Rebalanced_topic() external pure {
        assertEq(IVault.Rebalanced.selector, keccak256("Rebalanced(int24,uint256,uint256)"));
    }

    function test_event_FeesCollected_topic() external pure {
        assertEq(IVault.FeesCollected.selector, keccak256("FeesCollected(uint256,uint256)"));
    }

    // -------------------------------------------------------------------------
    // ERC-20 surface inherited
    // -------------------------------------------------------------------------

    function test_inherits_IERC20() external pure {
        // Compile-time guarantee: an `IVault` is assignable to an `IERC20`
        // typed slot. This both documents the inheritance and would fail
        // to compile if the interface were ever changed not to inherit.
        IVault v = IVault(address(0));
        IERC20 e = IERC20(v);
        assertEq(address(e), address(v));
    }
}
