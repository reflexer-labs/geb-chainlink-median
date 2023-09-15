pragma solidity 0.6.7;

import "ds-test/test.sol";

import { ChainlinkTWAP } from  "../ChainlinkTWAPNoRewards.sol";

abstract contract Hevm {
    function warp(uint256) virtual public;
}

contract ChainlinkAggregator {
    int256 public gwei = 10**9;
    int256 public latestAnswer = 120 * gwei;
    uint256 public latestTimestamp = now;

    function modifyParameters(int256 answer, uint timestamp) external {
        latestTimestamp = timestamp;
        latestAnswer = answer;
    }

    function latestRoundData() external returns (
            uint256 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint256 answeredInRound
    ) {
        return (0, latestAnswer, 0, latestTimestamp, 0);
    }
}

contract ChainlinkTWAPNoRewardsTest is DSTest {
    Hevm hevm;

    ChainlinkAggregator aggregator;
    ChainlinkTWAP chainlinkTwap;

    address alice = address(0x4567);
    address me;

    uint256 startTime                     = 1577836800;
    uint256 windowSize                    = 1 hours;
    uint256 maxWindowSize                 = 4 hours;
    uint256 baseCallerReward              = 15 ether;
    uint256 maxCallerReward               = 20 ether;
    uint256 initTokenAmount               = 100000000 ether;
    uint256 perSecondCallerRewardIncrease = 1000192559420674483977255848; // 100% over one hour
    uint8   granularity                   = 4;
    uint8   multiplier                    = 1;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(startTime);

        aggregator = new ChainlinkAggregator();

        chainlinkTwap = new ChainlinkTWAP(
          address(aggregator),
          windowSize,
          maxWindowSize,
          multiplier,
          granularity
        );

        me = address(this);

        hevm.warp(now + chainlinkTwap.periodSize());
    }

    // --- Math ---
    function multiply(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, 'mul-overflow');
    }

    // --- Utils ---
    uint[] _values;
    uint[] _intervals;

    // will loop through all the prices in the values array and warp between updates
    // the last interval is not warped (so the updates are fresh)
    // returns the TWAP for a given granularity (without accounting for large intervals; overflows are also unnacounted for)
    function simulateUpdates(uint[] memory values, uint[] memory intervals, uint8 granularity) internal returns (uint) {
        require(values.length == intervals.length);
        require(values.length > granularity);

        uint converterResultCumulative;
        uint periodStart;

        for (uint i = 0; i < values.length; i++) {
            aggregator.modifyParameters(int256(values[i]), now);
            chainlinkTwap.updateResult();

            //check if within granularity
            if(i >= values.length - granularity)
                converterResultCumulative += values[i] * intervals[i - 1];

            if(i == values.length - granularity - 1)
                periodStart = now;

            if(i != values.length -1) hevm.warp(now + intervals[i]);
        }

        return converterResultCumulative / (now - periodStart);
    }

    // --- Tests ---
    function test_correct_setup() public {
        assertEq(chainlinkTwap.authorizedAccounts(me), 1);
        assertEq(address(chainlinkTwap.chainlinkAggregator()), address(aggregator));

        assertEq(chainlinkTwap.linkAggregatorTimestamp(), 0);
        assertEq(chainlinkTwap.lastUpdateTime(), 0);
        assertEq(chainlinkTwap.converterResultCumulative(), 0);
        assertEq(chainlinkTwap.windowSize(), windowSize);
        assertEq(chainlinkTwap.maxWindowSize(), maxWindowSize);
        assertEq(chainlinkTwap.updates(), 0);

        assertEq(uint(chainlinkTwap.multiplier()), 1);
        assertEq(uint(chainlinkTwap.granularity()), uint(granularity));

        assertEq(chainlinkTwap.staleThreshold(), 3);
        assertEq(chainlinkTwap.symbol(), "fast-gas");
        assertEq(chainlinkTwap.getObservationListLength(), 0);
    }
    function testFail_setup_null_aggregator() public {
        chainlinkTwap = new ChainlinkTWAP(
          address(0x0),
          windowSize,
          maxWindowSize,
          multiplier,
          granularity
        );
    }
    function testFail_setup_null_granularity() public {
        chainlinkTwap = new ChainlinkTWAP(
          address(aggregator),
          windowSize,
          maxWindowSize,
          multiplier,
          0
        );
    }
    function testFail_setup_null_multiplier() public {
        chainlinkTwap = new ChainlinkTWAP(
          address(aggregator),
          windowSize,
          maxWindowSize,
          0,
          granularity
        );
    }
    function testFail_setup_null_window_size() public {
        chainlinkTwap = new ChainlinkTWAP(
          address(aggregator),
          0,
          maxWindowSize,
          multiplier,
          granularity
        );
    }
    function testFail_setup_window_not_evenly_divisible() public {
        chainlinkTwap = new ChainlinkTWAP(
          address(aggregator),
          windowSize,
          maxWindowSize,
          multiplier,
          27
        );
    }
    function test_change_aggregator() public {
        chainlinkTwap.modifyParameters("aggregator", address(0x123));

        assertTrue(address(chainlinkTwap.chainlinkAggregator()) == address(0x123));
    }
    function test_change_max_window_size() public {
        chainlinkTwap.modifyParameters("maxWindowSize", maxWindowSize + 1);

        assertEq(chainlinkTwap.maxWindowSize(), maxWindowSize + 1);
    }
    function testFail_change_max_window_size_lower_than_window() public {
        chainlinkTwap.modifyParameters("maxWindowSize", windowSize);
    }
    function test_change_stale_threshold() public {
        chainlinkTwap.modifyParameters("staleThreshold", 2);

        assertEq(chainlinkTwap.staleThreshold(), 2);
    }
    function testFail_change_stale_threshold_invalid() public {
        chainlinkTwap.modifyParameters("staleThreshold", 1);
    }
    function testFail_read_before_passing_granularity() public {
        hevm.warp(now + 3599);

        chainlinkTwap.updateResult();

        uint medianPrice = chainlinkTwap.read();
    }
    function test_get_result_before_passing_granularity() public {
        hevm.warp(now + 3599);

        // RAI/WETH
        chainlinkTwap.updateResult();
        (uint256 medianPrice, bool isValid) = chainlinkTwap.getResultWithValidity();
        assertTrue(!isValid);
    }
    function testFail_update_again_immediately() public {
        hevm.warp(now + 3599);
        chainlinkTwap.updateResult();

        hevm.warp(now + 1);
        chainlinkTwap.updateResult();
    }
    function testFail_update_result_aggregator_invalid_value() public {
        aggregator.modifyParameters(0, 0);
        hevm.warp(now + 3599);
        chainlinkTwap.updateResult();
    }
    function test_read_same_price() public {
        for (uint i = 0; i <= granularity * 4; i++) {
            _values.push(uint(120 * aggregator.gwei()));
            _intervals.push(chainlinkTwap.periodSize());
        }

        uint testMedian = simulateUpdates(_values, _intervals, granularity);
        assertEq(testMedian, uint(120 * aggregator.gwei()));
        assertEq(testMedian, chainlinkTwap.read()); // check median result
    }
    function test_read_diff_price() public {
        for (uint i = 0; i <= granularity * 4; i++) {
            _values.push(uint(120 * aggregator.gwei()));
            _intervals.push(chainlinkTwap.periodSize());
        }

        _values.push(uint(130 * aggregator.gwei()));
        _intervals.push(chainlinkTwap.periodSize() * 2);

        uint testMedian = simulateUpdates(_values, _intervals, granularity);
        assertEq(testMedian, chainlinkTwap.read()); // check median result
    }
    function test_read_fuzz(uint[8] memory values, uint[8] memory intervals) public {
        for (uint i = 0; i < 8; i++) {
            // random values from 1 to 1001 gwei
            _values.push(((values[i] % 1000) + 1) * uint(aggregator.gwei()));
            // random values between period size up to two times the size of it
            _intervals.push(chainlinkTwap.periodSize() + (intervals[i] % chainlinkTwap.periodSize()));
        }

        uint testMedian = simulateUpdates(_values, _intervals, granularity);
        assertEq(testMedian, chainlinkTwap.read()); // check median result
    }
    function test_two_hour_twap() public {
        // Create the TWAP
        chainlinkTwap = new ChainlinkTWAP(
          address(aggregator),
          2 hours,
          4 hours,
          multiplier,
          2
        );

        hevm.warp(now + chainlinkTwap.periodSize());

        // Update median
        hevm.warp(now + 10);
        aggregator.modifyParameters(120 * aggregator.gwei(), now);
        chainlinkTwap.updateResult();
        (, bool isValid) = chainlinkTwap.getResultWithValidity();
        assertTrue(!isValid);

        hevm.warp(now + 1 hours);
        aggregator.modifyParameters(120 * aggregator.gwei(), now);
        chainlinkTwap.updateResult();
        (, isValid) = chainlinkTwap.getResultWithValidity();
        assertTrue(!isValid);

        hevm.warp(now + 1 hours);
        aggregator.modifyParameters(120 * aggregator.gwei(), now);
        chainlinkTwap.updateResult();
        (, isValid) = chainlinkTwap.getResultWithValidity();
        assertTrue(isValid);

        // Checks
        (uint256 medianPrice,) = chainlinkTwap.getResultWithValidity();
        assertEq(medianPrice, uint(120 * aggregator.gwei()));

        assertEq(chainlinkTwap.updates(), 3);
        assertEq(chainlinkTwap.timeElapsedSinceFirstObservation(), 1 hours);
    }
    function test_two_hour_twap_massive_update_delay() public {
        // Create the TWAP
        chainlinkTwap = new ChainlinkTWAP(
          address(aggregator),
          2 hours,
          4 hours,
          multiplier,
          2
        );
        hevm.warp(now + chainlinkTwap.periodSize());

        // Update median
        hevm.warp(now + 1 hours);
        aggregator.modifyParameters(120 * aggregator.gwei(), now);
        chainlinkTwap.updateResult();

        hevm.warp(now + 1 hours);
        aggregator.modifyParameters(120 * aggregator.gwei(), now);
        chainlinkTwap.updateResult();

        hevm.warp(now + 3650 days);
        aggregator.modifyParameters(120 * aggregator.gwei(), now);
        chainlinkTwap.updateResult();

        // Checks
        (uint256 medianPrice, bool isValid) = chainlinkTwap.getResultWithValidity();
        assertEq(medianPrice, 120000000000);
        assertTrue(!isValid);

        assertEq(chainlinkTwap.updates(), 3);
        assertEq(chainlinkTwap.timeElapsedSinceFirstObservation(), 3650 days);

        // Another update
        hevm.warp(now + 1 hours);
        aggregator.modifyParameters(120 * aggregator.gwei(), now);
        chainlinkTwap.updateResult();

        // Checks
        (medianPrice, isValid) = chainlinkTwap.getResultWithValidity();
        assertEq(medianPrice, 120000000000);
        assertTrue(isValid);
    }
}
