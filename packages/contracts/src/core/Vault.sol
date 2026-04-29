// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {IProtocolHook} from "../interfaces/IProtocolHook.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IVault} from "../interfaces/IVault.sol";
import {Errors} from "../utils/Errors.sol";

/// @title PRISM Vault — multi-position LP aggregator on Uniswap V4
/// @notice This PR (#26) wires storage layout, ERC-20 share accounting,
///         and the constructor. The hot-path methods land in follow-ups:
///           - deposit  → #27
///           - withdraw → #28
///           - rebalance → #29
///           - views    → #30
///         Until those land the methods revert UnknownOp; the contract
///         compiles, tests can verify the storage shape, and downstream
///         integrators (factory, deployer scripts) can wire against the
///         real ABI.
///
/// @dev Storage layout is part of the immutable surface — moving slots
///      after launch is a redeploy, not an upgrade (ADR-006). Slot
///      ordering is therefore fixed:
///        slot 0..N-1 → ERC20 base (name, symbol, _balances, _allowances, _totalSupply)
///        slot 1     ↓ owner (mutable)
///        slot ↓     → depositsPaused (mutable)
///        slot ↓     → tvlCap (mutable, owner-bounded)
///        slot ↓     → positions (Position[] mutable)
///      The immutables (poolManager, poolKey hashed, strategy, hook,
///      token0, token1, MIN_SHARES, MAX_POSITIONS) live in code, not
///      storage — gas and rotation hygiene.
///
///      ERC-20 transfer hooks: this vault deliberately does NOT
///      override _update / _beforeTokenTransfer. Shares are freely
///      transferable, no transfer fees, no blocklists — composability
///      is non-negotiable per the PRD anti-goals.
///
///      MIN_SHARES = 1000 burned to address(0) on first deposit
///      mitigates the first-depositor inflation attack (PRD §13).
contract Vault is IVault, ERC20 {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice First-deposit shares burned to dead address. Inflation guard.
    uint256 public constant MIN_SHARES = 1000;

    /// @notice Hard cap on positions per vault (PRD invariant 3).
    uint256 public constant MAX_POSITIONS = 7;

    /// @notice Address that receives the MIN_SHARES burn.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // -------------------------------------------------------------------------
    // Immutables — set at construction, never updatable
    // -------------------------------------------------------------------------

    /// @notice Canonical V4 PoolManager.
    IPoolManager public immutable poolManager;

    /// @notice Strategy that computes target positions + the rebalance gate.
    ///         Per ADR-005 implementations are pure / stateless.
    IStrategy public immutable strategy;

    /// @notice Singleton hook that handles dynamic fees + MEV observation.
    IProtocolHook public immutable hook;

    /// @notice Pool tokens, snapshot from `PoolKey` for hot-path use.
    IERC20 public immutable token0;
    IERC20 public immutable token1;

    /// @notice Pool tickSpacing, snapshot for tick-alignment math.
    int24 public immutable tickSpacing;

    /// @notice Fee tier of the underlying pool. For PRISM this is the
    ///         dynamic-fee sentinel `0x800000`; immutable on the vault.
    uint24 public immutable poolFee;

    // -------------------------------------------------------------------------
    // Mutable storage
    // -------------------------------------------------------------------------

    /// @notice Multisig-controlled admin. Holds the two mutable levers
    ///         (depositsPaused, tvlCap) per ADR-006.
    address public owner;

    /// @notice Pause flag for deposits only. Withdrawals are NEVER pausable.
    bool public depositsPaused;

    /// @notice TVL cap in token0 notional units. Enforced by deposit().
    uint256 public tvlCap;

    /// @notice Active positions. Set by `rebalance` (#29). Indexed
    ///         in the order the strategy emits them.
    Position[] internal _positions;

    /// @notice Currency0 / currency1 slots from the pool key — kept as
    ///         storage (not immutable) only because PoolKey is a struct
    ///         and Solidity doesn't allow struct immutables. The values
    ///         match `token0` / `token1` and never change post-construction.
    PoolKey internal _poolKey;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event DepositsPausedSet(bool paused);
    event TVLCapSet(uint256 newCap);

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert Errors.OnlyOwner();
        _;
    }

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    constructor(
        IPoolManager poolManager_,
        PoolKey memory poolKey_,
        IStrategy strategy_,
        IProtocolHook hook_,
        address owner_,
        uint256 tvlCap_,
        string memory name_,
        string memory symbol_
    )
        ERC20(name_, symbol_)
    {
        if (address(poolManager_) == address(0)) revert Errors.ZeroAddress();
        if (address(strategy_) == address(0)) revert Errors.ZeroAddress();
        if (address(hook_) == address(0)) revert Errors.ZeroAddress();
        if (owner_ == address(0)) revert Errors.ZeroAddress();
        if (tvlCap_ == 0) revert Errors.ValueOutOfBounds(tvlCap_, type(uint256).max);
        if (poolKey_.tickSpacing <= 0) revert Errors.InvalidTickRange(0, 0);

        poolManager = poolManager_;
        strategy = strategy_;
        hook = hook_;

        // Snapshot pool tokens. PoolKey enforces currency0 < currency1
        // at the V4 layer; we mirror that ordering for hot-path use.
        token0 = IERC20(_unwrap(poolKey_.currency0));
        token1 = IERC20(_unwrap(poolKey_.currency1));
        tickSpacing = poolKey_.tickSpacing;
        poolFee = poolKey_.fee;

        _poolKey = poolKey_;

        owner = owner_;
        tvlCap = tvlCap_;

        emit OwnershipTransferred(address(0), owner_);
        emit TVLCapSet(tvlCap_);
    }

    // -------------------------------------------------------------------------
    // IERC20Metadata override — already provided by OZ ERC20 base
    // -------------------------------------------------------------------------

    function decimals() public pure override returns (uint8) {
        // Vault shares are 18 decimals regardless of underlying token
        // decimals. Keeps frontend formatting deterministic and matches
        // the convention from ERC-4626.
        return 18;
    }

    // -------------------------------------------------------------------------
    // Admin (ADR-006 two-lever model)
    // -------------------------------------------------------------------------

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert Errors.ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setDepositsPaused(bool paused) external onlyOwner {
        depositsPaused = paused;
        emit DepositsPausedSet(paused);
    }

    function setTVLCap(uint256 newCap) external onlyOwner {
        if (newCap == 0) revert Errors.ValueOutOfBounds(newCap, type(uint256).max);
        tvlCap = newCap;
        emit TVLCapSet(newCap);
    }

    // -------------------------------------------------------------------------
    // IVault method stubs — filled by #27/#28/#29/#30
    // -------------------------------------------------------------------------

    /// @inheritdoc IVault
    function deposit(
        uint256,
        uint256,
        uint256,
        uint256,
        address
    )
        external
        pure
        override
        returns (uint256, uint256, uint256)
    {
        // #27 implements deposit via PoolManager.unlock + multi-position
        // deploy + MIN_SHARES burn on first deposit.
        revert Errors.UnknownOp();
    }

    /// @inheritdoc IVault
    function withdraw(uint256, uint256, uint256, address) external pure override returns (uint256, uint256) {
        // #28 implements withdraw with proportional removal across all
        // positions; never pausable per invariant 6.
        revert Errors.UnknownOp();
    }

    /// @inheritdoc IVault
    function rebalance() external pure override {
        // #29 implements remove-all → bounded swap → redeploy.
        revert Errors.UnknownOp();
    }

    /// @inheritdoc IVault
    function getPositions() external view override returns (Position[] memory) {
        return _positions;
    }

    /// @inheritdoc IVault
    function getTotalAmounts() external pure override returns (uint256, uint256) {
        // #30 wires the per-position amount aggregation against PoolManager
        // state.
        return (0, 0);
    }

    /// @inheritdoc IVault
    function poolKey() external view override returns (PoolKey memory) {
        return _poolKey;
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev Currency is `type Currency is address;` in v4-core.
    function _unwrap(Currency c) private pure returns (address) {
        return Currency.unwrap(c);
    }
}
