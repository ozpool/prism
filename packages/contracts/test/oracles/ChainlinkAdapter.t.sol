// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {AggregatorV3, ChainlinkAdapter} from "../../src/oracles/ChainlinkAdapter.sol";
import {Errors} from "../../src/utils/Errors.sol";

contract MockFeed is AggregatorV3 {
    int256 public answer;
    uint256 public updatedAt;
    uint256 public startedAt;
    bool public revertOnRead;

    function setRound(int256 a, uint256 ua) external {
        answer = a;
        updatedAt = ua;
        startedAt = ua;
    }

    function setRevert(bool r) external {
        revertOnRead = r;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        if (revertOnRead) revert("feed down");
        return (1, answer, startedAt, updatedAt, 1);
    }
}

contract ChainlinkAdapterTest is Test {
    MockFeed feed;
    MockFeed sequencer;
    ChainlinkAdapter adapter;

    // For a hypothetical 1:1 feed where answer == sqrtPriceX96, the
    // scale factor is `2^192 / answer^2 * answer = 2^192 / answer`.
    // Easier to test: pick scale so that result is deterministic.
    // For answer=1e8 (1.0 with 8 decimals), priceQ192 should be 2^192,
    // so sqrtPriceX96 = 2^96.
    // priceQ192 = answer * num/den = 1e8 * num/den == 2^192
    // → num/den == 2^192 / 1e8.
    uint256 constant Q192 = 1 << 192;
    uint256 constant SCALE_NUM = Q192;
    uint256 constant SCALE_DEN = 1e8;

    uint256 constant STALENESS = 3600;
    uint256 constant GRACE = 3600;

    function setUp() public {
        feed = new MockFeed();
        sequencer = new MockFeed();
        adapter = new ChainlinkAdapter(
            AggregatorV3(address(feed)), AggregatorV3(address(sequencer)), STALENESS, GRACE, SCALE_NUM, SCALE_DEN
        );
    }

    // -------------------------------------------------------------------------
    // Constructor reverts
    // -------------------------------------------------------------------------

    function test_constructor_revertsOnZeroFeed() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ChainlinkAdapter(AggregatorV3(address(0)), AggregatorV3(address(0)), STALENESS, GRACE, SCALE_NUM, SCALE_DEN);
    }

    function test_constructor_revertsOnZeroScale() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ChainlinkAdapter(AggregatorV3(address(feed)), AggregatorV3(address(0)), STALENESS, GRACE, 0, SCALE_DEN);

        vm.expectRevert(Errors.ZeroAddress.selector);
        new ChainlinkAdapter(AggregatorV3(address(feed)), AggregatorV3(address(0)), STALENESS, GRACE, SCALE_NUM, 0);
    }

    function test_constructor_acceptsZeroSequencer() public {
        ChainlinkAdapter a = new ChainlinkAdapter(
            AggregatorV3(address(feed)), AggregatorV3(address(0)), STALENESS, GRACE, SCALE_NUM, SCALE_DEN
        );
        assertEq(address(a.sequencer()), address(0));
    }

    // -------------------------------------------------------------------------
    // Sequencer gating
    // -------------------------------------------------------------------------

    function test_read_failsWhenSequencerDown() public {
        // sequencer answer != 0 means down.
        sequencer.setRound(1, block.timestamp);
        feed.setRound(1e8, block.timestamp);

        (uint160 sp, bool ok) = adapter.read();
        assertEq(sp, 0);
        assertFalse(ok);
    }

    function test_read_failsDuringSequencerGrace() public {
        // Sequencer just came back up — startedAt = now.
        sequencer.setRound(0, block.timestamp);
        feed.setRound(1e8, block.timestamp);

        (uint160 sp, bool ok) = adapter.read();
        assertEq(sp, 0);
        assertFalse(ok);

        // After grace, recovery succeeds.
        vm.warp(block.timestamp + GRACE);
        (sp, ok) = adapter.read();
        assertTrue(ok);
        assertGt(sp, 0);
    }

    function test_read_failsOnSequencerRevert() public {
        sequencer.setRevert(true);
        feed.setRound(1e8, block.timestamp);

        (, bool ok) = adapter.read();
        assertFalse(ok);
    }

    // -------------------------------------------------------------------------
    // Staleness
    // -------------------------------------------------------------------------

    function test_read_failsWhenStale() public {
        // Sequencer healthy + grace elapsed.
        sequencer.setRound(0, 1);
        vm.warp(GRACE + 1);

        // Feed updated long ago.
        feed.setRound(1e8, 1);
        vm.warp(1 + STALENESS + 100);

        (, bool ok) = adapter.read();
        assertFalse(ok);
    }

    function test_read_failsOnNegativeAnswer() public {
        sequencer.setRound(0, 1);
        vm.warp(GRACE + 1);
        feed.setRound(-1, block.timestamp);

        (, bool ok) = adapter.read();
        assertFalse(ok);
    }

    function test_read_failsOnZeroAnswer() public {
        sequencer.setRound(0, 1);
        vm.warp(GRACE + 1);
        feed.setRound(0, block.timestamp);

        (, bool ok) = adapter.read();
        assertFalse(ok);
    }

    function test_read_failsOnFeedRevert() public {
        sequencer.setRound(0, 1);
        vm.warp(GRACE + 1);
        feed.setRevert(true);

        (, bool ok) = adapter.read();
        assertFalse(ok);
    }

    // -------------------------------------------------------------------------
    // Happy path + conversion
    // -------------------------------------------------------------------------

    function test_read_happyPath_unitPrice() public {
        sequencer.setRound(0, 1);
        vm.warp(GRACE + 1);
        feed.setRound(1e8, block.timestamp); // 1.00 with 8 decimals

        (uint160 sp, bool ok) = adapter.read();
        assertTrue(ok);
        // Expected: sqrtPriceX96 = sqrt(2^192) = 2^96.
        assertEq(uint256(sp), 1 << 96);
    }

    function test_read_happyPath_higherPrice() public {
        sequencer.setRound(0, 1);
        vm.warp(GRACE + 1);
        feed.setRound(4e8, block.timestamp); // 4.00 with 8 decimals

        (uint160 sp, bool ok) = adapter.read();
        assertTrue(ok);
        // Expected: priceQ192 = 4 * 2^192, sqrt = 2 * 2^96 = 2^97.
        assertEq(uint256(sp), 1 << 97);
    }

    function test_read_skipsSequencerWhenAddressZero() public {
        ChainlinkAdapter noSeq = new ChainlinkAdapter(
            AggregatorV3(address(feed)), AggregatorV3(address(0)), STALENESS, GRACE, SCALE_NUM, SCALE_DEN
        );

        feed.setRound(1e8, block.timestamp);
        (uint160 sp, bool ok) = noSeq.read();
        assertTrue(ok);
        assertEq(uint256(sp), 1 << 96);
    }

    function test_read_neverReverts_fuzz(int256 a, uint64 ua, uint256 warpTo) public {
        sequencer.setRound(0, 1);
        // Bound the warp so block.timestamp arithmetic stays sane.
        warpTo = bound(warpTo, GRACE + 2, type(uint64).max);
        vm.warp(warpTo);
        feed.setRound(a, ua);

        // Adapter must never revert regardless of inputs.
        adapter.read();
    }
}
