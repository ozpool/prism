// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";

import {IChainlinkAdapter} from "../interfaces/IChainlinkAdapter.sol";
import {Errors} from "../utils/Errors.sol";

// Subset of Chainlink's AggregatorV3Interface — only the calls this
// adapter makes. Inlined here so PRISM's contract package does not pull
// in chainlink/contracts as a submodule.
interface AggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title PRISM Chainlink adapter
/// @notice Fail-soft oracle reader for ProtocolHook. Combines a price
///         feed, an optional L2 sequencer uptime feed, a staleness gate,
///         and a sqrtPriceX96 conversion in one read() call.
///
///         Per ADR-003 the adapter NEVER reverts on the swap path. All
///         failure modes degrade to `(0, false)`. The hook then skips
///         MEV observation for that swap; volatility-fee updates in
///         beforeSwap are unaffected.
///
/// @dev   Construction parameters are immutable. To update any of them
///        the operator deploys a new adapter and rotates `oracle()` on
///        the affected vaults — see ADR-006 (immutable core).
///
///        sqrtPriceX96 conversion uses `FullMath.mulDiv` (512-bit
///        intermediate) so the operator can supply a Q-format scaling
///        factor as `priceScaleNum / priceScaleDen` without needing to
///        worry about intermediate overflow. The factor encodes pool
///        decimals + feed decimals; computing it off-chain at deploy
///        time keeps the swap path branch-free.
contract ChainlinkAdapter is IChainlinkAdapter {
    /// @notice Default staleness window — 1 hour.
    /// @dev See ADR-003.
    uint256 public constant DEFAULT_STALENESS = 3600;

    /// @notice Default sequencer grace period — 1 hour after recovery.
    uint256 public constant DEFAULT_GRACE_PERIOD = 3600;

    /// @notice Primary price feed (e.g. ETH/USD on Base).
    AggregatorV3 public immutable feed;

    /// @notice L2 sequencer uptime feed. `address(0)` for L1 deployments.
    AggregatorV3 public immutable sequencer;

    /// @notice Maximum age of `feed.updatedAt` before the round is rejected.
    uint256 public immutable staleness;

    /// @notice After sequencer recovery the adapter still reports
    ///         unhealthy for `gracePeriod` seconds. Lets dependent state
    ///         (mempool, off-chain bots) settle before MEV signalling resumes.
    uint256 public immutable gracePeriod;

    /// @notice Numerator of the Q192 sqrtPriceX96 scaling factor.
    /// @dev Off-chain helper computes: `priceScaleNum / priceScaleDen ==
    ///      2^192 * 10^(token0Decimals - token1Decimals - feedDecimals)`,
    ///      bounded so the multiplication fits the FullMath domain.
    uint256 public immutable priceScaleNum;

    /// @notice Denominator of the Q192 sqrtPriceX96 scaling factor.
    uint256 public immutable priceScaleDen;

    /// @notice Maximum signed answer the adapter will accept before
    ///         reporting unhealthy. Computed at construction so the
    ///         hot-path can compare in O(1) without doing the
    ///         overflow check via FullMath each call.
    /// @dev    Equal to `type(uint256).max * priceScaleDen / priceScaleNum`,
    ///         capped at `type(int256).max` since answer is int256.
    uint256 public immutable maxAnswer;

    constructor(
        AggregatorV3 feed_,
        AggregatorV3 sequencer_,
        uint256 staleness_,
        uint256 gracePeriod_,
        uint256 priceScaleNum_,
        uint256 priceScaleDen_
    ) {
        if (address(feed_) == address(0)) revert Errors.ZeroAddress();
        if (priceScaleDen_ == 0) revert Errors.ZeroAddress();
        if (priceScaleNum_ == 0) revert Errors.ZeroAddress();

        feed = feed_;
        sequencer = sequencer_;
        staleness = staleness_;
        gracePeriod = gracePeriod_;
        priceScaleNum = priceScaleNum_;
        priceScaleDen = priceScaleDen_;

        uint256 m = FullMath.mulDiv(type(uint256).max, priceScaleDen_, priceScaleNum_);
        maxAnswer = m > uint256(type(int256).max) ? uint256(type(int256).max) : m;
    }

    /// @inheritdoc IChainlinkAdapter
    function read() external view override returns (uint160 sqrtPriceX96, bool healthy) {
        // 1. L2 sequencer gate.
        //    Chainlink convention: answer == 0 means up; nonzero means down.
        if (address(sequencer) != address(0)) {
            try sequencer.latestRoundData() returns (uint80, int256 seqAnswer, uint256 startedAt, uint256, uint80) {
                if (seqAnswer != 0) return (0, false);
                // After recovery, gracePeriod must elapse before re-trusting.
                if (block.timestamp - startedAt < gracePeriod) return (0, false);
            } catch {
                return (0, false);
            }
        }

        // 2. Primary feed read.
        int256 answer;
        uint256 updatedAt;
        try feed.latestRoundData() returns (uint80, int256 a, uint256, uint256 ua, uint80) {
            answer = a;
            updatedAt = ua;
        } catch {
            return (0, false);
        }

        if (answer <= 0) return (0, false);
        if (updatedAt == 0) return (0, false);
        if (block.timestamp > updatedAt && block.timestamp - updatedAt > staleness) {
            return (0, false);
        }
        // Reject implausible feed values that would overflow the
        // Q192 conversion. maxAnswer is precomputed at construction.
        if (uint256(answer) > maxAnswer) return (0, false);

        // 3. Convert to sqrtPriceX96 = sqrt(answer * priceScaleNum / priceScaleDen).
        //    `priceScaleNum` already encodes `2^192` so the result is the
        //    Q192 spot-price; sqrt then yields the Q96 sqrt-price.
        uint256 spotQ192 = FullMath.mulDiv(uint256(answer), priceScaleNum, priceScaleDen);

        uint256 sqrtPrice = _sqrt(spotQ192);
        if (sqrtPrice > type(uint160).max) return (0, false);

        return (uint160(sqrtPrice), true);
    }

    /// @dev Babylonian method. Branchless after the seed; ~70 gas.
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;

        // Initial seed: most significant bit / 2.
        uint256 z = (x + 1) >> 1;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) >> 1;
        }
        return y;
    }
}
