// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {IProtocolHook} from "../../src/interfaces/IProtocolHook.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {Errors} from "../../src/utils/Errors.sol";

contract VaultFactoryTest is Test {
    address constant POOL_MANAGER = address(0xCa11);
    address constant HOOK = address(0xB00C);
    address constant STRATEGY = address(0x5747);
    address constant OWNER = address(0xACE);

    VaultFactory factory;

    function setUp() public {
        factory = new VaultFactory(IPoolManager(POOL_MANAGER), IProtocolHook(HOOK), OWNER);
        // Mock the hook.registerVault call so the factory's create()
        // doesn't revert against a non-existent hook contract.
        vm.mockCall(HOOK, abi.encodeWithSelector(IProtocolHook.registerVault.selector), abi.encode());
    }

    function _key() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0xa)),
            currency1: Currency.wrap(address(0xb)),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });
    }

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    function test_immutables() public view {
        assertEq(address(factory.poolManager()), POOL_MANAGER);
        assertEq(address(factory.hook()), HOOK);
        assertEq(factory.defaultOwner(), OWNER);
    }

    function test_constructor_revertsOnZeroPoolManager() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new VaultFactory(IPoolManager(address(0)), IProtocolHook(HOOK), OWNER);
    }

    function test_constructor_revertsOnZeroHook() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new VaultFactory(IPoolManager(POOL_MANAGER), IProtocolHook(address(0)), OWNER);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new VaultFactory(IPoolManager(POOL_MANAGER), IProtocolHook(HOOK), address(0));
    }

    // -------------------------------------------------------------------------
    // Registry
    // -------------------------------------------------------------------------

    function test_initialRegistryEmpty() public view {
        assertEq(factory.allVaultsLength(), 0);
    }

    function test_create_revertsOnZeroStrategy() public {
        PoolKey memory k = _key();
        vm.expectRevert(Errors.ZeroAddress.selector);
        factory.create(k, IStrategy(address(0)), 1e18, "n", "s", bytes32(0));
    }

    function test_create_deploysVault() public {
        PoolKey memory k = _key();
        address vault = factory.create(k, IStrategy(STRATEGY), 1_000_000e18, "PRISM", "pTKN", bytes32(uint256(0x1234)));
        assertTrue(vault != address(0));
        assertEq(factory.allVaultsLength(), 1);
        assertEq(factory.allVaults(0), vault);
    }

    function test_create_revertsOnDuplicate() public {
        PoolKey memory k = _key();
        factory.create(k, IStrategy(STRATEGY), 1e18, "n", "s", bytes32(uint256(1)));
        vm.expectRevert(Errors.OnlyOwner.selector);
        factory.create(k, IStrategy(STRATEGY), 1e18, "n", "s", bytes32(uint256(2)));
    }

    function test_predictAddress_matchesActualDeploy() public {
        PoolKey memory k = _key();
        bytes32 salt = bytes32(uint256(0xdead));
        address predicted = factory.predictAddress(k, IStrategy(STRATEGY), 1e18, "n", "s", salt);
        address actual = factory.create(k, IStrategy(STRATEGY), 1e18, "n", "s", salt);
        assertEq(predicted, actual);
    }
}
