pragma solidity 0.6.7;

import "ds-test/test.sol";

import {ChainlinkRelayer} from "../ChainlinkRelayer.sol";

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

contract ChainlinkRelayerTest is DSTest {
    Hevm hevm;

    ChainlinkAggregator aggregator;
    ChainlinkRelayer relayer;

    uint256 startTime      = 1577836800;
    uint256 staleThreshold = 6 hours;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(startTime);

        aggregator = new ChainlinkAggregator();
        relayer    = new ChainlinkRelayer(address(aggregator), staleThreshold);
    }

    function test_change_aggregator_address() public {
        ChainlinkAggregator newAggregator = new ChainlinkAggregator();
        relayer.modifyParameters("aggregator", address(newAggregator));
        assertEq(address(relayer.chainlinkAggregator()), address(newAggregator));
    }
    function test_change_uint_params() public {
        relayer.modifyParameters("staleThreshold", staleThreshold / 2);
        assertEq(relayer.staleThreshold(), staleThreshold / 2);
    }
    function testFail_read_null_price() public {
        aggregator.modifyParameters("latestAnswer", int(0));
        aggregator.modifyParameters("latestTimestamp", uint(now));

        relayer.read();
    }
    function testFail_read_stale_price() public {
        aggregator.modifyParameters("latestAnswer", int(5));
        aggregator.modifyParameters("latestTimestamp", uint(now - staleThreshold - 1));

        relayer.read();
    }
    function test_read() public {
        aggregator.modifyParameters("latestAnswer", int(5));
        aggregator.modifyParameters("latestTimestamp", uint(now - staleThreshold + 1));

        relayer.read();
    }
    function test_getResultWithValidity_null_price() public {
        aggregator.modifyParameters("latestAnswer", int(0));
        aggregator.modifyParameters("latestTimestamp", uint(now));

        (uint median, bool validity) = relayer.getResultWithValidity();
        assertEq(median, 0);
        assertTrue(!validity);
    }
    function test_getResultWithValidity_stale() public {
        aggregator.modifyParameters("latestAnswer", int(5));
        aggregator.modifyParameters("latestTimestamp", uint(now - staleThreshold - 1));

        (uint median, bool validity) = relayer.getResultWithValidity();
        assertEq(median, 5 * 10 ** uint(relayer.multiplier()));
        assertTrue(!validity);
    }
    function test_getResultWithValidity() public {
        aggregator.modifyParameters("latestAnswer", int(5));
        aggregator.modifyParameters("latestTimestamp", uint(now - staleThreshold + 1));

        (uint median, bool validity) = relayer.getResultWithValidity();
        assertEq(median, 5 * 10 ** uint(relayer.multiplier()));
        assertTrue(validity);
    }
    function test_updateResult() public {
        relayer.updateResult(address(0x1));
    }
}
