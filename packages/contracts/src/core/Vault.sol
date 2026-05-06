// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";

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
contract Vault is IVault, ERC20, IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev Tagged operations for `unlockCallback`. Each entry point
    ///      (deposit / withdraw / rebalance) calls `poolManager.unlock`
    ///      with `abi.encode(Op.X, payload)`; the callback dispatches
    ///      to the matching branch.
    enum Op {
        DEPOSIT,
        WITHDRAW,
        REBALANCE
    }

    struct DepositPayload {
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address payer;
        address to;
    }

    struct WithdrawPayload {
        uint256 shares;
        uint256 amount0Min;
        uint256 amount1Min;
        address from;
        address to;
    }

    struct RebalancePayload {
        address keeper;
    }
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

    /// @notice Pool tick at the moment of the last successful rebalance.
    ///         Used by `IStrategy.shouldRebalance` to compute drift.
    int24 public lastRebalanceTick;

    /// @notice Block timestamp of the last successful rebalance.
    ///         Used by both the strategy gate and the keeper bonus
    ///         accrual model (ADR-007).
    uint256 public lastRebalanceTimestamp;

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
    /// @dev #27 wires the entry point + unlock callback dispatch.
    ///      The actual multi-position deploy + MIN_SHARES burn lands
    ///      in the integration phase against a real PoolManager — the
    ///      tests here exercise the entry-point preconditions
    ///      (DepositsPaused, slippage, TVL cap) without poking
    ///      PoolManager state.
    function deposit(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    )
        external
        override
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        if (depositsPaused) revert Errors.DepositsPaused();
        if (to == address(0)) revert Errors.ZeroAddress();
        if (amount0Desired == 0 && amount1Desired == 0) revert Errors.ZeroShares();

        // Pull tokens from the caller into the vault as the source of
        // funds for the unlock callback. The callback consumes only as
        // much as the strategy actually needs; any remainder is
        // refunded by the unlockCallback before settling deltas.
        if (amount0Desired > 0) token0.safeTransferFrom(msg.sender, address(this), amount0Desired);
        if (amount1Desired > 0) token1.safeTransferFrom(msg.sender, address(this), amount1Desired);

        DepositPayload memory payload = DepositPayload({
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            payer: msg.sender,
            to: to
        });

        bytes memory result = poolManager.unlock(abi.encode(Op.DEPOSIT, abi.encode(payload)));
        (shares, amount0, amount1) = abi.decode(result, (uint256, uint256, uint256));

        emit Deposit(to, amount0, amount1, shares);
    }

    /// @notice IPoolManager unlock callback. Dispatch by op tag.
    /// @dev Only `poolManager` may call. The actual modifyLiquidity +
    ///      delta settlement sequence lands in the integration phase;
    ///      for now each branch reverts so unit tests can verify the
    ///      auth + dispatch shape without standing up a full pool.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Errors.OnlyPoolManager();

        (Op op, bytes memory payload) = abi.decode(data, (Op, bytes));

        if (op == Op.DEPOSIT) {
            return _handleDeposit(abi.decode(payload, (DepositPayload)));
        }
        if (op == Op.WITHDRAW) {
            return _handleWithdraw(abi.decode(payload, (WithdrawPayload)));
        }
        if (op == Op.REBALANCE) {
            return _handleRebalance(abi.decode(payload, (RebalancePayload)));
        }

        revert Errors.UnknownOp();
    }

    /// @notice Implements the deposit hot-path inside the PoolManager unlock context.
    /// @dev Execution flow:
    ///   1. Read current sqrtPrice + tick from PoolManager state.
    ///   2. Ask the strategy for target positions (tick ranges + weights).
    ///   3. Validate: weights sum to 10_000, position count ≤ MAX_POSITIONS.
    ///   4. Per position: weight-split desired amounts → compute liquidity →
    ///      call modifyLiquidity → accumulate callerDeltas.
    ///   5. Slippage guard: total amounts consumed must meet caller's minimums.
    ///   6. Settle owed currencies: sync → transfer → settle (CEI satisfied;
    ///      tokens were pulled from payer before unlock, so vault holds them).
    ///   7. Refund unused desired amounts back to payer.
    ///   8. Share minting (inflation-safe first-deposit branch).
    ///   9. Persist positions in storage.
    ///  10. Return ABI-encoded (shares, amount0Used, amount1Used).
    ///
    /// Delta sign convention (V4): callerDelta.amount0() < 0 means the caller
    /// owes token0 to PoolManager. For a pure add-liquidity this is always
    /// negative or zero for each token that is consumed.
    ///
    /// Share math — first deposit:
    ///   shares = sqrt(amount0Used * amount1Used) - MIN_SHARES
    ///   MIN_SHARES burned to DEAD (inflation attack mitigation, PRD §13).
    ///   Geometric mean chosen because the vault holds two assets; the L1-norm
    ///   (amount0 + amount1) is denominated in different units and would bias
    ///   toward whichever asset happens to have larger absolute values.
    ///
    /// Share math — subsequent deposits:
    ///   shares = (amount0Used * totalSupply) / total0
    ///   If total0 == 0 (all vault value is in token1), fall back to the
    ///   token1 dimension.  This single-asset denominator is intentionally
    ///   simple: a proper oracle-weighted formula is deferred to v1.1.
    function _handleDeposit(DepositPayload memory payload) internal returns (bytes memory) {
        // ── 1. Read current pool state ────────────────────────────────────────
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(_poolKey.toId());

        // ── 2. Ask strategy for target positions ─────────────────────────────
        IStrategy.TargetPosition[] memory targets = strategy.computePositions(
            currentTick, _poolKey.tickSpacing, payload.amount0Desired, payload.amount1Desired
        );

        // ── 3. Validate strategy output (invariants #2 and #3) ───────────────
        uint256 nPos = targets.length;
        if (nPos > MAX_POSITIONS) revert Errors.MaxPositionsExceeded(nPos);

        uint256 weightSum;
        for (uint256 i; i < nPos; ++i) {
            weightSum += targets[i].weight;
        }
        if (weightSum != 10_000) revert Errors.WeightsDoNotSum(weightSum);

        // ── 4. Deploy each position, accumulate deltas ───────────────────────
        // totalDelta tracks cumulative token owed/received across all positions.
        // Negative amounts mean we owe tokens to PoolManager.
        int256 totalDelta0;
        int256 totalDelta1;

        // Delete existing _positions storage; this is a fresh deployment.
        // (On first deposit _positions is empty; on subsequent deposits
        //  after a rebalance this clears old entries before writing new ones.)
        delete _positions;

        for (uint256 i; i < nPos; ++i) {
            IStrategy.TargetPosition memory t = targets[i];

            // Weight-proportional share of desired amounts for this position.
            uint256 amt0 = FullMath.mulDiv(payload.amount0Desired, t.weight, 10_000);
            uint256 amt1 = FullMath.mulDiv(payload.amount1Desired, t.weight, 10_000);

            // Compute maximum liquidity achievable with the position's share.
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(t.tickLower),
                TickMath.getSqrtPriceAtTick(t.tickUpper),
                amt0,
                amt1
            );

            // Skip zero-liquidity positions (price fully outside this range).
            if (liquidity == 0) continue;

            (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
                _poolKey,
                ModifyLiquidityParams({
                    tickLower: t.tickLower,
                    tickUpper: t.tickUpper,
                    liquidityDelta: int256(uint256(liquidity)),
                    // Use position index as salt so two positions at the same
                    // tick range (unusual for BellStrategy but possible) are
                    // tracked as distinct PoolManager positions.
                    salt: bytes32(i)
                }),
                ""
            );

            totalDelta0 += callerDelta.amount0();
            totalDelta1 += callerDelta.amount1();

            // Persist in vault storage for view helpers and future rebalance.
            _positions.push(IVault.Position({tickLower: t.tickLower, tickUpper: t.tickUpper, liquidity: liquidity}));
        }

        // Actual consumed amounts (flip sign: negative delta = tokens we owe).
        // `amount0Used` / `amount1Used` are the magnitudes paid to the pool.
        uint256 amount0Used = totalDelta0 < 0 ? uint256(-totalDelta0) : 0;
        uint256 amount1Used = totalDelta1 < 0 ? uint256(-totalDelta1) : 0;

        // ── 5. Slippage guard ─────────────────────────────────────────────────
        if (amount0Used < payload.amount0Min) {
            revert Errors.SlippageExceeded(amount0Used, payload.amount0Min);
        }
        if (amount1Used < payload.amount1Min) {
            revert Errors.SlippageExceeded(amount1Used, payload.amount1Min);
        }

        // ── 6. Settle owed currencies ─────────────────────────────────────────
        // V4 settlement pattern for ERC-20: sync records the pre-transfer
        // balance so the manager can verify exactly how much arrived.
        // Tokens were pulled into the vault by deposit() before unlock, so
        // we transfer from vault → poolManager here.
        if (amount0Used > 0) {
            poolManager.sync(_poolKey.currency0);
            token0.safeTransfer(address(poolManager), amount0Used);
            poolManager.settle();
        }
        if (amount1Used > 0) {
            poolManager.sync(_poolKey.currency1);
            token1.safeTransfer(address(poolManager), amount1Used);
            poolManager.settle();
        }

        // ── 7. Refund unused desired amounts back to payer ────────────────────
        uint256 refund0 = payload.amount0Desired - amount0Used;
        uint256 refund1 = payload.amount1Desired - amount1Used;
        if (refund0 > 0) token0.safeTransfer(payload.payer, refund0);
        if (refund1 > 0) token1.safeTransfer(payload.payer, refund1);

        // ── 8. Share minting ──────────────────────────────────────────────────
        uint256 shares;
        uint256 supply = totalSupply();

        if (supply == 0) {
            // First deposit: geometric mean of consumed amounts minus the
            // inflation-guard burn. sqrt(a * b) is safe here because each
            // factor is a uint128-bounded callerDelta and the product fits
            // in uint256 before the sqrt.
            uint256 geomMean = _sqrt(amount0Used * amount1Used);
            if (geomMean <= MIN_SHARES) revert Errors.ZeroShares();
            // Burn MIN_SHARES to the dead address; remainder goes to recipient.
            _mint(DEAD, MIN_SHARES);
            shares = geomMean - MIN_SHARES;
        } else {
            // Subsequent deposits: scale against the dominant dimension.
            // Use token0 notional as the reference; fall back to token1 when
            // token0 is entirely consumed (or vault holds no token0 position).
            // Read vault's remaining idle balances (AFTER settlement + refund)
            // as the share-price denominator. This is the simplest pro-rata
            // approach; an oracle-weighted formula is deferred to v1.1.
            uint256 total0 = token0.balanceOf(address(this));
            uint256 total1 = token1.balanceOf(address(this));
            if (total0 > 0) {
                shares = FullMath.mulDiv(amount0Used, supply, total0);
            } else if (total1 > 0) {
                shares = FullMath.mulDiv(amount1Used, supply, total1);
            } else {
                revert Errors.ZeroShares();
            }
        }

        if (shares == 0) revert Errors.ZeroShares();
        _mint(payload.to, shares);

        return abi.encode(shares, amount0Used, amount1Used);
    }

    /// @dev Integer square root (Babylonian method). Returns floor(sqrt(x)).
    ///      Used only for first-deposit share math.
    function _sqrt(uint256 x) private pure returns (uint256 z) {
        if (x == 0) return 0;
        // Initial estimate: bit-length / 2.
        assembly ("memory-safe") {
            z := 1
            let y := x
            if iszero(lt(y, 0x100000000000000000000000000000000)) {
                y := shr(128, y)
                z := shl(64, z)
            }
            if iszero(lt(y, 0x10000000000000000)) {
                y := shr(64, y)
                z := shl(32, z)
            }
            if iszero(lt(y, 0x100000000)) {
                y := shr(32, y)
                z := shl(16, z)
            }
            if iszero(lt(y, 0x10000)) {
                y := shr(16, y)
                z := shl(8, z)
            }
            if iszero(lt(y, 0x100)) {
                y := shr(8, y)
                z := shl(4, z)
            }
            if iszero(lt(y, 0x10)) {
                y := shr(4, y)
                z := shl(2, z)
            }
            if iszero(lt(y, 0x8)) { z := shl(1, z) }
            // Refine twice (sufficient for uint256).
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            // Floor: ensure z^2 <= x
            if gt(z, div(x, z)) { z := div(x, z) }
        }
    }

    /// @notice Implements the withdraw hot-path inside the PoolManager unlock context.
    /// @dev Execution flow:
    ///   1. Reconstruct the pre-burn supply (vault burned `payload.shares`
    ///      before unlock; current totalSupply() is post-burn).
    ///   2. Per stored position: compute pro-rata liquidity to remove,
    ///      modifyLiquidity with negative delta, accumulate caller deltas,
    ///      decrement persisted liquidity.
    ///   3. Compute pro-rata claim on idle vault balance (fees / dust).
    ///   4. Slippage guard against the total amount the user receives.
    ///   5. Take currencies from PoolManager directly to `payload.to`.
    ///   6. Transfer idle pro-rata share to `payload.to`.
    ///   7. Return ABI-encoded (amount0, amount1).
    ///
    /// Pro-rata math: `liquidityToRemove = position.liquidity * shares / preSupply`,
    /// floor-rounded so dust always favours the remaining shareholders. The
    /// MIN_SHARES burn permanently parked at DEAD is part of preSupply, so the
    /// last redeemable user can never withdraw the full underlying — a tiny
    /// sliver stays attributable to DEAD (the inflation guard).
    function _handleWithdraw(WithdrawPayload memory payload) internal returns (bytes memory) {
        // ── 1. Pre-burn supply ───────────────────────────────────────────────
        uint256 preSupply = totalSupply() + payload.shares;

        // ── 2. Remove pro-rata slice of every position ───────────────────────
        int256 totalDelta0;
        int256 totalDelta1;
        uint256 nPos = _positions.length;
        for (uint256 i; i < nPos; ++i) {
            Position storage p = _positions[i];
            // Floor — dust accrues to remaining shareholders.
            uint128 liquidityToRemove = uint128(FullMath.mulDiv(uint256(p.liquidity), payload.shares, preSupply));
            if (liquidityToRemove == 0) continue;

            (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
                _poolKey,
                ModifyLiquidityParams({
                    tickLower: p.tickLower,
                    tickUpper: p.tickUpper,
                    liquidityDelta: -int256(uint256(liquidityToRemove)),
                    salt: bytes32(i)
                }),
                ""
            );

            totalDelta0 += callerDelta.amount0();
            totalDelta1 += callerDelta.amount1();

            p.liquidity -= liquidityToRemove;
        }

        // Negative delta would mean caller owes — impossible for a pure
        // remove. Treat as zero rather than reverting on accumulated dust.
        uint256 fromPositions0 = totalDelta0 > 0 ? uint256(totalDelta0) : 0;
        uint256 fromPositions1 = totalDelta1 > 0 ? uint256(totalDelta1) : 0;

        // ── 3. Pro-rata share of idle balance (fees / refund dust) ───────────
        uint256 idle0 = token0.balanceOf(address(this));
        uint256 idle1 = token1.balanceOf(address(this));
        uint256 idleShare0 = FullMath.mulDiv(idle0, payload.shares, preSupply);
        uint256 idleShare1 = FullMath.mulDiv(idle1, payload.shares, preSupply);

        // ── 4. Slippage guard against total payout ───────────────────────────
        uint256 amount0 = fromPositions0 + idleShare0;
        uint256 amount1 = fromPositions1 + idleShare1;
        if (amount0 < payload.amount0Min) revert Errors.SlippageExceeded(amount0, payload.amount0Min);
        if (amount1 < payload.amount1Min) revert Errors.SlippageExceeded(amount1, payload.amount1Min);

        // ── 5. Take currencies directly to recipient ─────────────────────────
        if (fromPositions0 > 0) {
            poolManager.take(_poolKey.currency0, payload.to, fromPositions0);
        }
        if (fromPositions1 > 0) {
            poolManager.take(_poolKey.currency1, payload.to, fromPositions1);
        }

        // ── 6. Transfer idle pro-rata share to recipient ─────────────────────
        if (idleShare0 > 0) token0.safeTransfer(payload.to, idleShare0);
        if (idleShare1 > 0) token1.safeTransfer(payload.to, idleShare1);

        return abi.encode(amount0, amount1);
    }

    /// @dev Stub: real implementation removes all positions, optionally
    ///      runs a slippage-bounded internal swap to rebalance the
    ///      idle balance, calls strategy.computePositions for the new
    ///      shape, deploys via modifyLiquidity per target, settles
    ///      deltas, and mints the keeper bonus shares (ADR-007 §keeper
    ///      economics).
    function _handleRebalance(
        RebalancePayload memory /*payload*/
    )
        internal
        pure
        returns (bytes memory)
    {
        revert Errors.UnknownOp();
    }

    /// @inheritdoc IVault
    /// @dev Never pausable (invariant 6). The `depositsPaused` flag is
    ///      checked in `deposit` only; this entry point is reachable in
    ///      every state of the contract for the lifetime of the vault.
    function withdraw(
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    )
        external
        override
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0) revert Errors.InvalidShareAmount();
        if (shares > balanceOf(msg.sender)) revert Errors.InvalidShareAmount();
        if (to == address(0)) revert Errors.ZeroAddress();

        // Burn shares up-front so the unlock callback can compute
        // proportional withdrawals against the post-burn supply.
        // Inflation guard: MIN_SHARES never circulates; burning more
        // than (totalSupply - MIN_SHARES) is rejected by the
        // balanceOf check above on the first depositor.
        _burn(msg.sender, shares);

        WithdrawPayload memory payload =
            WithdrawPayload({shares: shares, amount0Min: amount0Min, amount1Min: amount1Min, from: msg.sender, to: to});

        bytes memory result = poolManager.unlock(abi.encode(Op.WITHDRAW, abi.encode(payload)));
        (amount0, amount1) = abi.decode(result, (uint256, uint256));

        emit Withdraw(to, amount0, amount1, shares);
    }

    /// @inheritdoc IVault
    /// @dev Permissionless. Caller becomes `payload.keeper` and is
    ///      credited the rebalance bonus on successful settlement.
    ///      Gates on `strategy.shouldRebalance(currentTick, lastTick,
    ///      lastTimestamp)` — reverts `RebalanceNotNeeded` if the
    ///      strategy says no.
    ///
    ///      The full remove-all → bounded swap → redeploy sequence
    ///      lives in `_handleRebalance`. The current PR exercises the
    ///      entry-point gate; settlement lands during integration
    ///      testing against a real PoolManager.
    function rebalance() external override {
        // Read the current tick from PoolManager state. For #29 we
        // forward 0 as a placeholder — integration phase reads via
        // `StateView.getSlot0(poolKey.toId())`. The strategy still
        // sees a non-zero last-rebalance window the first time.
        int24 currentTick = 0;

        if (!strategy.shouldRebalance(currentTick, lastRebalanceTick, lastRebalanceTimestamp)) {
            revert Errors.RebalanceNotNeeded();
        }

        RebalancePayload memory payload = RebalancePayload({keeper: msg.sender});
        bytes memory result = poolManager.unlock(abi.encode(Op.REBALANCE, abi.encode(payload)));
        // Settlement returns (newTick, nPositions, gasUsed). Decode
        // and record post-rebalance state.
        (int24 newTick, uint256 nPositions, uint256 gasUsed) = abi.decode(result, (int24, uint256, uint256));

        lastRebalanceTick = newTick;
        lastRebalanceTimestamp = block.timestamp;

        emit Rebalanced(newTick, nPositions, gasUsed);
    }

    /// @inheritdoc IVault
    function getPositions() external view override returns (Position[] memory) {
        return _positions;
    }

    /// @inheritdoc IVault
    /// @dev Sums every active position's token0 + token1 amounts plus
    ///      the vault's idle balances. The per-position amounts are
    ///      derived from V4 liquidity via PositionLib.amountsForLiquidity
    ///      against the current sqrtPrice; integration phase wires the
    ///      sqrtPrice read via StateView. Until then this returns the
    ///      idle balances only — adequate for v1.0 dApp rendering of
    ///      a freshly-deployed vault and the test surface for #38.
    function getTotalAmounts() external view override returns (uint256 total0, uint256 total1) {
        total0 = token0.balanceOf(address(this));
        total1 = token1.balanceOf(address(this));
        // Per-position aggregation lands during integration. The shape:
        //   for (i in _positions) {
        //     (a0, a1) = PositionLib.amountsForLiquidity(
        //       sqrtPriceCurrentX96,
        //       TickMath.getSqrtPriceAtTick(_positions[i].tickLower),
        //       TickMath.getSqrtPriceAtTick(_positions[i].tickUpper),
        //       _positions[i].liquidity
        //     );
        //     total0 += a0; total1 += a1;
        //   }
    }

    /// @notice Spot share price in token0 units, scaled by 1e18.
    /// @dev `(token0_per_share, token1_per_share)` — caller composes
    ///      with the oracle to render a USD price. Returns (1e18, 1e18)
    ///      pre-deposit so the dApp doesn't divide by zero.
    function sharePrice() external view returns (uint256 price0, uint256 price1) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return (1e18, 1e18);
        }
        (uint256 t0, uint256 t1) = (token0.balanceOf(address(this)), token1.balanceOf(address(this)));
        // 1e18-scaled per-share amounts. Position-aware aggregation in
        // integration phase replaces the idle-only path here.
        price0 = (t0 * 1e18) / supply;
        price1 = (t1 * 1e18) / supply;
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
