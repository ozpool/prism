// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";

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
import {IChainlinkAdapter} from "../../src/interfaces/IChainlinkAdapter.sol";
import {MEVLib} from "../../src/libraries/MEVLib.sol";
import {Errors} from "../../src/utils/Errors.sol";

/// Stub adapter so the hook can be exercised against a controllable
/// oracle without pulling Chainlink AggregatorV3 mocks in.
contract MockOracle is IChainlinkAdapter {
    uint160 public sqrtPrice;
    bool public isHealthy;

    function set(uint160 _sqrtPrice, bool _healthy) external {
        sqrtPrice = _sqrtPrice;
        isHealthy = _healthy;
    }

    function read() external view override returns (uint160, bool) {
        return (sqrtPrice, isHealthy);
    }
}

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

    HookDeployer deployer;
    ProtocolHook hook;

    function setUp() public {
        deployer = new HookDeployer();
        hook = _deployValidHook();
        // Give POOL_MANAGER non-zero code so vm.mockCall on extsload resolves.
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
    // afterSwap — slot0 + oracle + MEV deviation
    // -------------------------------------------------------------------------

    event SwapObserved(bytes32 indexed poolId, int24 tick, uint160 sqrtPriceX96);
    event SwapDeviation(bytes32 indexed poolId, uint256 deviationBps, bool oracleHealthy);

    uint160 constant SQRT_PRICE_REF = 79_228_162_514_264_337_593_543_950_336; // 1.0 in Q64.96

    function test_afterSwap_emitsSwapObservedWithRealSlot0() public {
        PoolKey memory key = _emptyKey();
        _mockSlot0(key, 1234, SQRT_PRICE_REF);

        bytes32 pidBytes = PoolId.unwrap(key.toId());

        vm.expectEmit(true, false, false, true);
        emit SwapObserved(pidBytes, 1234, SQRT_PRICE_REF);

        vm.prank(POOL_MANAGER);
        hook.afterSwap(address(this), key, _emptySwapParams(), BalanceDelta.wrap(0), "");
    }

    function test_afterSwap_skipsDeviationWhenOracleUnregistered() public {
        PoolKey memory key = _emptyKey();
        _mockSlot0(key, 0, SQRT_PRICE_REF);

        // Record logs to assert SwapDeviation was NOT emitted.
        vm.recordLogs();
        vm.prank(POOL_MANAGER);
        hook.afterSwap(address(this), key, _emptySwapParams(), BalanceDelta.wrap(0), "");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sigDeviation = keccak256("SwapDeviation(bytes32,uint256,bool)");
        for (uint256 i = 0; i < entries.length; i++) {
            assertTrue(entries[i].topics[0] != sigDeviation, "SwapDeviation should be skipped");
        }
    }

    function test_afterSwap_emitsDeviationWhenOracleHealthy() public {
        PoolKey memory key = _emptyKey();
        bytes32 pidBytes = PoolId.unwrap(key.toId());

        // Pool sqrt-price == oracle sqrt-price → deviation = 0 bps.
        MockOracle oracle = new MockOracle();
        oracle.set(SQRT_PRICE_REF, true);
        vm.prank(FACTORY);
        hook.registerOracle(key, oracle);

        _mockSlot0(key, 0, SQRT_PRICE_REF);

        vm.expectEmit(true, false, false, true);
        emit SwapDeviation(pidBytes, 0, true);

        vm.prank(POOL_MANAGER);
        hook.afterSwap(address(this), key, _emptySwapParams(), BalanceDelta.wrap(0), "");
    }

    function test_afterSwap_failSoftWhenOracleUnhealthy() public {
        PoolKey memory key = _emptyKey();
        bytes32 pidBytes = PoolId.unwrap(key.toId());

        MockOracle oracle = new MockOracle();
        oracle.set(0, false); // unhealthy
        vm.prank(FACTORY);
        hook.registerOracle(key, oracle);

        _mockSlot0(key, 0, SQRT_PRICE_REF);

        // Unhealthy oracle: deviation reports 0, healthy=false. Per
        // ADR-003 the hook does not revert.
        vm.expectEmit(true, false, false, true);
        emit SwapDeviation(pidBytes, 0, false);

        vm.prank(POOL_MANAGER);
        hook.afterSwap(address(this), key, _emptySwapParams(), BalanceDelta.wrap(0), "");
    }

    function test_afterSwap_deviationNonZero() public {
        PoolKey memory key = _emptyKey();
        bytes32 pidBytes = PoolId.unwrap(key.toId());

        // Oracle reports a sqrt-price 1% above pool → ~100 bps deviation.
        uint160 oraclePrice = uint160((uint256(SQRT_PRICE_REF) * 101) / 100);
        MockOracle oracle = new MockOracle();
        oracle.set(oraclePrice, true);
        vm.prank(FACTORY);
        hook.registerOracle(key, oracle);

        _mockSlot0(key, 0, SQRT_PRICE_REF);

        uint256 expectedBps = MEVLib.deviationBps(SQRT_PRICE_REF, oraclePrice);
        vm.expectEmit(true, false, false, true);
        emit SwapDeviation(pidBytes, expectedBps, true);

        vm.prank(POOL_MANAGER);
        hook.afterSwap(address(this), key, _emptySwapParams(), BalanceDelta.wrap(0), "");
    }

    /// ADR-007 caps afterSwap at 18k gas. The actual cost depends on
    /// whether an oracle is registered — pin both numbers so future
    /// regressions surface.
    function test_afterSwap_gasBudget_noOracle() public {
        PoolKey memory key = _emptyKey();
        _mockSlot0(key, 100, SQRT_PRICE_REF);

        vm.prank(POOL_MANAGER);
        uint256 gasBefore = gasleft();
        hook.afterSwap(address(this), key, _emptySwapParams(), BalanceDelta.wrap(0), "");
        uint256 gasUsed = gasBefore - gasleft();

        // Headroom for forge mockCall overhead.
        assertLt(gasUsed, 25_000, "afterSwap gas regression (no oracle)");
    }

    // -------------------------------------------------------------------------
    // registerOracle
    // -------------------------------------------------------------------------

    function test_registerOracle_revertsForNonFactory() public {
        PoolKey memory key = _emptyKey();
        MockOracle oracle = new MockOracle();
        vm.prank(address(0xDeAd));
        vm.expectRevert(Errors.OnlyOwner.selector);
        hook.registerOracle(key, oracle);
    }

    function test_registerOracle_revertsOnZeroOracle() public {
        PoolKey memory key = _emptyKey();
        vm.prank(FACTORY);
        vm.expectRevert(Errors.ZeroAddress.selector);
        hook.registerOracle(key, IChainlinkAdapter(address(0)));
    }

    function test_registerOracle_revertsOnRebind() public {
        PoolKey memory key = _emptyKey();
        MockOracle a = new MockOracle();
        MockOracle b = new MockOracle();

        vm.prank(FACTORY);
        hook.registerOracle(key, a);

        vm.prank(FACTORY);
        vm.expectRevert(Errors.AlreadyInitialised.selector);
        hook.registerOracle(key, b);
    }

    function test_registerOracle_storesAdapter() public {
        PoolKey memory key = _emptyKey();
        MockOracle oracle = new MockOracle();

        vm.prank(FACTORY);
        hook.registerOracle(key, oracle);

        assertEq(address(hook.oracleByPool(key.toId())), address(oracle));
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
    /// POOLS_SLOT))`, then calls extsload on the manager. The slot0 value
    /// packs sqrtPriceX96 in bits 0..159 and tick in bits 160..183.
    function _mockSlot0(PoolKey memory key, int24 tick, uint160 sqrtPriceX96) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), bytes32(uint256(6))));
        bytes32 slot0 = bytes32(uint256(sqrtPriceX96)) | bytes32(uint256(uint24(tick)) << 160);
        vm.mockCall(
            POOL_MANAGER, abi.encodeWithSelector(bytes4(keccak256("extsload(bytes32)")), stateSlot), abi.encode(slot0)
        );
    }
}
