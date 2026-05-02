// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {Vault} from "../../src/core/Vault.sol";
import {IProtocolHook} from "../../src/interfaces/IProtocolHook.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {Errors} from "../../src/utils/Errors.sol";

/// Minimal ERC20 used by the withdraw-body integration tests.
contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Minimal PoolManager stand-in that drives `unlock` straight back into
/// the caller's `unlockCallback` and returns a configurable
/// BalanceDelta from `modifyLiquidity`. Real pool flow is exercised in
/// the fork suite (#42); here we only need enough to drive the
/// unlock callback shape.
contract MockPoolManager {
    BalanceDelta public mockedDelta;

    function setDelta(int128 d0, int128 d1) external {
        mockedDelta = toBalanceDelta(d0, d1);
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function modifyLiquidity(
        PoolKey memory,
        ModifyLiquidityParams memory,
        bytes calldata
    )
        external
        view
        returns (BalanceDelta, BalanceDelta)
    {
        return (mockedDelta, BalanceDelta.wrap(0));
    }

    /// take() in the real PoolManager transfers from manager to recipient.
    /// We mirror that here so the vault's post-take balance accounting
    /// matches production. Tests fund the manager with the tokens they
    /// expect to be paid out.
    function take(Currency currency, address to, uint256 amount) external {
        ERC20(Currency.unwrap(currency)).transfer(to, amount);
    }

    function settle() external payable returns (uint256) {
        return 0;
    }

    function sync(Currency) external {}

    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }
}

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

    function test_rebalance_stubReverts() public {
        vm.expectRevert(Errors.UnknownOp.selector);
        vault.rebalance();
    }

    function test_views_stubsAreSafe() public view {
        // getPositions returns empty array on a fresh vault.
        Vault.Position[] memory ps = vault.getPositions();
        assertEq(ps.length, 0);

        // getTotalAmounts returns 0/0 stub.
        (uint256 a, uint256 b) = vault.getTotalAmounts();
        assertEq(a, 0);
        assertEq(b, 0);
    }

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

// =============================================================================
// VaultWithdrawTest — exercises _handleWithdraw against the mock pool.
// Withdraw burns shares up-front, so we mint shares directly via deal() to
// simulate a prior depositor and seed _positions via vm.store.
// =============================================================================

contract VaultWithdrawTest is Test {
    address constant HOOK = address(0xB00C);
    address constant OWNER = address(0xACE);

    uint256 constant TVL_CAP = 1_000_000e18;

    Vault vault;
    MockERC20 token0;
    MockERC20 token1;
    MockPoolManager pool;
    PoolKey key;

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");
        if (uint160(address(token1)) < uint160(address(token0))) {
            (token0, token1) = (token1, token0);
        }

        pool = new MockPoolManager();
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });

        vault = new Vault(
            IPoolManager(address(pool)), key, IStrategy(address(0xBEEF)), IProtocolHook(HOOK), OWNER, TVL_CAP, "v", "v"
        );
    }

    function test_withdraw_proportionalRemoveTransfersPayout() public {
        // Seed: 100 shares total — 90 to alice, 10 to DEAD (MIN_SHARES burn).
        address alice = address(0xA11CE);
        deal(address(vault), alice, 90, true);
        deal(address(vault), 0x000000000000000000000000000000000000dEaD, 10, true);
        // Single position of 1000 liquidity at [-600, 600].
        _seedPosition(0, -600, 600, 1000);

        // Vault holds 100 idle of token0, 200 idle of token1 (e.g. fee dust).
        token0.mint(address(vault), 100);
        token1.mint(address(vault), 200);

        // modifyLiquidity returns +18 / +27 — alice's 9% liquidity slice (= 90 / 1000).
        pool.setDelta(int128(18), int128(27));
        // Manager pre-funded so take() succeeds.
        token0.mint(address(pool), 18);
        token1.mint(address(pool), 27);

        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = vault.withdraw(90, 0, 0, alice);

        // Idle proportional: 90/100 = 90% of idle balance.
        // owed0 = 18; idleTake0 = 100 * 90 / 100 = 90 → amount0 = 108.
        // owed1 = 27; idleTake1 = 200 * 90 / 100 = 180 → amount1 = 207.
        assertEq(amount0, 108, "amount0");
        assertEq(amount1, 207, "amount1");

        // Recipient received the payout.
        assertEq(token0.balanceOf(alice), 108, "alice token0");
        assertEq(token1.balanceOf(alice), 207, "alice token1");

        // Position liquidity reduced by alice's 90% slice (900 of 1000).
        assertEq(vault.getPositions()[0].liquidity, 1000 - 900, "position liquidity post-burn");
    }

    function test_withdraw_revertsOnSlippage() public {
        address alice = address(0xA11CE);
        deal(address(vault), alice, 50, true);
        _seedPosition(0, -600, 600, 1000);
        pool.setDelta(int128(10), int128(10));
        token0.mint(address(pool), 10);
        token1.mint(address(pool), 10);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.SlippageExceeded.selector, 10, 100));
        vault.withdraw(50, 100, 0, alice);
    }

    function test_withdraw_neverPaused_runsToCompletion() public {
        // Even with deposits paused, withdraw must reach _handleWithdraw.
        vm.prank(OWNER);
        vault.setDepositsPaused(true);

        address alice = address(0xA11CE);
        deal(address(vault), alice, 50, true);
        deal(address(vault), 0x000000000000000000000000000000000000dEaD, 50, true);
        _seedPosition(0, -600, 600, 1000);
        pool.setDelta(int128(5), int128(5));
        token0.mint(address(pool), 5);
        token1.mint(address(pool), 5);

        vm.prank(alice);
        (uint256 a0, uint256 a1) = vault.withdraw(50, 0, 0, alice);
        assertEq(a0, 5, "amount0");
        assertEq(a1, 5, "amount1");
    }

    /// Vault.Position[] is at storage slot 7 in the current layout
    /// (ERC20 fields 0–4, owner 5, depositsPaused/tvlCap 6, _positions 7).
    /// Foundry's `vm.store` on a dynamic array sets length at the slot
    /// itself; the data lives at keccak256(slot). We use the contract's
    /// own getPositions() helper to verify the seed worked.
    function _seedPosition(uint256 index, int24 tickLower, int24 tickUpper, uint128 liquidity) internal {
        bytes32 lengthSlot = bytes32(uint256(7));
        // Set length to index + 1 (overwrites any previous seed).
        vm.store(address(vault), lengthSlot, bytes32(uint256(index + 1)));

        bytes32 dataSlot = keccak256(abi.encode(lengthSlot));
        // Position struct: tickLower (int24) + tickUpper (int24) + liquidity (uint128)
        // pack into one 256-bit slot per index. tickLower in bits 0..23,
        // tickUpper in 24..47, liquidity in 48..175.
        uint256 packed = (uint256(uint24(tickLower)) & ((1 << 24) - 1))
            | ((uint256(uint24(tickUpper)) & ((1 << 24) - 1)) << 24) | (uint256(liquidity) << 48);
        vm.store(address(vault), bytes32(uint256(dataSlot) + index), bytes32(packed));
    }
}
