pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-token/token.sol";

import "./geb/MockTreasury.sol";

import { ChainlinkTWAP } from  "../ChainlinkTWAP.sol";

import "geb-treasury-reimbursement/relayer/IncreasingRewardRelayer.sol";

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
}

contract ChainlinkTWAPTest is DSTest {
    Hevm hevm;

    ChainlinkAggregator aggregator;
    ChainlinkTWAP chainlinkTwap;
    IncreasingRewardRelayer relayer;
    MockTreasury treasury;
    DSToken rai;

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

        // Create token
        rai = new DSToken("RAI", "RAI");
        rai.mint(initTokenAmount);

        // Create treasury
        treasury = new MockTreasury(address(rai));
        rai.transfer(address(treasury), initTokenAmount);

        chainlinkTwap = new ChainlinkTWAP(
          address(aggregator),
          windowSize,
          maxWindowSize,
          multiplier,
          granularity
        );

        // Create the reward relayer
        relayer = new IncreasingRewardRelayer(
            address(chainlinkTwap),
            address(treasury),
            baseCallerReward,
            maxCallerReward,
            perSecondCallerRewardIncrease,
            15 minutes
        );
        chainlinkTwap.modifyParameters("rewardRelayer", address(relayer));

        // Setup treasury allowance
        treasury.setTotalAllowance(address(relayer), uint(-1));
        treasury.setPerBlockAllowance(address(relayer), uint(-1));

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
            chainlinkTwap.updateResult(alice);

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
        assertEq(chainlinkTwap.lastUpdateTime(), now - chainlinkTwap.periodSize());
        assertEq(chainlinkTwap.converterResultCumulative(), 0);
        assertEq(chainlinkTwap.windowSize(), windowSize);
        assertEq(chainlinkTwap.maxWindowSize(), maxWindowSize);
        assertEq(chainlinkTwap.updates(), 0);

        assertEq(uint(chainlinkTwap.multiplier()), 1);
        assertEq(uint(chainlinkTwap.granularity()), uint(granularity));

        assertEq(chainlinkTwap.staleThreshold(), 3);
        assertEq(chainlinkTwap.symbol(), "fast-gas");
        assertEq(chainlinkTwap.getObservationListLength(), 0);

        assertEq(address(chainlinkTwap.rewardRelayer()), address(relayer));
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

        chainlinkTwap.updateResult(alice);

        uint medianPrice = chainlinkTwap.read();
    }
    function test_get_result_before_passing_granularity() public {
        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        // RAI/WETH
        chainlinkTwap.updateResult(alice);
        (uint256 medianPrice, bool isValid) = chainlinkTwap.getResultWithValidity();
        assertTrue(!isValid);
    }
    function test_update_treasury_throws() public {
        MockRevertableTreasury revertTreasury = new MockRevertableTreasury();

        // Set treasury allowance
        revertTreasury.setTotalAllowance(address(relayer), uint(-1));
        revertTreasury.setPerBlockAllowance(address(relayer), uint(-1));

        // Change the treasury in the relayer
        relayer.modifyParameters("treasury", address(revertTreasury));

        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        chainlinkTwap.updateResult(alice);
        assertEq(rai.balanceOf(alice), 0);
    }
    function test_update_treasury_reward_treasury() public {
        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        uint treasuryBalance = rai.balanceOf(address(treasury));

        chainlinkTwap.updateResult(address(treasury));

        assertEq(rai.balanceOf(address(treasury)), treasuryBalance);
        assertEq(rai.balanceOf(alice), 0);
    }
    function testFail_update_again_immediately() public {
        hevm.warp(now + 3599);
        chainlinkTwap.updateResult(address(this));

        hevm.warp(now + 1);
        chainlinkTwap.updateResult(address(this));
    }
    function testFail_update_result_aggregator_invalid_value() public {
        aggregator.modifyParameters(0, 0);
        hevm.warp(now + 3599);
        chainlinkTwap.updateResult(address(this));
    }
    function test_update_result() public {
        hevm.warp(now + 3599);

        chainlinkTwap.updateResult(address(this));
        (uint timestamp, uint timeAdjustedResult) =
          chainlinkTwap.chainlinkObservations(0);
        (uint256 medianPrice, bool isValid) = chainlinkTwap.getResultWithValidity();
        uint256 converterResultCumulative = chainlinkTwap.converterResultCumulative();

        assertEq(uint256(chainlinkTwap.earliestObservationIndex()), 0);
        assertEq(converterResultCumulative, 120 * 10**9 * (3599 + chainlinkTwap.periodSize()));
        assertEq(medianPrice, 120 * 10**9);
        assertTrue(!isValid);
        assertEq(timestamp, now);
        assertEq(timeAdjustedResult, 120 * 10**9 * (3599 + chainlinkTwap.periodSize()));
    }
    function test_wait_more_than_maxUpdateCallerReward_since_last_update() public {
        relayer.modifyParameters("maxRewardIncreaseDelay", 6 hours);

        uint maxRewardDelay = 100;
        chainlinkTwap.updateResult(alice);
        assertEq(rai.balanceOf(alice), baseCallerReward);

        hevm.warp(now + chainlinkTwap.periodSize());
        aggregator.modifyParameters(130 * 10**9, now);
        chainlinkTwap.updateResult(alice);
        assertEq(rai.balanceOf(alice), baseCallerReward * 2);

        hevm.warp(now + chainlinkTwap.periodSize() + relayer.maxRewardIncreaseDelay() + 30);
        aggregator.modifyParameters(130 * 10**9, now);
        chainlinkTwap.updateResult(alice);
        assertEq(rai.balanceOf(alice), baseCallerReward * 2 + maxCallerReward);

        hevm.warp(now + chainlinkTwap.periodSize() + relayer.maxRewardIncreaseDelay() + 30);
        aggregator.modifyParameters(130 * 10**9, now);
        chainlinkTwap.updateResult(address(0x1234));
        assertEq(rai.balanceOf(address(0x1234)), maxCallerReward);

        hevm.warp(now + chainlinkTwap.periodSize() + relayer.maxRewardIncreaseDelay() + 300 weeks);
        aggregator.modifyParameters(130 * 10**9, now);
        chainlinkTwap.updateResult(address(0x1234));
        assertEq(rai.balanceOf(address(0x1234)), maxCallerReward * 2);
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
        relayer.modifyParameters("maxRewardIncreaseDelay", 5 * 52 weeks);

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
        // Create token
        rai = new DSToken("RAI", "RAI");
        rai.mint(initTokenAmount);

        // Create treasury
        treasury = new MockTreasury(address(rai));
        rai.transfer(address(treasury), initTokenAmount);

        // Create the TWAP
        chainlinkTwap = new ChainlinkTWAP(
          address(aggregator),
          2 hours,
          4 hours,
          multiplier,
          2
        );

        // Create the reward relayer
        relayer = new IncreasingRewardRelayer(
            address(chainlinkTwap),
            address(treasury),
            baseCallerReward,
            maxCallerReward,
            perSecondCallerRewardIncrease,
            1 hours
        );
        chainlinkTwap.modifyParameters("rewardRelayer", address(relayer));

        // Setup treasury allowance
        treasury.setTotalAllowance(address(relayer), uint(-1));
        treasury.setPerBlockAllowance(address(relayer), uint(-1));
        hevm.warp(now + chainlinkTwap.periodSize());

        // Update median
        hevm.warp(now + 10);
        aggregator.modifyParameters(120 * aggregator.gwei(), now);
        chainlinkTwap.updateResult(address(this));
        (, bool isValid) = chainlinkTwap.getResultWithValidity();
        assertTrue(!isValid);

        hevm.warp(now + 1 hours);
        aggregator.modifyParameters(120 * aggregator.gwei(), now);
        chainlinkTwap.updateResult(address(this));
        (, isValid) = chainlinkTwap.getResultWithValidity();
        assertTrue(!isValid);

        hevm.warp(now + 1 hours);
        aggregator.modifyParameters(120 * aggregator.gwei(), now);
        chainlinkTwap.updateResult(address(this));
        (, isValid) = chainlinkTwap.getResultWithValidity();
        assertTrue(isValid);

        // Checks
        (uint256 medianPrice,) = chainlinkTwap.getResultWithValidity();
        assertEq(medianPrice, uint(120 * aggregator.gwei()));

        assertEq(chainlinkTwap.updates(), 3);
        assertEq(chainlinkTwap.timeElapsedSinceFirstObservation(), 1 hours);
    }
    function test_two_hour_twap_massive_update_delay() public {
        // Create token
        rai = new DSToken("RAI", "RAI");
        rai.mint(initTokenAmount);

        // Create treasury
        treasury = new MockTreasury(address(rai));
        rai.transfer(address(treasury), initTokenAmount);

        // Create the TWAP
        chainlinkTwap = new ChainlinkTWAP(
          address(aggregator),
          2 hours,
          4 hours,
          multiplier,
          2
        );

        // Create the reward relayer
        relayer = new IncreasingRewardRelayer(
            address(chainlinkTwap),
            address(treasury),
            baseCallerReward,
            maxCallerReward,
            perSecondCallerRewardIncrease,
            1 hours
        );
        relayer.modifyParameters("maxRewardIncreaseDelay", 6 hours);
        chainlinkTwap.modifyParameters("rewardRelayer", address(relayer));

        // Setup treasury allowance
        treasury.setTotalAllowance(address(relayer), uint(-1));
        treasury.setPerBlockAllowance(address(relayer), uint(-1));
        hevm.warp(now + chainlinkTwap.periodSize());

        // Update median
        hevm.warp(now + 1 hours);
        aggregator.modifyParameters(120 * aggregator.gwei(), now);
        chainlinkTwap.updateResult(address(this));

        hevm.warp(now + 1 hours);
        aggregator.modifyParameters(120 * aggregator.gwei(), now);
        chainlinkTwap.updateResult(address(this));

        hevm.warp(now + 3650 days);
        aggregator.modifyParameters(120 * aggregator.gwei(), now);
        chainlinkTwap.updateResult(address(this));

        // Checks
        (uint256 medianPrice, bool isValid) = chainlinkTwap.getResultWithValidity();
        assertEq(medianPrice, 120000000000);
        assertTrue(!isValid);

        assertEq(chainlinkTwap.updates(), 3);
        assertEq(chainlinkTwap.timeElapsedSinceFirstObservation(), 3650 days);

        // Another update
        hevm.warp(now + 1 hours);
        aggregator.modifyParameters(120 * aggregator.gwei(), now);
        chainlinkTwap.updateResult(address(this));

        // Checks
        (medianPrice, isValid) = chainlinkTwap.getResultWithValidity();
        assertEq(medianPrice, 120000000000);
        assertTrue(isValid);
    }
}
