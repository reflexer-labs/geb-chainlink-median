pragma solidity 0.6.7;

import "geb-treasury-reimbursement/math/GebMath.sol";

import "./link/AggregatorInterface.sol";

abstract contract IncreasingRewardRelayerLike {
    function reimburseCaller(address) virtual external;
}

contract ChainlinkPriceFeedMedianizer is GebMath {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) virtual external isAuthorized {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) virtual external isAuthorized {
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "ChainlinkPriceFeedMedianizer/account-not-authorized");
        _;
    }

    // --- Variables ---
    AggregatorInterface public chainlinkAggregator;
    IncreasingRewardRelayerLike public rewardRelayer;

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
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event ModifyParameters(
      bytes32 parameter,
      address addr
    );
    event ModifyParameters(
      bytes32 parameter,
      uint256 val
    );
    event UpdateResult(uint256 medianPrice, uint256 lastUpdateTime);

    constructor(
      address aggregator,
      uint256 periodSize_
    ) public {
        require(aggregator != address(0), "ChainlinkPriceFeedMedianizer/null-aggregator");
        require(multiplier >= 1, "ChainlinkPriceFeedMedianizer/null-multiplier");
        require(periodSize_ > 0, "ChainlinkPriceFeedMedianizer/null-period-size");

        authorizedAccounts[msg.sender] = 1;

        lastUpdateTime                 = now;
        periodSize                     = periodSize_;
        chainlinkAggregator            = AggregatorInterface(aggregator);

        emit AddAuthorization(msg.sender);
        emit ModifyParameters("periodSize", periodSize);
        emit ModifyParameters("aggregator", aggregator);
    }

    // --- General Utils ---
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- Administration ---
    /*
    * @notify Modify an uin256 parameter
    * @param parameter The name of the parameter to change
    * @param data The new parameter value
    */
    function modifyParameters(bytes32 parameter, uint256 data) external isAuthorized {
        if (parameter == "periodSize") {
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
    /*
    * @notify Modify an address parameter
    * @param parameter The name of the parameter to change
    * @param addr The new parameter address
    */
    function modifyParameters(bytes32 parameter, address addr) external isAuthorized {
        require(addr != address(0), "ChainlinkPriceFeedMedianizer/null-addr");
        if (parameter == "aggregator") chainlinkAggregator = AggregatorInterface(addr);
        else if (parameter == "rewardRelayer") {
          rewardRelayer = IncreasingRewardRelayerLike(addr);
        }
        else revert("ChainlinkPriceFeedMedianizer/modify-unrecognized-param");
        emit ModifyParameters(parameter, addr);
    }

    // --- Main Getters ---
    /**
    * @notice Fetch the latest medianResult or revert if is is invalid
    **/
    function read() external view returns (uint256) {
        require(both(medianPrice > 0, subtract(now, linkAggregatorTimestamp) <= multiply(periodSize, staleThreshold)), "ChainlinkPriceFeedMedianizer/invalid-price-feed");
        return medianPrice;
    }
    /**
    * @notice Fetch the latest medianResult and whether it is valid or not
    **/
    function getResultWithValidity() external view returns (uint256,bool) {
        return (medianPrice, both(medianPrice > 0, subtract(now, linkAggregatorTimestamp) <= multiply(periodSize, staleThreshold)));
    }

    // --- Median Updates ---
    /*
    * @notify Update the median price
    * @param feeReceiver The address that will receive a SF payout for calling this function
    */
    function updateResult(address feeReceiver) external {
        // The relayer must not be null
        require(address(rewardRelayer) != address(0), "ChainlinkPriceFeedMedianizer/null-reward-relayer");

        int256 aggregatorPrice      = chainlinkAggregator.latestAnswer();
        uint256 aggregatorTimestamp = chainlinkAggregator.latestTimestamp();

        // Perform price and time checks
        require(aggregatorPrice > 0, "ChainlinkPriceFeedMedianizer/invalid-price-feed");
        require(both(aggregatorTimestamp > 0, aggregatorTimestamp > linkAggregatorTimestamp), "ChainlinkPriceFeedMedianizer/invalid-timestamp");

        // Update state
        medianPrice             = multiply(uint(aggregatorPrice), 10 ** uint(multiplier));
        linkAggregatorTimestamp = aggregatorTimestamp;
        lastUpdateTime          = now;

        // Emit the event
        emit UpdateResult(medianPrice, lastUpdateTime);

        // Get final fee receiver
        address finalFeeReceiver = (feeReceiver == address(0)) ? msg.sender : feeReceiver;

        // Send the reward
        rewardRelayer.reimburseCaller(finalFeeReceiver);
    }
}
