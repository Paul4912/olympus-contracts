// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.10;

import {IERC20} from "../interfaces/IERC20.sol";
import {IsOHM} from "../interfaces/IsOHM.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {IYieldStreamer} from "../interfaces/IYieldStreamer.sol";
import {OlympusAccessControlled, IOlympusAuthority} from "../types/OlympusAccessControlled.sol";
import {IUniswapV2Router} from "../interfaces/IUniswapV2Router.sol";
import {IStaking} from  "../interfaces/IStaking.sol";

/**
    @title YieldStreamer
    @notice This contract allows users to deposit their gOhm and have their yield
            converted into DAI and sent to their address every interval.
 */
contract YieldStreamer is IYieldStreamer, OlympusAccessControlled {
    using SafeERC20 for IERC20;

    address public immutable OHM;
    address public immutable DAI;
    address public immutable sOHM;
    IUniswapV2Router public immutable sushiRouter;
    address[] sushiRouterPath = new address[](2);
    IStaking public immutable staking;

    bool public depositDisabled;
    bool public withdrawDisabled;
    bool public upkeepDisabled;

    uint256 public maxSwapSlippagePercent; // as fraction / 1000
    uint256 public feeToDaoPercent; // as percent /1000
    uint256 public minimumDaiThreshold; //MAKE SETTERS FOR ALL THESE

    struct DepositInfo {
        uint256 id;
        address depositor;
        address recipient;
        uint256 principalAmount; // Total amount of sOhm deposited as principal
        uint256 agnosticAmount; // Total amount deposited in gOhm
        uint256 lastUpkeepTimestamp;
        uint256 paymentInterval; // Time before yield is able to be swapped to DAI
        uint256 unclaimedDai;
        uint256 userMinimumDaiThreshold;
    }

    DepositInfo[] public depositInfo;
    mapping(address => uint256[]) public depositIndices;

    event Deposited(address indexed depositor_, uint256 amount_);
    event Withdrawn(address indexed depositor_, uint256 amount_);
    event UpkeepComplete(uint indexed timestamp);
    event EmergencyShutdown(bool active_);

    constructor (
        address sOhm_, 
        address OHM_, 
        address DAI_, 
        address sushiRouter_, 
        address staking_, 
        address authority_,
        uint256 maxSwapSlippagePercent_,
        uint256 feeToDaoPercent_,
        uint256 minimumDaiThreshold_
    ) OlympusAccessControlled(IOlympusAuthority(authority_)) {
        require(sOhm_ != address(0), "Invalid address for sOHM");
        sOHM = sOhm_;
        OHM = OHM_;
        DAI = DAI_;
        sushiRouter = IUniswapV2Router(sushiRouter_);
        staking = IStaking(staking_);
        sushiRouterPath[0] = OHM;
        sushiRouterPath[1] = DAI;
        maxSwapSlippagePercent = maxSwapSlippagePercent_;
        feeToDaoPercent = feeToDaoPercent_;
        minimumDaiThreshold = minimumDaiThreshold_;
    }

    /**
        @notice Deposit sOHM, records sender address and assign rebases to recipient
        @param amount_ Amount of sOHM
        @param recipient_ Address to direct staking yield and vault shares to
        @param paymentInterval_ how much time must elapse before yield is able to be swapped for DAI
    */
    function deposit(uint256 amount_, address recipient_, uint256 paymentInterval_, uint256 userMinimumDaiThreshold_) external override {
        require(!depositDisabled, "Deposits currently disabled");
        require(amount_ > 0, "Invalid deposit amount");
        require(recipient_ != address(0), "Invalid recipient address");
        require(userMinimumDaiThreshold_ >= minimumDaiThreshold, "minimumDaiThreshold too low");

        IERC20(sOHM).safeTransferFrom(msg.sender, address(this), amount_);

        depositInfo.push(
            DepositInfo({
                id: depositInfo.length,
                depositor: msg.sender,
                recipient: recipient_,
                principalAmount: amount_,
                agnosticAmount: _toAgnostic(amount_),
                lastUpkeepTimestamp: block.timestamp,
                paymentInterval: paymentInterval_,
                unclaimedDai: 0,
                userMinimumDaiThreshold: userMinimumDaiThreshold_
            })
        );

        emit Deposited(msg.sender, amount_);
    }

    //NOT DONE
	function withdraw(uint256 id_, uint256 amount_) external override {
        require(!withdrawDisabled, "Withdraws currently disabled");
        require(amount_ > 0, "Invalid withdraw amount");

        DepositInfo storage userDeposit = depositInfo[id_];

        require(userDeposit.depositor == msg.sender, "Deposit ID not yours");
    }

    //WRITE NATSPEC
	function upkeep() external override {
        uint256 totalOhm;

        for(uint256 i = 0; i < depositInfo.length; i++) {
            if(block.timestamp >= depositInfo[i].lastUpkeepTimestamp + depositInfo[i].paymentInterval) {
                DepositInfo storage currentDeposit = depositInfo[i];
                totalOhm += _getOutstandingYield(currentDeposit.principalAmount, currentDeposit.agnosticAmount);
                currentDeposit.lastUpkeepTimestamp = block.timestamp;
            }
        }

        staking.unstake(address(this), totalOhm, false, false);
        uint256 feeToDao = totalOhm * feeToDaoPercent / 1000; //send fee to DAO
        uint256 totalOhmToSwap = totalOhm - feeToDao;
        
        require(IERC20(OHM).approve(address(sushiRouter), totalOhmToSwap), 'approve failed');
        uint[] memory calculatedAmounts = sushiRouter.getAmountsOut(totalOhmToSwap, sushiRouterPath);
        uint[] memory amounts = sushiRouter.swapExactTokensForTokens(totalOhmToSwap, calculatedAmounts[1] * (1000 - maxSwapSlippagePercent)/1000, sushiRouterPath, address(this), block.timestamp);
        
        for(uint256 i = 0; i < depositInfo.length; i++) {
            if(block.timestamp >= depositInfo[i].lastUpkeepTimestamp + depositInfo[i].paymentInterval) {
                DepositInfo storage currentDeposit = depositInfo[i];
                currentDeposit.unclaimedDai += amounts[1] * _getOutstandingYield(currentDeposit.principalAmount, currentDeposit.agnosticAmount) / totalOhm;
                currentDeposit.agnosticAmount = _toAgnostic(currentDeposit.principalAmount);

                if(currentDeposit.unclaimedDai >= currentDeposit.userMinimumDaiThreshold) {
                    IERC20(DAI).safeTransfer(currentDeposit.recipient, currentDeposit.unclaimedDai);
                    currentDeposit.unclaimedDai = 0;
                }
            }
        }
    }

    /************************
    * Utility Functions
    ************************/

    /**
        @notice Calculate outstanding yield based on principal sOhm and agnostic gOhm amount
     */
    function _getOutstandingYield(uint256 principal, uint256 agnosticAmount) internal view returns (uint256) {
        return _fromAgnostic(agnosticAmount) - principal;
    }

    /**
        @notice Convert flat sOHM value to agnostic value(gOhm amount) at current index
        @dev Agnostic value earns rebases. Agnostic value is amount / rebase_index.
             1e18 is because gOhm has 18 decimals.
     */
    function _toAgnostic(uint256 amount_) internal view returns ( uint256 ) {
        return amount_
            * 1e9
            / (IsOHM(sOHM).index());
    }

    /**
        @notice Convert agnostic value(gOhm amount) at current index to flat sOHM value
        @dev Agnostic value earns rebases. Agnostic value is amount / rebase_index.
             1e18 is because gOHM has 18 decimals.
     */
    function _fromAgnostic(uint256 amount_) internal view returns ( uint256 ) {
        return amount_
            * (IsOHM(sOHM).index())
            / 1e18;
    }

    /**
        @notice Convert flat sOHM value to agnostic value(gOhm amount) at a given index value
        @dev Agnostic value earns rebases. Agnostic value is amount / rebase_index.
             1e18 is because gOHM has 18 decimals.
     */
    function _fromAgnosticAtIndex(uint256 amount_, uint256 index_) internal pure returns ( uint256 ) { //NOT NEED REMOVE THIS
        return amount_
            * index_
            / 1e18;
    }

    /************************
    * Setter Functions
    ************************/

    /**
        @notice Setter for maxSwapSlippagePercent.
        @param slippagePercent_ new slippage value as a fraction / 1000.
    */
    function setMaxSwapSlippagePercent(uint256 slippagePercent_) external onlyGovernor {
        maxSwapSlippagePercent = slippagePercent_;
    }

    /**
        @notice Setter for feeToDaoPercent.
        @param feePercent_ new fee value as a fraction / 1000.
    */
    function setFeeToDaoPercent(uint256 feePercent_) external onlyGovernor {
        feeToDaoPercent = feePercent_;
    }

    /**
        @notice Setter for minimumDaiThreshold.
        @param minDaiThreshold_ new minimumDaiThreshold value.
    */
    function setMinimumDaiThreshold(uint256 minDaiThreshold_) external onlyGovernor {
        minimumDaiThreshold = minDaiThreshold_;
    }

    /************************
    * Emergency Functions
    ************************/

    function emergencyShutdown(bool active_) external onlyGovernor {
        depositDisabled = active_;
        withdrawDisabled = active_;
        upkeepDisabled = active_;
        emit EmergencyShutdown(active_);
    }

    function disableDeposits(bool active_) external onlyGovernor {
        depositDisabled = active_;
    }

    function disableWithdrawals(bool active_) external onlyGovernor {
        withdrawDisabled = active_;
    }

    function disableUpkeep(bool active_) external onlyGovernor {
        upkeepDisabled = active_;
    }
}
