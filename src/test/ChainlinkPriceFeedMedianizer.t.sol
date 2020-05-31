pragma solidity ^0.5.15;

import "ds-test/test.sol";

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

    function setUp() public {
        aggregator = new ChainlinkAggregator();
        chainlinkMedianizer = new ChainlinkPriceFeedMedianizer(address(aggregator));
    }

    function test_change_aggregator_address() public {
        ChainlinkAggregator newAggregator = new ChainlinkAggregator();
        chainlinkMedianizer.modifyParameters("aggregator", address(newAggregator));
        assertEq(address(chainlinkMedianizer.chainlinkAggregator()), address(newAggregator));
    }
    function testFail_negative_price_feed() public {
        aggregator.modifyParameters("latestTimestamp", uint(now));
        aggregator.modifyParameters("latestAnswer", int(-1.1 ether));

        chainlinkMedianizer.updateResult();
    }
    function testFail_null_timestamp() public {
        aggregator.modifyParameters("latestAnswer", int(1.1 ether));
        chainlinkMedianizer.updateResult();
    }
    function testFail_new_timestamp_smaller_than_last() public {
        aggregator.modifyParameters("latestTimestamp", uint(now));
        aggregator.modifyParameters("latestAnswer", int(1.1 ether));

        chainlinkMedianizer.updateResult();

        aggregator.modifyParameters("latestTimestamp", uint(now - 1));
        chainlinkMedianizer.updateResult();
    }
    function test_update_result_and_read() public {
        aggregator.modifyParameters("latestTimestamp", uint(now));
        aggregator.modifyParameters("latestAnswer", int(1.1 ether));

        chainlinkMedianizer.updateResult();
        assertEq(chainlinkMedianizer.read(), 1.1 ether);
        assertEq(chainlinkMedianizer.lastUpdateTime(), now);

        chainlinkMedianizer.updateResult();
        assertEq(chainlinkMedianizer.lastUpdateTime(), now);
    }
}
