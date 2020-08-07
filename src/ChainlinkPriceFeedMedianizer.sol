pragma solidity ^0.6.7;

import "./link/AggregatorInterface.sol";

abstract contract StabilityFeeTreasuryLike {
    function systemCoin() virtual external view returns (address);
    function pullFunds(address, address, uint) virtual external;
}

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
            let mark := mload(0x40)                   // end of memory ensures zero
            mstore(0x40, add(mark, 288))              // update free memory pointer
            mstore(mark, 0x20)                        // bytes type data offset
            mstore(add(mark, 0x20), 224)              // bytes size (padded)
            calldatacopy(add(mark, 0x40), 0, 224)     // bytes payload
            log4(mark, 288,                           // calldata
                 shl(224, shr(224, calldataload(0))), // msg.sig
                 caller(),                            // msg.sender
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

    // Amount of GEB system coins paid to the caller of 'updateResult'
    uint256 public  updateCallerReward;
    uint128 private medianPrice;
    uint32  public  lastUpdateTime;
    uint8   public  multiplier = 10;  // default multiplier for Chainlink USD feeds

    bytes32 public symbol = "ethusd"; // you want to change this every deployment

    // SF treasury contract
    StabilityFeeTreasuryLike public treasury;

    event ModifyParameters(bytes32 parameter, address addr);
    event LogMedianPrice(uint256 medianPrice, uint256 lastUpdateTime);
    event RewardCaller(address feeReceiver, uint256 updateCallerReward);

    constructor(address aggregator, address treasury_, uint256 updateCallerReward_) public {
        require(multiplier >= 1, "ChainlinkPriceFeedMedianizer/null-multiplier");
        authorizedAccounts[msg.sender] = 1;
        treasury = StabilityFeeTreasuryLike(treasury_);
        updateCallerReward = updateCallerReward_;
        chainlinkAggregator = AggregatorInterface(aggregator);
    }

    // --- General Utils ---
    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }

    // --- Math ---
    function multiply(uint x, int y) internal pure returns (int z) {
        z = int(x) * y;
        require(int(x) >= 0);
        require(y == 0 || z / y == int(x));
    }

    // --- Administration ---
    function modifyParameters(bytes32 parameter, address addr) external emitLog isAuthorized {
        if (parameter == "aggregator") chainlinkAggregator = AggregatorInterface(addr);
        else if (parameter == "treasury") {
          require(StabilityFeeTreasuryLike(addr).systemCoin() != address(0), "ChainlinkPriceFeedMedianizer/treasury-coin-not-set");
      	  treasury = StabilityFeeTreasuryLike(addr);
        }
        else revert("ChainlinkPriceFeedMedianizer/modify-unrecognized-param");
        emit ModifyParameters(parameter, addr);
    }

    function read() external view returns (uint256) {
        require(medianPrice > 0, "ChainlinkPriceFeedMedianizer/invalid-price-feed");
        return medianPrice;
    }

    function getResultWithValidity() external view returns (uint256,bool) {
        return (medianPrice, medianPrice > 0);
    }

    // --- Treasury Utils ---
    function rewardCaller(address proposedFeeReceiver) internal {
        if (address(treasury) == proposedFeeReceiver) return;
        if (either(address(treasury) == address(0), updateCallerReward == 0)) return;
        address finalFeeReceiver = (proposedFeeReceiver == address(0)) ? msg.sender : proposedFeeReceiver;
        try treasury.pullFunds(finalFeeReceiver, treasury.systemCoin(), updateCallerReward) {
          emit RewardCaller(finalFeeReceiver, updateCallerReward);
        }
        catch(bytes memory revertReason) {}
    }

    // --- Median Updates ---
    function updateResult(address feeReceiver) external emitLog {
        int256 aggregatorPrice = chainlinkAggregator.latestAnswer();
        uint256 aggregatorTimestamp = chainlinkAggregator.latestTimestamp();
        require(aggregatorPrice > 0, "ChainlinkPriceFeedMedianizer/invalid-price-feed");
        require(aggregatorTimestamp > 0 && aggregatorTimestamp >= lastUpdateTime, "ChainlinkPriceFeedMedianizer/invalid-timestamp");
        medianPrice    = uint128(multiply(uint(aggregatorPrice), int256(10 ** uint(multiplier))));
        lastUpdateTime = uint32(aggregatorTimestamp);
        emit LogMedianPrice(medianPrice, lastUpdateTime);
        rewardCaller(feeReceiver);
    }
}
