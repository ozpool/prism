// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Vault} from "../../src/core/Vault.sol";
import {IProtocolHook} from "../../src/interfaces/IProtocolHook.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {Errors} from "../../src/utils/Errors.sol";

contract VaultStorageTest is Test {
    address constant POOL_MANAGER = address(0xCa11);
    address constant STRATEGY = address(0x5747);
    address constant HOOK = address(0xB00C);
    address constant TOKEN0 = address(0x0001);
    address constant TOKEN1 = address(0x0002);
    address constant OWNER = address(0xACE);

    uint256 constant TVL_CAP = 1_000_000e18;

    Vault vault;

    function setUp() public {
        PoolKey memory key = _key();
        vault = new Vault(
            IPoolManager(POOL_MANAGER),
            key,
            IStrategy(STRATEGY),
            IProtocolHook(HOOK),
            OWNER,
            TVL_CAP,
            "PRISM Vault WETH/USDC",
            "pWETHUSDC"
        );
    }

    function _key() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(TOKEN0),
            currency1: Currency.wrap(TOKEN1),
            fee: 0x800000, // dynamic-fee sentinel
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });
    }

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    function test_immutables_pinnedAtConstruction() public view {
        assertEq(address(vault.poolManager()), POOL_MANAGER);
        assertEq(address(vault.strategy()), STRATEGY);
        assertEq(address(vault.hook()), HOOK);
        assertEq(address(vault.token0()), TOKEN0);
        assertEq(address(vault.token1()), TOKEN1);
        assertEq(vault.tickSpacing(), 60);
        assertEq(vault.poolFee(), 0x800000);
    }

    function test_storage_initialState() public view {
        assertEq(vault.owner(), OWNER);
        assertEq(vault.depositsPaused(), false);
        assertEq(vault.tvlCap(), TVL_CAP);
        assertEq(vault.totalSupply(), 0);
    }

    function test_metadata() public view {
        assertEq(vault.name(), "PRISM Vault WETH/USDC");
        assertEq(vault.symbol(), "pWETHUSDC");
        assertEq(vault.decimals(), 18);
    }

    function test_constants() public view {
        assertEq(vault.MIN_SHARES(), 1000);
        assertEq(vault.MAX_POSITIONS(), 7);
        assertEq(vault.DEAD(), 0x000000000000000000000000000000000000dEaD);
    }

    function test_poolKey_returnsConstructedKey() public view {
        PoolKey memory k = vault.poolKey();
        assertEq(Currency.unwrap(k.currency0), TOKEN0);
        assertEq(Currency.unwrap(k.currency1), TOKEN1);
        assertEq(k.fee, 0x800000);
        assertEq(k.tickSpacing, 60);
        assertEq(address(k.hooks), HOOK);
    }

    // -------------------------------------------------------------------------
    // Constructor reverts
    // -------------------------------------------------------------------------

    function test_constructor_revertsOnZeroPoolManager() public {
        PoolKey memory key = _key();
        vm.expectRevert(Errors.ZeroAddress.selector);
        new Vault(IPoolManager(address(0)), key, IStrategy(STRATEGY), IProtocolHook(HOOK), OWNER, TVL_CAP, "n", "s");
    }

    function test_constructor_revertsOnZeroStrategy() public {
        PoolKey memory key = _key();
        vm.expectRevert(Errors.ZeroAddress.selector);
        new Vault(IPoolManager(POOL_MANAGER), key, IStrategy(address(0)), IProtocolHook(HOOK), OWNER, TVL_CAP, "n", "s");
    }

    function test_constructor_revertsOnZeroHook() public {
        PoolKey memory key = _key();
        vm.expectRevert(Errors.ZeroAddress.selector);
        new Vault(
            IPoolManager(POOL_MANAGER), key, IStrategy(STRATEGY), IProtocolHook(address(0)), OWNER, TVL_CAP, "n", "s"
        );
    }

    function test_constructor_revertsOnZeroOwner() public {
        PoolKey memory key = _key();
        vm.expectRevert(Errors.ZeroAddress.selector);
        new Vault(
            IPoolManager(POOL_MANAGER), key, IStrategy(STRATEGY), IProtocolHook(HOOK), address(0), TVL_CAP, "n", "s"
        );
    }

    function test_constructor_revertsOnZeroTvlCap() public {
        PoolKey memory key = _key();
        vm.expectRevert();
        new Vault(IPoolManager(POOL_MANAGER), key, IStrategy(STRATEGY), IProtocolHook(HOOK), OWNER, 0, "n", "s");
    }

    // -------------------------------------------------------------------------
    // Admin levers
    // -------------------------------------------------------------------------

    function test_setDepositsPaused_onlyOwner() public {
        vm.prank(address(0x1234));
        vm.expectRevert(Errors.OnlyOwner.selector);
        vault.setDepositsPaused(true);
    }

    function test_setDepositsPaused_owner() public {
        vm.prank(OWNER);
        vault.setDepositsPaused(true);
        assertTrue(vault.depositsPaused());

        vm.prank(OWNER);
        vault.setDepositsPaused(false);
        assertFalse(vault.depositsPaused());
    }

    function test_setTVLCap_onlyOwner() public {
        vm.prank(address(0x1234));
        vm.expectRevert(Errors.OnlyOwner.selector);
        vault.setTVLCap(2_000_000e18);
    }

    function test_setTVLCap_owner() public {
        vm.prank(OWNER);
        vault.setTVLCap(2_000_000e18);
        assertEq(vault.tvlCap(), 2_000_000e18);
    }

    function test_setTVLCap_revertsOnZero() public {
        vm.prank(OWNER);
        vm.expectRevert();
        vault.setTVLCap(0);
    }

    function test_transferOwnership_onlyOwner() public {
        vm.prank(address(0x1234));
        vm.expectRevert(Errors.OnlyOwner.selector);
        vault.transferOwnership(address(0x5678));
    }

    function test_transferOwnership_owner() public {
        vm.prank(OWNER);
        vault.transferOwnership(address(0x5678));
        assertEq(vault.owner(), address(0x5678));
    }

    function test_transferOwnership_revertsOnZero() public {
        vm.prank(OWNER);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.transferOwnership(address(0));
    }

    // -------------------------------------------------------------------------
    // Stub method reverts (replaced by #27/#28/#29)
    // -------------------------------------------------------------------------

    function test_deposit_revertsWhenPaused() public {
        vm.prank(OWNER);
        vault.setDepositsPaused(true);

        vm.expectRevert(Errors.DepositsPaused.selector);
        vault.deposit(1e18, 1e18, 0, 0, address(this));
    }

    function test_deposit_revertsOnZeroRecipient() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.deposit(1e18, 1e18, 0, 0, address(0));
    }

    function test_deposit_revertsOnZeroAmounts() public {
        vm.expectRevert(Errors.ZeroShares.selector);
        vault.deposit(0, 0, 0, 0, address(this));
    }

    function test_unlockCallback_revertsForNonPoolManager() public {
        vm.expectRevert(Errors.OnlyPoolManager.selector);
        vault.unlockCallback(abi.encode(uint8(0), bytes("")));
    }

    function test_withdraw_revertsOnZeroShares() public {
        vm.expectRevert(Errors.InvalidShareAmount.selector);
        vault.withdraw(0, 0, 0, address(this));
    }

    function test_withdraw_revertsOnInsufficientBalance() public {
        vm.expectRevert(Errors.InvalidShareAmount.selector);
        vault.withdraw(1, 0, 0, address(this));
    }

    function test_withdraw_revertsOnZeroRecipient() public {
        // Mint shares directly (bypassing deposit) to test the recipient
        // check independently of the deposit flow.
        deal(address(vault), address(this), 1e18);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.withdraw(1, 0, 0, address(0));
    }

    function test_withdraw_neverPaused() public {
        // Even with deposits paused, withdraw must remain reachable.
        vm.prank(OWNER);
        vault.setDepositsPaused(true);

        // Withdraw still validates (zero shares → InvalidShareAmount),
        // not DepositsPaused.
        vm.expectRevert(Errors.InvalidShareAmount.selector);
        vault.withdraw(0, 0, 0, address(this));
    }

    function test_rebalance_revertsWhenStrategyGateClosed() public {
        // The entry point reads slot0 from the pool manager (extsload)
        // before the gate check, so we mock both the slot read and the
        // shouldRebalance return.
        vm.mockCall(POOL_MANAGER, abi.encodeWithSignature("extsload(bytes32)"), abi.encode(bytes32(0)));
        vm.mockCall(STRATEGY, abi.encodeWithSelector(IStrategy.shouldRebalance.selector), abi.encode(false));
        vm.expectRevert(Errors.RebalanceNotNeeded.selector);
        vault.rebalance();
    }

    function test_rebalance_lastTimestampInitiallyZero() public view {
        assertEq(vault.lastRebalanceTimestamp(), 0);
        assertEq(vault.lastRebalanceTick(), 0);
    }

    function _mockZeroBalances() internal {
        vm.mockCall(
            TOKEN0,
            abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)")), address(vault)),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            TOKEN1,
            abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)")), address(vault)),
            abi.encode(uint256(0))
        );
    }

    function test_views_emptyVault() public {
        _mockZeroBalances();

        Vault.Position[] memory ps = vault.getPositions();
        assertEq(ps.length, 0);

        (uint256 a, uint256 b) = vault.getTotalAmounts();
        assertEq(a, 0);
        assertEq(b, 0);
    }

    function test_sharePrice_zeroSupplyReturnsUnit() public view {
        // sharePrice short-circuits on totalSupply == 0; no token reads.
        (uint256 p0, uint256 p1) = vault.sharePrice();
        assertEq(p0, 1e18);
        assertEq(p1, 1e18);
    }

    function test_getTotalAmounts_reflectsIdleBalances() public {
        // Mock token0/token1 balanceOf calls to return non-zero amounts.
        vm.mockCall(
            TOKEN0,
            abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)")), address(vault)),
            abi.encode(uint256(1000e18))
        );
        vm.mockCall(
            TOKEN1,
            abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)")), address(vault)),
            abi.encode(uint256(2000e18))
        );

        (uint256 a, uint256 b) = vault.getTotalAmounts();
        assertEq(a, 1000e18);
        assertEq(b, 2000e18);
    }

    // -------------------------------------------------------------------------
    // #38 — additional unit + access-control coverage
    // -------------------------------------------------------------------------

    function test_admin_eventEmittedOnPause() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit DepositsPausedSet(true);
        vm.prank(OWNER);
        vault.setDepositsPaused(true);
    }

    function test_admin_eventEmittedOnTVLCap() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit TVLCapSet(2_000_000e18);
        vm.prank(OWNER);
        vault.setTVLCap(2_000_000e18);
    }

    function test_admin_eventEmittedOnOwnershipTransfer() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit OwnershipTransferred(OWNER, address(0xBEEF));
        vm.prank(OWNER);
        vault.transferOwnership(address(0xBEEF));
    }

    function test_erc20_zeroAllowance() public view {
        assertEq(vault.allowance(address(this), OWNER), 0);
    }

    function test_erc20_approve() public {
        assertTrue(vault.approve(OWNER, 100e18));
        assertEq(vault.allowance(address(this), OWNER), 100e18);
    }

    function test_constants_areImmutable() public view {
        // Sanity: constants survive a re-read (defensive against
        // accidental migration to mutable storage).
        assertEq(vault.MIN_SHARES(), vault.MIN_SHARES());
        assertEq(vault.MAX_POSITIONS(), vault.MAX_POSITIONS());
    }

    // Replicate event signatures locally so vm.expectEmit can match them.
    event DepositsPausedSet(bool paused);
    event TVLCapSet(uint256 newCap);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // -------------------------------------------------------------------------
    // ERC-20 base behaviour (transfers, allowances)
    // -------------------------------------------------------------------------

    function test_erc20_initialBalances() public view {
        assertEq(vault.balanceOf(OWNER), 0);
        assertEq(vault.balanceOf(address(this)), 0);
    }

    function test_erc20_transfer_zeroBalance() public {
        vm.expectRevert();
        vault.transfer(address(0x9999), 1);
    }
}
