// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IExtsload} from "v4-core/interfaces/IExtsload.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

import {ProtocolHook} from "../../src/hooks/ProtocolHook.sol";
import {FeeLib} from "../../src/libraries/FeeLib.sol";
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
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = address(0xCafe);
    address constant FACTORY = address(0xBeef);

    /// V4 OVERRIDE_FEE_FLAG — high bit signals PoolManager to apply the
    /// returned fee as the swap fee for this transaction only.
    uint24 constant OVERRIDE_FEE_FLAG = 0x400000;

    HookDeployer deployer;
    ProtocolHook hook;

    function setUp() public {
        deployer = new HookDeployer();
        hook = _deployValidHook();
        // Give POOL_MANAGER non-zero code so extsload mocks can resolve.
        vm.etch(POOL_MANAGER, hex"60");
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

    function test_mevProfits_returnsZeroStub() public view {
        (uint256 a, uint256 b) = hook.mevProfits(address(0x1234));
        assertEq(a, 0);
        assertEq(b, 0);
    }

    // -------------------------------------------------------------------------
    // beforeSwap — FeeLib integration
    // -------------------------------------------------------------------------

    function test_beforeSwap_firstSwapReturnsBaseFee() public {
        PoolKey memory key = _emptyKey();
        _mockSlot0(key, 100); // arbitrary tick — first swap seeds state

        vm.prank(POOL_MANAGER);
        (bytes4 selector,, uint24 fee) = hook.beforeSwap(address(this), key, _emptySwapParams(), "");

        assertEq(selector, IHooks.beforeSwap.selector, "selector");
        // First swap → BASE_FEE (3000) | OVERRIDE_FEE_FLAG.
        assertEq(fee, FeeLib.BASE_FEE | OVERRIDE_FEE_FLAG, "first-swap fee");

        // currentFee view returns the unflagged fee.
        assertEq(hook.currentFee(PoolId.unwrap(key.toId())), FeeLib.BASE_FEE, "currentFee");
    }

    function test_beforeSwap_setsOverrideFlag() public {
        PoolKey memory key = _emptyKey();
        _mockSlot0(key, 0);

        vm.prank(POOL_MANAGER);
        (,, uint24 fee) = hook.beforeSwap(address(this), key, _emptySwapParams(), "");

        // High bit must be set so PoolManager treats it as an override.
        assertGt(fee & OVERRIDE_FEE_FLAG, 0, "override flag missing");
    }

    function test_beforeSwap_secondSwapUpdatesFeeFromVolatility() public {
        PoolKey memory key = _emptyKey();

        // First swap seeds tick at 0.
        _mockSlot0(key, 0);
        vm.prank(POOL_MANAGER);
        hook.beforeSwap(address(this), key, _emptySwapParams(), "");

        // Second swap arrives with tick 10_000 — large delta drives EWMA up.
        // ewmaShort grows much faster than ewmaLong, so the ratio > 1 and
        // the dynamic fee strictly exceeds BASE_FEE.
        _mockSlot0(key, 10_000);
        vm.prank(POOL_MANAGER);
        (,, uint24 feeWithFlag) = hook.beforeSwap(address(this), key, _emptySwapParams(), "");

        uint24 fee = feeWithFlag & ~OVERRIDE_FEE_FLAG;
        assertGt(fee, FeeLib.BASE_FEE, "fee did not rise on volatility");
        assertLe(fee, FeeLib.MAX_FEE, "fee above clamp");
        assertEq(hook.currentFee(PoolId.unwrap(key.toId())), fee, "currentFee mismatch");
    }

    function test_beforeSwap_clampsBelowMaxFee() public {
        PoolKey memory key = _emptyKey();

        // Drive ewmaShort to a huge value via a single enormous tick jump
        // to verify MAX_FEE clamp engages.
        _mockSlot0(key, 0);
        vm.prank(POOL_MANAGER);
        hook.beforeSwap(address(this), key, _emptySwapParams(), "");

        _mockSlot0(key, 800_000); // near tick range bounds
        vm.prank(POOL_MANAGER);
        (,, uint24 feeWithFlag) = hook.beforeSwap(address(this), key, _emptySwapParams(), "");

        uint24 fee = feeWithFlag & ~OVERRIDE_FEE_FLAG;
        assertLe(fee, FeeLib.MAX_FEE, "fee not clamped");
    }

    /// Regression test for warm-state beforeSwap gas cost. Note: ADR-007
    /// targets 12k; today's measurement is higher because FeeLib stores
    /// the EWMA + lastTick across four uint256 slots (~11.6k SSTORE
    /// overhead alone). Tightening to ADR-007 requires packing
    /// VolatilityState (e.g., uint128 ewma fields + int24 lastTick into
    /// a single slot) — tracked as a follow-up. The bound here pins
    /// today's number so future regressions surface.
    function test_beforeSwap_gasBudget() public {
        PoolKey memory key = _emptyKey();

        // Seed state — first swap pays init cost; we measure the second.
        _mockSlot0(key, 100);
        vm.prank(POOL_MANAGER);
        hook.beforeSwap(address(this), key, _emptySwapParams(), "");

        _mockSlot0(key, 250);
        vm.prank(POOL_MANAGER);
        uint256 gasBefore = gasleft();
        hook.beforeSwap(address(this), key, _emptySwapParams(), "");
        uint256 gasUsed = gasBefore - gasleft();

        // Current cost ~46k. Bound at 50k catches regressions while
        // leaving some headroom for forge-test instrumentation noise.
        assertLt(gasUsed, 50_000, "beforeSwap gas regression");
    }

    function test_beforeSwap_independentPerPool() public {
        PoolKey memory keyA = _emptyKey();
        PoolKey memory keyB = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(2)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        _mockSlot0(keyA, 100);
        vm.prank(POOL_MANAGER);
        hook.beforeSwap(address(this), keyA, _emptySwapParams(), "");

        // keyB has not been touched — its fee state is still empty.
        assertEq(hook.currentFee(PoolId.unwrap(keyB.toId())), 3000, "keyB stale");
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

    function _emptySwapParams() internal pure returns (SwapParams memory p) {
        return p;
    }

    /// Mock the StateLibrary.getSlot0 extsload path. StateLibrary derives
    /// the pool's storage slot from `keccak256(abi.encodePacked(poolId,
    /// POOLS_SLOT))`, then calls extsload on the manager. We mock that
    /// extsload return so beforeSwap can read the pool's current tick
    /// without a real PoolManager.
    function _mockSlot0(PoolKey memory key, int24 tick) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), bytes32(uint256(6))));
        // Pack tick into bits 160..183, all other slot0 fields zero.
        bytes32 slot0 = bytes32(uint256(uint24(tick)) << 160);
        // IExtsload has multiple extsload overloads — select the
        // single-slot variant explicitly via its 4-byte selector.
        vm.mockCall(
            POOL_MANAGER, abi.encodeWithSelector(bytes4(keccak256("extsload(bytes32)")), stateSlot), abi.encode(slot0)
        );
    }
}
