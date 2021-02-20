pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-token/token.sol";

import "./geb/MockTreasury.sol";

import { ChainlinkTWAP } from  "../ChainlinkTWAP.sol";

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
    MockTreasury treasury;
    DSToken rai;
    address alice = address(0x4567);
    address me;

    uint256 startTime                     = 1577836800;
    uint256 windowSize                    = 10;
    uint256 maxWindowSize                 = 50;
    uint256 baseCallerReward              = 15 ether;
    uint256 maxCallerReward               = 20 ether;
    uint256 initTokenAmount               = 100000000 ether;
    uint256 perSecondCallerRewardIncrease = 1.01E27;
    uint8   granularity                   = 5;
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
          address(treasury),
          windowSize,
          maxWindowSize,
          multiplier,
          baseCallerReward,
          maxCallerReward,
          perSecondCallerRewardIncrease,
          granularity
        );

        // Setup treasury allowance
        treasury.setTotalAllowance(address(chainlinkTwap), uint(-1));
        treasury.setPerBlockAllowance(address(chainlinkTwap), uint(-1));

        me = address(this);

        hevm.warp(now + chainlinkTwap.periodSize());
    }

    // --- Math ---
    function multiply(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, 'mul-overflow');
    }

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
    }
    function testFail_setup_null_aggregator() public {
        chainlinkTwap = new ChainlinkTWAP(
          address(0x0),
          address(treasury),
          windowSize,
          maxWindowSize,
          multiplier,
          baseCallerReward,
          maxCallerReward,
          perSecondCallerRewardIncrease,
          granularity
        );
    }

    function testFail_setup_null_granularity() public {
        chainlinkTwap = new ChainlinkTWAP(
          address(aggregator),
          address(treasury),
          windowSize,
          maxWindowSize,
          multiplier,
          baseCallerReward,
          maxCallerReward,
          perSecondCallerRewardIncrease,
          0
        );
    }

    function testFail_setup_null_multiplier() public {
        chainlinkTwap = new ChainlinkTWAP(
          address(aggregator),
          address(treasury),
          windowSize,
          maxWindowSize,
          0,
          baseCallerReward,
          maxCallerReward,
          perSecondCallerRewardIncrease,
          granularity
        );
    }

    function testFail_setup_null_window_size() public {
        chainlinkTwap = new ChainlinkTWAP(
          address(aggregator),
          address(treasury),
          0,
          maxWindowSize,
          multiplier,
          baseCallerReward,
          baseCallerReward,
          perSecondCallerRewardIncrease,
          granularity
        );
    }

    function testFail_setup_invalid_max_window_size() public {
        chainlinkTwap = new ChainlinkTWAP(
          address(aggregator),
          address(treasury),
          windowSize,
          windowSize,
          multiplier,
          baseCallerReward,
          baseCallerReward,
          perSecondCallerRewardIncrease,
          granularity
        );
    }

    function testFail_setup_window_not_evenly_divisible() public {
        chainlinkTwap = new ChainlinkTWAP(
          address(aggregator),
          address(treasury),
          windowSize,
          maxWindowSize,
          multiplier,
          baseCallerReward,
          baseCallerReward,
          perSecondCallerRewardIncrease,
          3
        );
    }

    function test_change_aggregator() public {
        chainlinkTwap.modifyParameters("aggregator", address(0x123));

        assertTrue(address(chainlinkTwap.chainlinkAggregator()) == address(0x123));
    }

    function test_change_treasury() public {
        treasury = new MockTreasury(address(rai));
        chainlinkTwap.modifyParameters("treasury", address(treasury));

        assertTrue(address(chainlinkTwap.treasury()) == address(treasury));
    }

    function testFail_change_treasury_coin_not_set() public {
        treasury = new MockTreasury(address(0));
        chainlinkTwap.modifyParameters("treasury", address(treasury));
    }

    function test_change_base_update_caller_reward() public {
        chainlinkTwap.modifyParameters("baseUpdateCallerReward", 1);

        assertEq(chainlinkTwap.baseUpdateCallerReward(), 1);
    }

    function testFail_change_base_update_caller_reward_more_than_max_reward() public {
        chainlinkTwap.modifyParameters("baseUpdateCallerReward", maxCallerReward + 1);
    }    

    function test_change_base_update_max_caller_reward() public {
        chainlinkTwap.modifyParameters("maxUpdateCallerReward", maxCallerReward + 1 ether);

        assertEq(chainlinkTwap.maxUpdateCallerReward(), maxCallerReward + 1 ether);
    }

    function testFail_change_base_update_max_caller_reward_less_than_base_reward() public {
        chainlinkTwap.modifyParameters("maxUpdateCallerReward", baseCallerReward);
    }

    function test_change_per_second_reward_increase() public {
        chainlinkTwap.modifyParameters("perSecondCallerRewardIncrease", 10**27);

        assertEq(chainlinkTwap.perSecondCallerRewardIncrease(), 10**27);
    }

    function testFail_change_per_second_reward_increase_less_than_ray() public {
        chainlinkTwap.modifyParameters("perSecondCallerRewardIncrease", 10**27 - 1);
    }

    function test_change_max_reward_increase_delay() public {
        chainlinkTwap.modifyParameters("maxRewardIncreaseDelay", 123);

        assertEq(chainlinkTwap.maxRewardIncreaseDelay(), 123);
    }

    function testFail_change_max_reward_increase_delay_zero() public {
        chainlinkTwap.modifyParameters("maxRewardIncreaseDelay", 0);
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
        revertTreasury.setTotalAllowance(address(chainlinkTwap), uint(-1));
        revertTreasury.setPerBlockAllowance(address(chainlinkTwap), uint(-1));

        chainlinkTwap.modifyParameters("treasury", address(revertTreasury));

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
        chainlinkTwap.modifyParameters("maxRewardIncreaseDelay", 5 * 52 weeks); // need to force a lower bound maxRewardIncreaseDelay or things break

        uint maxRewardDelay = 100;
        chainlinkTwap.updateResult(alice);
        assertEq(rai.balanceOf(alice), baseCallerReward);

        hevm.warp(now + chainlinkTwap.periodSize());
        aggregator.modifyParameters(130 * 10**9, now);
        chainlinkTwap.updateResult(alice);
        assertEq(rai.balanceOf(alice), baseCallerReward * 2);

        hevm.warp(now + chainlinkTwap.periodSize() + chainlinkTwap.maxRewardIncreaseDelay() + 30);
        aggregator.modifyParameters(130 * 10**9, now);
        chainlinkTwap.updateResult(alice);
        assertEq(rai.balanceOf(alice), baseCallerReward * 2 + maxCallerReward);

        hevm.warp(now + chainlinkTwap.periodSize() + chainlinkTwap.maxRewardIncreaseDelay() + 30);
        aggregator.modifyParameters(130 * 10**9, now);
        chainlinkTwap.updateResult(address(0x1234));
        assertEq(rai.balanceOf(address(0x1234)), maxCallerReward);

        hevm.warp(now + chainlinkTwap.periodSize() + chainlinkTwap.maxRewardIncreaseDelay() + 300 weeks);
        aggregator.modifyParameters(130 * 10**9, now);
        chainlinkTwap.updateResult(address(0x1234));
        assertEq(rai.balanceOf(address(0x1234)), maxCallerReward * 2);
    }

    // will include all prices in values array, and then warp the interval value
    // last interval is not warped (so the updates are fresh)
    // returns twap for a given granularity (without accounting for too large intervals, overflows were also unnacounted for)
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
                converterResultCumulative += values[i] * intervals[i];
            
            periodStart = now;

            hevm.warp(now + intervals[i]);
        }

        return converterResultCumulative / (now - periodStart);
    }

    uint[] _values;
    uint[] _intervals;
    function test_read_same_price() public {
        for (uint i = 0; i <= granularity * 4; i++) {
            _values.push(uint(120 * aggregator.gwei()));
            _intervals.push(chainlinkTwap.periodSize());
        }
        
        uint testMedian = simulateUpdates(_values, _intervals, granularity);
        assertEq(testMedian, chainlinkTwap.read()); // check median result
    } 

    // different approach for unit testing, will run a number of random different values (adjusted
    // to be valid inputs) and check results. This will also randomize inputs for every run.
    function test_read_fuzz(uint[8] memory values, uint[8] memory intervals) public {
        for (uint i = 0; i < 8; i++) {
            _values.push(((values[i] % 1000) + 1) * uint(aggregator.gwei())); // random values from 1 to 1001 gwei
            _intervals.push(chainlinkTwap.periodSize());//+ (intervals[i] % chainlinkTwap.periodSize())); todo: check
        }
        
        uint testMedian = simulateUpdates(_values, _intervals, granularity);
        assertEq(testMedian, chainlinkTwap.read()); // check median result
    }



    function test_two_hour_twap() public {
        // Setup
        // Create token
        rai = new DSToken("RAI", "RAI");
        rai.mint(initTokenAmount);

        // Create treasury
        treasury = new MockTreasury(address(rai));
        rai.transfer(address(treasury), initTokenAmount);

        chainlinkTwap = new ChainlinkTWAP(
          address(aggregator),
          address(treasury),
          2 hours,
          4 hours,
          multiplier,
          baseCallerReward,
          maxCallerReward,
          perSecondCallerRewardIncrease,
          2
        );

        // Setup treasury allowance
        treasury.setTotalAllowance(address(chainlinkTwap), uint(-1));
        treasury.setPerBlockAllowance(address(chainlinkTwap), uint(-1));

        me = address(this);

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
        assertEq(medianPrice, 240000000000); // todo: check

        assertEq(chainlinkTwap.updates(), 3);
        assertEq(chainlinkTwap.timeElapsedSinceFirstObservation(), 1 hours);
    }
    function test_two_hour_twap_massive_update_delay() public {
        // Setup
        // Create token
        rai = new DSToken("RAI", "RAI");
        rai.mint(initTokenAmount);

        // Create treasury
        treasury = new MockTreasury(address(rai));
        rai.transfer(address(treasury), initTokenAmount);

        chainlinkTwap = new ChainlinkTWAP(
          address(aggregator),
          address(treasury),
          2 hours,
          4 hours,
          multiplier,
          baseCallerReward,
          maxCallerReward,
          perSecondCallerRewardIncrease,
          2
        );

        chainlinkTwap.modifyParameters("maxRewardIncreaseDelay", 5 * 52 weeks); 

        // Setup treasury allowance
        treasury.setTotalAllowance(address(chainlinkTwap), uint(-1));
        treasury.setPerBlockAllowance(address(chainlinkTwap), uint(-1));

        me = address(this);

        hevm.warp(now + chainlinkTwap.periodSize());

        // Update median
        hevm.warp(now + 10);
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
        assertEq(medianPrice, 120000000000); // bug
        assertTrue(isValid);
    }
}
