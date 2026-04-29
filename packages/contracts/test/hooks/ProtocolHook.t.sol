// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

import {ProtocolHook} from "../../src/hooks/ProtocolHook.sol";
import {Errors} from "../../src/utils/Errors.sol";

/// Mines a CREATE2 salt that yields an address satisfying the PRISM
/// hook permission mask (0x05C0). Used by the test to deploy ProtocolHook
/// at an address its constructor will accept.
contract HookDeployer {
    bytes32 internal constant CREATE2_INIT_HASH_SALT = bytes32(uint256(0));

    function mineSalt(
        bytes memory creationCode,
        bytes memory ctorArgs
    )
        external
        view
        returns (bytes32 salt, address predicted)
    {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, ctorArgs));
        // 200_000 iterations is enough at 1/16384 hit rate.
        for (uint256 i = 0; i < 200_000; i++) {
            salt = bytes32(i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
            if (uint160(predicted) & 0x3FFF == 0x05C0) {
                return (salt, predicted);
            }
        }
        revert("salt not found");
    }

    function deploy(bytes32 salt, bytes memory creationCode, bytes memory ctorArgs) external returns (address addr) {
        bytes memory initCode = abi.encodePacked(creationCode, ctorArgs);
        assembly {
            addr := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(addr != address(0), "deploy failed");
    }
}

contract ProtocolHookTest is Test {
    address constant POOL_MANAGER = address(0xCafe);
    address constant FACTORY = address(0xBeef);

    HookDeployer deployer;
    ProtocolHook hook;

    function setUp() public {
        deployer = new HookDeployer();
        hook = _deployValidHook();
    }

    function _deployValidHook() internal returns (ProtocolHook) {
        bytes memory ctorArgs = abi.encode(POOL_MANAGER, FACTORY);
        (bytes32 salt, address predicted) = deployer.mineSalt(type(ProtocolHook).creationCode, ctorArgs);
        address deployed = deployer.deploy(salt, type(ProtocolHook).creationCode, ctorArgs);
        require(deployed == predicted, "predicted address mismatch");
        return ProtocolHook(deployed);
    }

    // -------------------------------------------------------------------------
    // Permissions
    // -------------------------------------------------------------------------

    function test_getHookPermissions_returnsExactBits() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap, "beforeSwap");
        assertTrue(p.afterSwap, "afterSwap");
        assertTrue(p.afterAddLiquidity, "afterAddLiquidity");
        assertTrue(p.afterRemoveLiquidity, "afterRemoveLiquidity");

        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    function test_addressBits_matchPermissions() public view {
        // The deployed hook address must encode 0x05C0 in its low 14 bits.
        assertEq(uint160(address(hook)) & 0x3FFF, 0x05C0);
    }

    // -------------------------------------------------------------------------
    // Constructor reverts
    // -------------------------------------------------------------------------

    function test_constructor_revertsOnZeroPoolManager() public {
        bytes memory ctorArgs = abi.encode(address(0), FACTORY);
        // Mine a valid address even with bad ctor args — the bit check
        // happens after the zero check, so we still need a valid address
        // to ensure ZeroAddress fires before HookAddressNotValid.
        (bytes32 salt,) = deployer.mineSalt(type(ProtocolHook).creationCode, ctorArgs);

        vm.expectRevert();
        deployer.deploy(salt, type(ProtocolHook).creationCode, ctorArgs);
    }

    function test_constructor_revertsOnZeroFactory() public {
        bytes memory ctorArgs = abi.encode(POOL_MANAGER, address(0));
        (bytes32 salt,) = deployer.mineSalt(type(ProtocolHook).creationCode, ctorArgs);

        vm.expectRevert();
        deployer.deploy(salt, type(ProtocolHook).creationCode, ctorArgs);
    }

    function test_constructor_revertsOnInvalidAddressBits() public {
        // Deploy with a deliberately bad salt → predicted address won't
        // have the right bits. Constructor's validateHookPermissions
        // reverts.
        bytes memory ctorArgs = abi.encode(POOL_MANAGER, FACTORY);
        bytes32 badSalt = bytes32(uint256(0)); // overwhelmingly unlikely to be valid

        vm.expectRevert();
        deployer.deploy(badSalt, type(ProtocolHook).creationCode, ctorArgs);
    }

    // -------------------------------------------------------------------------
    // onlyPoolManager / onlyFactory
    // -------------------------------------------------------------------------

    function test_beforeSwap_revertsForNonPoolManager() public {
        PoolKey memory key = _emptyKey();
        SwapParams memory params;

        vm.prank(address(0xDeAd));
        vm.expectRevert(Errors.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
    }

    function test_afterSwap_revertsForNonPoolManager() public {
        PoolKey memory key = _emptyKey();
        SwapParams memory params;

        vm.prank(address(0xDeAd));
        vm.expectRevert(Errors.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
    }

    function test_afterAddLiquidity_revertsForNonPoolManager() public {
        PoolKey memory key = _emptyKey();
        ModifyLiquidityParams memory params;

        vm.prank(address(0xDeAd));
        vm.expectRevert(Errors.OnlyPoolManager.selector);
        hook.afterAddLiquidity(address(this), key, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
    }

    function test_afterRemoveLiquidity_revertsForNonPoolManager() public {
        PoolKey memory key = _emptyKey();
        ModifyLiquidityParams memory params;

        vm.prank(address(0xDeAd));
        vm.expectRevert(Errors.OnlyPoolManager.selector);
        hook.afterRemoveLiquidity(address(this), key, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
    }

    function test_registerVault_revertsForNonFactory() public {
        vm.prank(address(0xDeAd));
        vm.expectRevert(Errors.OnlyOwner.selector);
        hook.registerVault(address(0x1234));
    }

    function test_registerVault_revertsOnZeroVault() public {
        vm.prank(FACTORY);
        vm.expectRevert(Errors.ZeroAddress.selector);
        hook.registerVault(address(0));
    }

    // -------------------------------------------------------------------------
    // Disabled callbacks
    // -------------------------------------------------------------------------

    function test_beforeInitialize_revertsAlways() public {
        PoolKey memory key = _emptyKey();
        vm.expectRevert(Errors.UnknownOp.selector);
        hook.beforeInitialize(address(this), key, 0);
    }

    function test_afterInitialize_revertsAlways() public {
        PoolKey memory key = _emptyKey();
        vm.expectRevert(Errors.UnknownOp.selector);
        hook.afterInitialize(address(this), key, 0, 0);
    }

    function test_beforeAddLiquidity_revertsAlways() public {
        PoolKey memory key = _emptyKey();
        ModifyLiquidityParams memory params;
        vm.expectRevert(Errors.UnknownOp.selector);
        hook.beforeAddLiquidity(address(this), key, params, "");
    }

    function test_beforeRemoveLiquidity_revertsAlways() public {
        PoolKey memory key = _emptyKey();
        ModifyLiquidityParams memory params;
        vm.expectRevert(Errors.UnknownOp.selector);
        hook.beforeRemoveLiquidity(address(this), key, params, "");
    }

    // -------------------------------------------------------------------------
    // Stub views (will be replaced in #35/#36)
    // -------------------------------------------------------------------------

    function test_currentFee_returnsDefaultBeforeSwap() public view {
        // No swaps have been observed → fee state is empty → DEFAULT_FEE.
        assertEq(hook.currentFee(bytes32(uint256(1))), 3000);
    }

    // -------------------------------------------------------------------------
    // #40 — additional fuzz coverage
    // -------------------------------------------------------------------------

    /// @dev onlyPoolManager rejects every non-pool-manager caller. Fuzz
    ///      across random sender addresses to confirm the modifier never
    ///      lets a non-PM through.
    function testFuzz_beforeSwap_rejectsAnyNonPoolManager(address caller) public {
        vm.assume(caller != POOL_MANAGER);
        PoolKey memory key = _emptyKey();
        SwapParams memory params;

        vm.prank(caller);
        vm.expectRevert(Errors.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
    }

    function testFuzz_afterSwap_rejectsAnyNonPoolManager(address caller) public {
        vm.assume(caller != POOL_MANAGER);
        PoolKey memory key = _emptyKey();
        SwapParams memory params;

        vm.prank(caller);
        vm.expectRevert(Errors.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
    }

    function testFuzz_registerVault_rejectsAnyNonFactory(address caller) public {
        vm.assume(caller != FACTORY);
        vm.prank(caller);
        vm.expectRevert(Errors.OnlyOwner.selector);
        hook.registerVault(address(0x1234));
    }

    /// @dev Permission bits invariant: across the deployed hook,
    ///      bits 6/7/8/10 are set and all others are zero.
    function test_addressBits_onlyEnabledFlagsSet() public view {
        uint160 addrBits = uint160(address(hook)) & 0x3FFF;
        // Set bits: 6, 7, 8, 10 → 0x40 | 0x80 | 0x100 | 0x400 = 0x5C0
        assertEq(addrBits, 0x05C0);
        // Confirm bits 0..5, 9, 11..13 are all clear.
        assertEq(addrBits & 0x3F, 0);
        assertEq(addrBits & 0x200, 0);
        assertEq(addrBits & 0x3800, 0);
    }

    function test_mevProfits_returnsZeroStub() public view {
        (uint256 a, uint256 b) = hook.mevProfits(address(0x1234));
        assertEq(a, 0);
        assertEq(b, 0);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _emptyKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }
}
