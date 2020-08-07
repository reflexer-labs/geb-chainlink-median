pragma solidity ^0.6.7;

import "ds-test/test.sol";
import "ds-token/token.sol";

import "./geb/MockTreasury.sol";

import "../ChainlinkPriceFeedMedianizer.sol";

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
    ChainlinkAggregator aggregator;
    ChainlinkPriceFeedMedianizer chainlinkMedianizer;
    MockTreasury treasury;
    DSToken rai;

    uint256 callerReward    = 15 ether;
    uint256 initTokenAmount = 100000000 ether;

    function setUp() public {
        aggregator = new ChainlinkAggregator();

        // Create token
        rai = new DSToken("RAI");
        rai.mint(initTokenAmount);

        // Create treasury
        treasury = new MockTreasury(address(rai));
        rai.transfer(address(treasury), initTokenAmount);

        chainlinkMedianizer = new ChainlinkPriceFeedMedianizer(address(aggregator), address(treasury), callerReward);
    }

    function test_change_aggregator_address() public {
        ChainlinkAggregator newAggregator = new ChainlinkAggregator();
        chainlinkMedianizer.modifyParameters("aggregator", address(newAggregator));
        assertEq(address(chainlinkMedianizer.chainlinkAggregator()), address(newAggregator));
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

        chainlinkMedianizer.updateResult(address(this));
        assertEq(chainlinkMedianizer.lastUpdateTime(), now);
    }
    function test_reward_caller_other() public {
        aggregator.modifyParameters("latestTimestamp", uint(now));
        aggregator.modifyParameters("latestAnswer", int(1.1 * 10 ** 8));

        chainlinkMedianizer.updateResult(address(0x123));

        assertEq(rai.balanceOf(address(0x123)), callerReward);
    }
    function test_reward_caller_null_param() public {
        aggregator.modifyParameters("latestTimestamp", uint(now));
        aggregator.modifyParameters("latestAnswer", int(1.1 * 10 ** 8));

        chainlinkMedianizer.updateResult(address(0));

        assertEq(rai.balanceOf(address(this)), callerReward);
    }
}
