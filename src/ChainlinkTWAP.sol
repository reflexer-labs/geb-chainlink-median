pragma solidity 0.6.7;

import "geb-treasury-reimbursement/IncreasingTreasuryReimbursement.sol";

import "./link/AggregatorInterface.sol";

contract ChainlinkTWAP is IncreasingTreasuryReimbursement {
    // --- Variables ---
    AggregatorInterface public chainlinkAggregator;

    // Delay between updates after which the reward starts to increase
    uint256 public periodSize;
    // Timestamp of the Chainlink aggregator
    uint256 public linkAggregatorTimestamp;
    // Last timestamp when the median was updated
    uint256 public lastUpdateTime;                  // [unix timestamp]
    // Cumulative result
    uint256 public converterResultCumulative;
    // Latest result
    uint256 private medianResult;                   // [wad]
    /**
      The ideal amount of time over which the moving average should be computed, e.g. 24 hours.
      In practice it can and most probably will be different than the actual window over which the contract medianizes.
    **/
    uint256 public windowSize;
    // Maximum window size used to determine if the median is 'valid' (close to the real one) or not
    uint256 public maxWindowSize;
    // Total number of updates
    uint256 public updates;
    // Multiplier for the Chainlink result
    uint8   public multiplier = 1;
    // Number of updates in the window
    uint8   public granularity;

    // You want to change these every deployment
    uint256 public staleThreshold = 3;
    bytes32 public symbol         = "fast-gas";

    ChainlinkObservation[] public chainlinkObservations;

    // --- Structs ---
    struct ChainlinkObservation {
        uint timestamp;
        uint timeAdjustedResult;
    }

    // --- Events ---
    event UpdateResult(uint256 result);

    constructor(
      address aggregator,
      address treasury_,
      uint256 windowSize_,
      uint256 maxWindowSize_,
      uint8   multiplier_,
      uint256 baseUpdateCallerReward_,
      uint256 maxUpdateCallerReward_,
      uint256 perSecondCallerRewardIncrease_,
      uint8   granularity_
    ) public IncreasingTreasuryReimbursement(treasury_, baseUpdateCallerReward_, maxUpdateCallerReward_, perSecondCallerRewardIncrease_) {
        require(aggregator != address(0), "ChainlinkTWAP/null-aggregator");
        require(multiplier_ >= 1, "ChainlinkTWAP/null-multiplier");
        require(granularity_ > 1, 'ChainlinkTWAP/null-granularity');
        require(windowSize_ > 0, 'ChainlinkTWAP/null-window-size');
        require(maxWindowSize_ > windowSize_, 'ChainlinkTWAP/invalid-max-window-size');
        require(
          (periodSize = windowSize_ / granularity_) * granularity_ == windowSize_,
          'ChainlinkTWAP/window-not-evenly-divisible'
        );

        lastUpdateTime      = now;
        windowSize          = windowSize_;
        maxWindowSize       = maxWindowSize_;
        granularity         = granularity_;
        multiplier          = multiplier_;

        chainlinkAggregator = AggregatorInterface(aggregator);

        emit ModifyParameters(bytes32("maxWindowSize"), maxWindowSize);
        emit ModifyParameters(bytes32("aggregator"), aggregator);
    }

    // --- Boolean Utils ---
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- General Utils ---
    /**
    * @notice Returns the oldest observations (relative to the current index in the Uniswap/Converter lists)
    **/
    function getFirstObservationInWindow()
      private view returns (ChainlinkObservation storage firstChainlinkObservation) {
        uint256 earliestObservationIndex = earliestObservationIndex();
        firstChainlinkObservation        = chainlinkObservations[earliestObservationIndex];
    }
    /**
      @notice It returns the time passed since the first observation in the window
    **/
    function timeElapsedSinceFirstObservation() public view returns (uint256) {
        if (updates > 1) {
          ChainlinkObservation memory firstChainlinkObservation = getFirstObservationInWindow();
          return subtract(now, firstChainlinkObservation.timestamp);
        }
        return 0;
    }
    /**
    * @notice Returns the index of the earliest observation in the window
    **/
    function earliestObservationIndex() public view returns (uint256) {
        if (updates <= granularity) {
          return 0;
        }
        return subtract(updates, uint(granularity));
    }
    /**
    * @notice Get the observation list length
    **/
    function getObservationListLength() public view returns (uint256) {
        return chainlinkObservations.length;
    }

    // --- Administration ---
    function modifyParameters(bytes32 parameter, uint256 data) external isAuthorized {
        if (parameter == "baseUpdateCallerReward") {
            require(data < maxUpdateCallerReward, "ChainlinkTWAP/invalid-base-reward"); 
            baseUpdateCallerReward = data;
        }
        else if (parameter == "maxUpdateCallerReward") {
          require(data > baseUpdateCallerReward, "ChainlinkTWAP/invalid-max-reward"); 
          maxUpdateCallerReward = data;
        }
        else if (parameter == "perSecondCallerRewardIncrease") {
          require(data >= RAY, "ChainlinkTWAP/invalid-reward-increase");
          perSecondCallerRewardIncrease = data;
        }
        else if (parameter == "maxRewardIncreaseDelay") {
          require(data > 0, "ChainlinkTWAP/invalid-max-increase-delay");
          maxRewardIncreaseDelay = data;
        }
        else if (parameter == "maxWindowSize") { 
          require(data > windowSize, 'ChainlinkTWAP/invalid-max-window-size');
          maxWindowSize = data;
        }
        else if (parameter == "staleThreshold") {
          require(data > 1, "ChainlinkTWAP/invalid-stale-threshold");
          staleThreshold = data;
        }
        else revert("ChainlinkTWAP/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }
    function modifyParameters(bytes32 parameter, address addr) external isAuthorized {
        if (parameter == "aggregator") chainlinkAggregator = AggregatorInterface(addr);
        else if (parameter == "treasury") {
          require(StabilityFeeTreasuryLike(addr).systemCoin() != address(0), "ChainlinkTWAP/treasury-coin-not-set");
      	  treasury = StabilityFeeTreasuryLike(addr);
        }
        else revert("ChainlinkTWAP/modify-unrecognized-param");
        emit ModifyParameters(parameter, addr);
    }

    // --- Main Getters ---
    /**
    * @notice Fetch the latest medianResult or revert if is is null
    **/
    function read() external view returns (uint256) {
        require(
          both(both(medianResult > 0, updates > granularity), timeElapsedSinceFirstObservation() <= maxWindowSize),
          "ChainlinkTWAP/invalid-price-feed"
        );
        return multiply(medianResult, multiplier);
    }
    /**
    * @notice Fetch the latest medianResult and whether it is null or not
    **/
    function getResultWithValidity() external view returns (uint256, bool) {
        return (
          multiply(medianResult, multiplier),
          both(both(medianResult > 0, updates > granularity), timeElapsedSinceFirstObservation() <= maxWindowSize)
        );
    }

    // --- Median Updates ---
    function updateResult(address feeReceiver) external {
        uint256 elapsedTime = (chainlinkObservations.length == 0) ?
          subtract(now, lastUpdateTime) : subtract(now, chainlinkObservations[chainlinkObservations.length - 1].timestamp);

        // Check delay between calls
        require(elapsedTime >= periodSize, "ChainlinkTWAP/wait-more");

        int256 aggregatorResult     = chainlinkAggregator.latestAnswer();
        uint256 aggregatorTimestamp = chainlinkAggregator.latestTimestamp();

        require(aggregatorResult > 0, "ChainlinkTWAP/invalid-feed-result");
        require(both(aggregatorTimestamp > 0, aggregatorTimestamp > linkAggregatorTimestamp), "ChainlinkTWAP/invalid-timestamp");

        // Calculate the reward
        uint256 callerReward    = getCallerReward(lastUpdateTime, periodSize);

        // Get current first observation timestamp
        uint timeSinceFirst;
        if (updates > 0) {
              ChainlinkObservation memory firstUniswapObservation = getFirstObservationInWindow();
              timeSinceFirst = subtract(now, firstUniswapObservation.timestamp);
        } else 
          timeSinceFirst = elapsedTime;

        // Update the observations array
        updateObservations(elapsedTime, uint256(aggregatorResult));

        // Update var state
        medianResult            = converterResultCumulative / timeSinceFirst;
        updates                 = addition(updates, 1);
        linkAggregatorTimestamp = aggregatorTimestamp;
        lastUpdateTime          = now;

        emit UpdateResult(medianResult);

        // Send the reward
        rewardCaller(feeReceiver, callerReward);
    }
    /**
    * @notice Push new observation data in the observation array
    * @param timeElapsedSinceLatest Time elapsed between now and the earliest observation in the window
    * @param newResult Latest result coming from Chainlink
    **/
    function updateObservations(
      uint256 timeElapsedSinceLatest,
      uint256 newResult
    ) internal {
        // Compute the new time adjusted result
        uint256 newTimeAdjustedResult = multiply(newResult, timeElapsedSinceLatest);
        // Add Chainlink observation
        chainlinkObservations.push(ChainlinkObservation(now, newTimeAdjustedResult));
        // Add the new update
        converterResultCumulative = addition(converterResultCumulative, newTimeAdjustedResult);

        // Subtract the earliest update
        if (updates >= granularity) {
          ChainlinkObservation memory chainlinkObservation = getFirstObservationInWindow();
          converterResultCumulative = subtract(converterResultCumulative, chainlinkObservation.timeAdjustedResult);
        }
    }
}
