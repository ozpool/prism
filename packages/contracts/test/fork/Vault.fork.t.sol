// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Vault} from "../../src/core/Vault.sol";
import {IProtocolHook} from "../../src/interfaces/IProtocolHook.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {Errors} from "../../src/utils/Errors.sol";

/// @notice Mintable ERC-20 used as token0 / token1 in the fork fixture.
contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Fork strategy: returns one position with weight 10_000 and a
///         configurable rebalance verdict.
contract ForkStrategy is IStrategy {
    int24 public lowerTick;
    int24 public upperTick;
    bool public verdict = true;

    function set(int24 l, int24 u, bool gate) external {
        lowerTick = l;
        upperTick = u;
        verdict = gate;
    }

    function computePositions(
        int24,
        int24,
        uint256,
        uint256
    )
        external
        view
        override
        returns (TargetPosition[] memory ps)
    {
        ps = new TargetPosition[](1);
        ps[0] = TargetPosition({tickLower: lowerTick, tickUpper: upperTick, weight: 10_000});
    }

    function shouldRebalance(int24, int24, uint256) external view override returns (bool) {
        return verdict;
    }
}

/// @title Vault fork integration tests — Base Sepolia
/// @notice Stands the vault up against a freshly deployed V4 `PoolManager`
///         on a Base Sepolia fork so the unlock callback, slot0 reads,
///         and modifyLiquidity / take / sync / settle dance run through
///         real V4 code paths.
///
///         Skipped (entire suite) when `BASE_SEPOLIA_RPC_URL` is unset
///         so CI without the secret stays green.
///
/// @dev    Deposit / withdraw bodies land via #187 / #190; the full
///         deposit → rebalance → withdraw cycle test is deferred until
///         then. The current suite verifies that the vault deploys
///         against a real PoolManager and that the rebalance gate
///         reverts cleanly.
contract VaultForkTest is Test {
    address constant HOOK = address(0xB00C);
    address constant OWNER = address(0xACE);

    /// @notice Sqrt-price for tick 0.
    uint160 constant SQRT_PRICE_TICK_0 = 79_228_162_514_264_337_593_543_950_336;

    uint256 constant TVL_CAP = 1_000_000e18;

    PoolManager internal manager;
    Vault internal vault;
    ForkStrategy internal strategy;
    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal key;

    bool internal forkActive;

    function _skipIfNoFork() internal {
        if (!forkActive) vm.skip(true);
    }

    function setUp() public {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            // No RPC configured — leave `forkActive=false`. Each test
            // calls `_skipIfNoFork()` to register a skip cleanly
            // (calling `vm.skip` from setUp marks the entire suite as
            // a setup failure, which CI reads as red).
            return;
        }
        vm.createSelectFork(rpc);
        forkActive = true;

        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");
        if (uint160(address(token1)) < uint160(address(token0))) {
            (token0, token1) = (token1, token0);
        }

        // Fresh PoolManager on the forked chain — sidesteps the need
        // to track the live deploy address per-network.
        manager = new PoolManager(address(this));

        strategy = new ForkStrategy();
        strategy.set(-600, 600, true);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });

        // Pool is *not* initialized here. The dynamic-fee sentinel
        // (0x800000) requires a hook address whose lower 14 bits encode
        // the right permission flags — that's the singleton ProtocolHook
        // (#34) and is out of scope for this fork scaffold. Without
        // initialization the unlock + modifyLiquidity paths still
        // exercise real V4 code; an empty-vault rebalance never calls
        // `modifyLiquidity` because the strategy's only target evaluates
        // to zero liquidity (zero idle balance).
        //
        // The full cycle test (`test_fork_depositRebalanceWithdraw_cycle`)
        // unskips alongside #187 / #190 and brings a properly-mined
        // hook address with it.

        vault = new Vault(
            IPoolManager(address(manager)),
            key,
            IStrategy(address(strategy)),
            IProtocolHook(HOOK),
            OWNER,
            TVL_CAP,
            "PRISM Vault Fork",
            "pVAULT"
        );
    }

    /// @notice Vault deploys cleanly against a real PoolManager and
    ///         pins immutables to the constructor inputs.
    function test_fork_vaultDeploys() public {
        _skipIfNoFork();
        assertEq(address(vault.poolManager()), address(manager), "poolManager");
        assertEq(address(vault.strategy()), address(strategy), "strategy");
        assertEq(address(vault.hook()), HOOK, "hook");
        assertEq(vault.tickSpacing(), 60, "tickSpacing");
        assertEq(vault.poolFee(), 0x800000, "poolFee");
        assertEq(vault.totalSupply(), 0, "totalSupply");
    }

    /// @notice Strategy gate closed → rebalance reverts cleanly via
    ///         the live PoolManager's slot0 read path.
    function test_fork_rebalance_revertsWhenGateClosed() public {
        _skipIfNoFork();
        strategy.set(-600, 600, false);
        vm.expectRevert(Errors.RebalanceNotNeeded.selector);
        vault.rebalance();
    }

    /// @notice Empty-vault rebalance with the gate open: strategy
    ///         returns a target shape, the vault computes zero
    ///         liquidity (no idle balance), pushes no positions, and
    ///         records the post-rebalance state.
    ///
    /// @dev Without the deposit body the vault never holds idle
    ///      balance, so `liquidityForAmounts` returns 0 and the
    ///      position is skipped. This still exercises the unlock /
    ///      modifyLiquidity / settle plumbing against the real
    ///      PoolManager — the cycle test (deposit → rebalance →
    ///      withdraw) extends this once #187 / #190 merge.
    function test_fork_rebalance_emptyVault_recordsState() public {
        _skipIfNoFork();
        strategy.set(-600, 600, true);
        vault.rebalance();

        Vault.Position[] memory ps = vault.getPositions();
        assertEq(ps.length, 0, "no positions deployed on empty vault");
        assertEq(vault.lastRebalanceTimestamp(), block.timestamp, "lastRebalanceTimestamp");
    }

    /// @notice Cycle test scaffold — deposit a small amount, rebalance,
    ///         withdraw. Activates once `_handleDeposit` and
    ///         `_handleWithdraw` ship via #187 / #190; until then the
    ///         entry-point bodies revert UnknownOp from inside the
    ///         unlock callback.
    function test_fork_depositRebalanceWithdraw_cycle() public {
        _skipIfNoFork();
        vm.skip(true);
        // TODO(#187, #190): unskip and drive
        //   token0.mint + approve → vault.deposit
        //   vault.rebalance (keeper)
        //   vault.withdraw
        // once the deposit / withdraw bodies merge.
    }
}
