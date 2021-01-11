pragma solidity 0.6.7;

import "./link/AggregatorInterface.sol";

contract ChainlinkPriceFeedMedianizer {
    // --- Variables ---
    AggregatorInterface public chainlinkAggregator;

    // Delay between updates after which the reward starts to increase
    uint256 public periodSize;
    // Latest median price
    uint256 private medianPrice;                    // [wad]
    // Timestamp of the Chainlink aggregator
    uint256 public linkAggregatorTimestamp;
    // Last timestamp when the median was updated
    uint256 public  lastUpdateTime;                 // [unix timestamp]
    // Multiplier for the Chainlink price feed in order to scaled it to 18 decimals. Default to 10 for USD price feeds
    uint8   public  multiplier = 10;

    // You want to change these every deployment
    uint256 public staleThreshold = 3;
    bytes32 public symbol         = "ethusd";

    // --- Events ---
    event UpdateResult(uint256 medianPrice, uint256 lastUpdateTime);

    constructor(
      address aggregator,
      address treasury_,
      uint256 periodSize_,
      uint256 baseUpdateCallerReward_,
      uint256 maxUpdateCallerReward_,
      uint256 perSecondCallerRewardIncrease_
    ) public {
        require(aggregator != address(0), "ChainlinkPriceFeedMedianizer/null-aggregator");
        require(multiplier >= 1, "ChainlinkPriceFeedMedianizer/null-multiplier");
        require(periodSize_ > 0, "ChainlinkPriceFeedMedianizer/null-period-size");

        periodSize          = periodSize_;
        chainlinkAggregator = AggregatorInterface(aggregator);

        emit ModifyParameters(bytes32("periodSize"), periodSize);
        emit ModifyParameters(bytes32("aggregator"), aggregator);
    }

    // --- General Utils ---
    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- Administration ---
    function modifyParameters(bytes32 parameter, uint256 data) external isAuthorized {
        if (parameter == "baseUpdateCallerReward") baseUpdateCallerReward = data;
        else if (parameter == "maxUpdateCallerReward") {
          require(data > baseUpdateCallerReward, "ChainlinkPriceFeedMedianizer/invalid-max-reward");
          maxUpdateCallerReward = data;
        }
        else if (parameter == "perSecondCallerRewardIncrease") {
          require(data >= RAY, "ChainlinkPriceFeedMedianizer/invalid-reward-increase");
          perSecondCallerRewardIncrease = data;
        }
        else if (parameter == "maxRewardIncreaseDelay") {
          require(data > 0, "ChainlinkPriceFeedMedianizer/invalid-max-increase-delay");
          maxRewardIncreaseDelay = data;
        }
        else if (parameter == "periodSize") {
          require(data > 0, "ChainlinkPriceFeedMedianizer/null-period-size");
          periodSize = data;
        }
        else if (parameter == "staleThreshold") {
          require(data > 1, "ChainlinkPriceFeedMedianizer/invalid-stale-threshold");
          staleThreshold = data;
        }
        else revert("ChainlinkPriceFeedMedianizer/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }
    function modifyParameters(bytes32 parameter, address addr) external isAuthorized {
        if (parameter == "aggregator") chainlinkAggregator = AggregatorInterface(addr);
        else if (parameter == "treasury") {
          require(StabilityFeeTreasuryLike(addr).systemCoin() != address(0), "ChainlinkPriceFeedMedianizer/treasury-coin-not-set");
      	  treasury = StabilityFeeTreasuryLike(addr);
        }
        else revert("ChainlinkPriceFeedMedianizer/modify-unrecognized-param");
        emit ModifyParameters(parameter, addr);
    }

    function read() external view returns (uint256) {
        require(both(medianPrice > 0, subtract(now, linkAggregatorTimestamp) <= multiply(periodSize, staleThreshold)), "ChainlinkPriceFeedMedianizer/invalid-price-feed");
        return medianPrice;
    }

    function getResultWithValidity() external view returns (uint256,bool) {
        return (medianPrice, both(medianPrice > 0, subtract(now, linkAggregatorTimestamp) <= multiply(periodSize, staleThreshold)));
    }

    // --- Median Updates ---
    function updateResult(address feeReceiver) external {
        int256 aggregatorPrice = chainlinkAggregator.latestAnswer();
        uint256 aggregatorTimestamp = chainlinkAggregator.latestTimestamp();
        require(aggregatorPrice > 0, "ChainlinkPriceFeedMedianizer/invalid-price-feed");
        require(aggregatorTimestamp > 0 && aggregatorTimestamp > linkAggregatorTimestamp, "ChainlinkPriceFeedMedianizer/invalid-timestamp");
        uint256 callerReward    = getCallerReward();
        medianPrice             = multiply(uint(aggregatorPrice), 10 ** uint(multiplier));
        linkAggregatorTimestamp = aggregatorTimestamp;
        lastUpdateTime          = now;
        emit UpdateResult(medianPrice, lastUpdateTime);
        rewardCaller(feeReceiver, callerReward);
    }
}
