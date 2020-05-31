pragma solidity ^0.5.15;

import "./link/AggregatorInterface.sol";

contract Logging {
    event LogNote(
        bytes4   indexed  sig,
        address  indexed  usr,
        bytes32  indexed  arg1,
        bytes32  indexed  arg2,
        bytes             data
    ) anonymous;

    modifier emitLog {
        _;
        assembly {
            // log an 'anonymous' event with a constant 6 words of calldata
            // and four indexed topics: selector, caller, arg1 and arg2
            let mark := msize                         // end of memory ensures zero
            mstore(0x40, add(mark, 288))              // update free memory pointer
            mstore(mark, 0x20)                        // bytes type data offset
            mstore(add(mark, 0x20), 224)              // bytes size (padded)
            calldatacopy(add(mark, 0x40), 0, 224)     // bytes payload
            log4(mark, 288,                           // calldata
                 shl(224, shr(224, calldataload(0))), // msg.sig
                 caller,                              // msg.sender
                 calldataload(4),                     // arg1
                 calldataload(36)                     // arg2
                )
        }
    }
}

contract ChainlinkPriceFeedMedianizer is Logging {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external emitLog isAuthorized {
        authorizedAccounts[account] = 1;
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external emitLog isAuthorized {
        authorizedAccounts[account] = 0;
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "ChainlinkPriceFeedMedianizer/account-not-authorized");
        _;
    }

    AggregatorInterface public chainlinkAggregator;

    uint128 private medianPrice;
    uint32  public  lastUpdateTime;

    bytes32 public constant symbol = "ethusd"; // You want to change this every deployment

    constructor(address aggregator) public {
        authorizedAccounts[msg.sender] = 1;
        chainlinkAggregator = AggregatorInterface(aggregator);
    }

    // --- Administration ---
    function modifyParameters(bytes32 parameter, address addr) external emitLog isAuthorized {
        if (parameter == "aggregator") chainlinkAggregator = AggregatorInterface(addr);
        else revert("ChainlinkPriceFeedMedianizer/modify-unrecognized-param");
    }

    function read() external view returns (uint256) {
        require(medianPrice > 0, "ChainlinkPriceFeedMedianizer/invalid-price-feed");
        return medianPrice;
    }

    function getResultWithValidity() external view returns (uint256,bool) {
        return (medianPrice, medianPrice > 0);
    }

    function updateResult() external emitLog {
        int256 aggregatorPrice = chainlinkAggregator.latestAnswer();
        uint256 aggregatorTimestamp = chainlinkAggregator.latestTimestamp();
        require(aggregatorPrice > 0, "ChainlinkPriceFeedMedianizer/invalid-price-feed");
        require(aggregatorTimestamp > 0 && aggregatorTimestamp >= lastUpdateTime, "ChainlinkPriceFeedMedianizer/invalid-timestamp");
        medianPrice = uint128(aggregatorPrice);
        lastUpdateTime = uint32(aggregatorTimestamp);
    }
}
