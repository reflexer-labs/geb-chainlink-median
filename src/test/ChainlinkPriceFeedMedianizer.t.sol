pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-token/token.sol";

import "./geb/MockTreasury.sol";

import "../ChainlinkPriceFeedMedianizer.sol";

import "geb-treasury-reimbursement/relayer/IncreasingRewardRelayer.sol";

abstract contract Hevm {
    function warp(uint256) virtual public;
}

contract ChainlinkAggregator {
    int256 public latestAnswer;
    uint256 public latestTimestamp;

    function modifyParameters(bytes32 parameter, uint data) external {
        latestTimestamp = data;
    }
    function modifyParameters(bytes32 parameter, int data) external {
        latestAnswer = data;
    }
}

contract ChainlinkPriceFeedMedianizerTest is DSTest {
    Hevm hevm;

    ChainlinkAggregator aggregator;
    ChainlinkPriceFeedMedianizer chainlinkMedianizer;
    IncreasingRewardRelayer relayer;
    MockTreasury treasury;
    DSToken rai;

    uint256 startTime                     = 1577836800;
    uint256 periodSize                    = 10;
    uint256 callerReward                  = 15 ether;
    uint256 maxCallerReward               = 20 ether;
    uint256 initTokenAmount               = 100000000 ether;
    uint256 perSecondCallerRewardIncrease = 1.01E27;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(startTime);

        aggregator = new ChainlinkAggregator();

        // Create token
        rai = new DSToken("RAI", "RAI");
        rai.mint(initTokenAmount);

        // Create treasury
        treasury = new MockTreasury(address(rai));
        rai.transfer(address(treasury), initTokenAmount);

        // Create median
        chainlinkMedianizer = new ChainlinkPriceFeedMedianizer(
          address(aggregator),
          periodSize
        );

        // Create the reward relayer
        relayer = new IncreasingRewardRelayer(
            address(chainlinkMedianizer),
            address(treasury),
            callerReward,
            maxCallerReward,
            perSecondCallerRewardIncrease,
            periodSize
        );
        chainlinkMedianizer.modifyParameters("rewardRelayer", address(relayer));

        // Setup treasury allowance
        treasury.setTotalAllowance(address(relayer), uint(-1));
        treasury.setPerBlockAllowance(address(relayer), uint(-1));
    }

    function test_change_aggregator_address() public {
        ChainlinkAggregator newAggregator = new ChainlinkAggregator();
        chainlinkMedianizer.modifyParameters("aggregator", address(newAggregator));
        assertEq(address(chainlinkMedianizer.chainlinkAggregator()), address(newAggregator));
    }
    function test_change_uint_params() public {
        chainlinkMedianizer.modifyParameters("periodSize", 5);
        assertEq(chainlinkMedianizer.periodSize(), 5);
    }
    function testFail_negative_price_feed() public {
        aggregator.modifyParameters("latestTimestamp", uint(now));
        aggregator.modifyParameters("latestAnswer", int(-1.1 * 10 ** 8));

        chainlinkMedianizer.updateResult(address(this));
    }
    function testFail_null_timestamp() public {
        aggregator.modifyParameters("latestAnswer", int(1.1 * 10 ** 8));
        chainlinkMedianizer.updateResult(address(this));
    }
    function testFail_new_timestamp_smaller_than_last() public {
        aggregator.modifyParameters("latestTimestamp", uint(now));
        aggregator.modifyParameters("latestAnswer", int(1.1 * 10 ** 8));

        chainlinkMedianizer.updateResult(address(this));

        aggregator.modifyParameters("latestTimestamp", uint(now - 1));
        chainlinkMedianizer.updateResult(address(this));
    }
    function test_update_result_and_read() public {
        aggregator.modifyParameters("latestTimestamp", uint(now));
        aggregator.modifyParameters("latestAnswer", int(1.1 * 10 ** 8));

        chainlinkMedianizer.updateResult(address(this));
        assertEq(chainlinkMedianizer.read(), 1.1 ether);
        assertEq(chainlinkMedianizer.lastUpdateTime(), now);

        hevm.warp(now + chainlinkMedianizer.periodSize());
        aggregator.modifyParameters("timestamp", uint(now));
        chainlinkMedianizer.updateResult(address(this));
        assertEq(chainlinkMedianizer.lastUpdateTime(), now);
    }
    function test_reward_caller_other_first_and_second_update() public {
        aggregator.modifyParameters("latestTimestamp", uint(now));
        aggregator.modifyParameters("latestAnswer", int(1.1 * 10 ** 8));

        // First update
        chainlinkMedianizer.updateResult(address(0x123));
        assertEq(rai.balanceOf(address(0x123)), callerReward);

        // Second update
        hevm.warp(now + chainlinkMedianizer.periodSize());
        aggregator.modifyParameters("latestTimestamp", uint(now));
        chainlinkMedianizer.updateResult(address(0x123));
        assertEq(rai.balanceOf(address(0x123)), callerReward * 2);
    }
    function test_reward_after_waiting_more_than_maxRewardIncreaseDelay() public {
        relayer.modifyParameters("maxRewardIncreaseDelay", periodSize * 4);

        aggregator.modifyParameters("latestTimestamp", uint(now));
        aggregator.modifyParameters("latestAnswer", int(1.1 * 10 ** 8));

        // First update
        chainlinkMedianizer.updateResult(address(0x123));
        assertEq(rai.balanceOf(address(0x123)), callerReward);

        // Second update
        hevm.warp(now + chainlinkMedianizer.periodSize());
        aggregator.modifyParameters("latestTimestamp", uint(now));
        chainlinkMedianizer.updateResult(address(0x123));
        assertEq(rai.balanceOf(address(0x123)), callerReward * 2);

        // Third update
        hevm.warp(now + relayer.maxRewardIncreaseDelay() + 1);
        aggregator.modifyParameters("latestTimestamp", uint(now));
        chainlinkMedianizer.updateResult(address(0x123));
        assertEq(rai.balanceOf(address(0x123)), callerReward * 2 + maxCallerReward);
    }
    function test_reward_caller_null_param_first_update() public {
        aggregator.modifyParameters("latestTimestamp", uint(now));
        aggregator.modifyParameters("latestAnswer", int(1.1 * 10 ** 8));

        // First
        chainlinkMedianizer.updateResult(address(0));
        assertEq(rai.balanceOf(address(this)), callerReward);

        // Second
        hevm.warp(now + chainlinkMedianizer.periodSize());
        aggregator.modifyParameters("latestTimestamp", uint(now));
        chainlinkMedianizer.updateResult(address(0));
        assertEq(rai.balanceOf(address(this)), callerReward * 2);
    }
    function test_increased_reward_above_max_second_update() public {
        aggregator.modifyParameters("latestTimestamp", uint(now));
        aggregator.modifyParameters("latestAnswer", int(1.1 * 10 ** 8));

        // First
        chainlinkMedianizer.updateResult(address(0));
        assertEq(rai.balanceOf(address(this)), callerReward);

        // Second
        hevm.warp(now + chainlinkMedianizer.periodSize());
        aggregator.modifyParameters("latestTimestamp", uint(now));
        chainlinkMedianizer.updateResult(address(0));
        assertEq(rai.balanceOf(address(this)), callerReward * 2);

        // Third
        hevm.warp(now + 1000);
        aggregator.modifyParameters("latestTimestamp", uint(now));
        chainlinkMedianizer.updateResult(address(0));
        assertEq(rai.balanceOf(address(this)), maxCallerReward + callerReward * 2);
    }
    function test_reward_other_multiple_times() public {
        aggregator.modifyParameters("latestTimestamp", uint(now));
        aggregator.modifyParameters("latestAnswer", int(1.1 * 10 ** 8));

        // First
        chainlinkMedianizer.updateResult(address(0x123));
        assertEq(rai.balanceOf(address(0x123)), callerReward);

        // Second
        hevm.warp(now + chainlinkMedianizer.periodSize());
        aggregator.modifyParameters("latestTimestamp", uint(now));
        chainlinkMedianizer.updateResult(address(0x123));
        assertEq(rai.balanceOf(address(0x123)), callerReward * 2);

        for (uint i = 0; i < 10; i++) {
          hevm.warp(now + periodSize);
          aggregator.modifyParameters("latestTimestamp", uint(now));
          chainlinkMedianizer.updateResult(address(0x123));
        }

        assertEq(rai.balanceOf(address(0x123)), callerReward * 12);
    }
    function testFail_read_when_stale() public {
        aggregator.modifyParameters("latestTimestamp", uint(now));
        aggregator.modifyParameters("latestAnswer", int(1.1 * 10 ** 8));

        chainlinkMedianizer.updateResult(address(this));
        assertEq(chainlinkMedianizer.read(), 1.1 ether);

        hevm.warp(now + periodSize * chainlinkMedianizer.staleThreshold() + 1);
        assertEq(chainlinkMedianizer.read(), 1.1 ether);
    }
    function test_update_base_reward_zero() public {
        aggregator.modifyParameters("latestTimestamp", uint(now));
        aggregator.modifyParameters("latestAnswer", int(1.1 * 10 ** 8));

        relayer.modifyParameters("baseUpdateCallerReward", 0);
        chainlinkMedianizer.updateResult(address(0x123));
        assertEq(rai.balanceOf(address(this)), 0);
    }
    function test_get_result_with_validity_when_stale() public {
        aggregator.modifyParameters("latestTimestamp", uint(now));
        aggregator.modifyParameters("latestAnswer", int(1.1 * 10 ** 8));

        chainlinkMedianizer.updateResult(address(this));
        (uint256 price, bool valid) = chainlinkMedianizer.getResultWithValidity();
        assertEq(price, 1.1 ether);
        assertTrue(valid);

        hevm.warp(now + periodSize * chainlinkMedianizer.staleThreshold() + 1);
        (price, valid) = chainlinkMedianizer.getResultWithValidity();
        assertEq(price, 1.1 ether);
        assertTrue(!valid);
    }
}
