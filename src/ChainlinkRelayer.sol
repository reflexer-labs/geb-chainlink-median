pragma solidity 0.6.7;

import "geb-treasury-reimbursement/math/GebMath.sol";

import "./link/AggregatorInterface.sol";

contract ChainlinkRelayer is GebMath {
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
        require(authorizedAccounts[msg.sender] == 1, "ChainlinkRelayer/account-not-authorized");
        _;
    }

    // --- Variables ---
    AggregatorInterface public chainlinkAggregator;

    // Multiplier for the Chainlink price feed in order to scaled it to 18 decimals. Default to 10 for USD price feeds
    uint8   public multiplier = 10;
    // Time threshold after which a Chainlink response is considered stale
    uint256 public staleThreshold;

    bytes32 public symbol = "ethusd";

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

    constructor(
      address aggregator,
      uint256 staleThreshold_
    ) public {
        require(aggregator != address(0), "ChainlinkRelayer/null-aggregator");
        require(multiplier >= 1, "ChainlinkRelayer/null-multiplier");
        require(staleThreshold_ > 0, "ChainlinkRelayer/null-stale-threshold");

        authorizedAccounts[msg.sender] = 1;

        staleThreshold                 = staleThreshold_;
        chainlinkAggregator            = AggregatorInterface(aggregator);

        emit AddAuthorization(msg.sender);
        emit ModifyParameters("staleThreshold", staleThreshold);
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
        if (parameter == "staleThreshold") {
          require(data > 1, "ChainlinkRelayer/invalid-stale-threshold");
          staleThreshold = data;
        }
        else revert("ChainlinkRelayer/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }
    /*
    * @notify Modify an address parameter
    * @param parameter The name of the parameter to change
    * @param addr The new parameter address
    */
    function modifyParameters(bytes32 parameter, address addr) external isAuthorized {
        require(addr != address(0), "ChainlinkRelayer/null-addr");
        if (parameter == "aggregator") chainlinkAggregator = AggregatorInterface(addr);
        else revert("ChainlinkRelayer/modify-unrecognized-param");
        emit ModifyParameters(parameter, addr);
    }

    // --- Main Getters ---
    /**
    * @notice Fetch the latest medianResult or revert if is is null, if the price is stale or if chainlinkAggregator is null
    **/
    function read() external view returns (uint256) {
        // The relayer must not be null
        require(address(chainlinkAggregator) != address(0), "ChainlinkRelayer/null-median");

        // Fetch values from Chainlink
        uint256 medianPrice         = multiply(uint(chainlinkAggregator.latestAnswer()), 10 ** uint(multiplier));
        uint256 aggregatorTimestamp = chainlinkAggregator.latestTimestamp();

        require(both(medianPrice > 0, subtract(now, aggregatorTimestamp) <= staleThreshold), "ChainlinkRelayer/invalid-price-feed");
        return medianPrice;
    }
    /**
    * @notice Fetch the latest medianResult and whether it is valid or not
    **/
    function getResultWithValidity() external view returns (uint256, bool) {
        if (address(chainlinkAggregator) == address(0)) return (0, false);

        // Fetch values from Chainlink
        uint256 medianPrice         = multiply(uint(chainlinkAggregator.latestAnswer()), 10 ** uint(multiplier));
        uint256 aggregatorTimestamp = chainlinkAggregator.latestTimestamp();

        return (medianPrice, both(medianPrice > 0, subtract(now, aggregatorTimestamp) <= staleThreshold));
    }

    // --- Median Updates ---
    /*
    * @notice Remnant from other Chainlink medians
    */
    function updateResult(address feeReceiver) external {}
}
