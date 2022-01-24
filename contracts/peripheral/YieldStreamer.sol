// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.10;

import {IERC20} from "../interfaces/IERC20.sol";
import {IsOHM} from "../interfaces/IsOHM.sol";
import {IgOHM} from "../interfaces/IgOHM.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {IYieldStreamer} from "../interfaces/IYieldStreamer.sol";
import {OlympusAccessControlled, IOlympusAuthority} from "../types/OlympusAccessControlled.sol";
import {IUniswapV2Router} from "../interfaces/IUniswapV2Router.sol";
import {IStaking} from "../interfaces/IStaking.sol";
import {YieldSplitter} from "../peripheral/YieldSplitter.sol";

/**
    @title YieldStreamer
    @notice This contract allows users to deposit their gOhm and have their yield
            converted into DAI and sent to their address every interval.
 */
contract YieldStreamer is IYieldStreamer, YieldSplitter {
    using SafeERC20 for IERC20;

    address public immutable OHM; //use the interface wrapper for consistency
    address public immutable DAI;
    address public immutable sOHM;
    IUniswapV2Router public immutable sushiRouter;
    address[] public sushiRouterPath = new address[](2);
    IStaking public immutable staking;

    bool public depositDisabled;
    bool public withdrawDisabled;
    bool public upkeepDisabled;

    uint256 public maxSwapSlippagePercent; // as fraction / 1000
    uint256 public feeToDaoPercent; // as fraction /1000
    uint256 public minimumDaiThreshold;

    struct UpKeeptInfo {
        uint256 id;
        uint256 lastUpkeepTimestamp;
        uint256 paymentInterval; // Time before yield is able to be swapped to DAI
        uint256 unclaimedDai;
        uint256 userMinimumDaiThreshold;
    }

    mapping(uint256 => DepositInfo) public upkeepInfo; // depositId -> UpkeepInfo
    uint256[] public activeDepositIds; // All deposit ids that are not empty or deleted

    event Deposited(address indexed depositor_, uint256 amount_);
    event Withdrawn(address indexed depositor_, uint256 amount_);
    event UpkeepComplete(uint256 indexed timestamp);
    event EmergencyShutdown(bool active_);

    /**
        @notice Constructor
        @param gOHM_ Address of gOHM.
        @param sOHM_ Address of SOHM.
        @param OHM_ Address of OHM.
        @param DAI_ Address of DAO.
        @param sushiRouter_ Address of sushiswap router.
        @param staking_ Address of sOHM staking contract.
        @param authority_ Address of Olympus authority contract.
        @param maxSwapSlippagePercent_ Maximum acceptable slippage when swapping OHM to DAI as fraction / 1000.
        @param feeToDaoPercent_ How much of yield goes to DAO before swapping to DAI as fraction / 1000.
        @param minimumDaiThreshold_ Minimum a user can set threshold for amount of DAI accumulated as yield before sending to recipient's wallet.
    */
    constructor(
        address gOHM_,
        address sOHM_,
        address OHM_,
        address DAI_,
        address sushiRouter_,
        address staking_,
        address authority_,
        uint256 maxSwapSlippagePercent_,
        uint256 feeToDaoPercent_,
        uint256 minimumDaiThreshold_
    ) YieldSplitter(gOHM_, authority_) {
        require(sOHM_ != address(0), "Invalid address for sOHM");
        sOHM = sOHM_;
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
        @notice Deposit gOHM, creates a deposit in the active deposit pool to be unkept.
        @param amount_ Amount of gOHM.
        @param recipient_ Address to direct staking yield and vault shares to.
        @param paymentInterval_ How much time must elapse before yield is able to be swapped for DAI.
    */
    function deposit(
        uint256 amount_,
        address recipient_,
        uint256 paymentInterval_,
        uint256 userMinimumDaiThreshold_
    ) external override {
        require(!depositDisabled, "Deposits currently disabled");
        require(amount_ > 0, "Invalid deposit amount");
        require(userMinimumDaiThreshold_ >= minimumDaiThreshold, "minimumDaiThreshold too low");

        IERC20(gOHM).safeTransferFrom(msg.sender, address(this), amount_);

        uint256 depositId = _deposit(msg.sender, recipient_, amount_);

        upkeepInfo[depositId] = UpKeeptInfo({
            id: idCount,
            lastUpkeepTimestamp: block.timestamp,
            paymentInterval: paymentInterval_,
            unclaimedDai: 0,
            userMinimumDaiThreshold: userMinimumDaiThreshold_
        });

        emit Deposited(msg.sender, amount_);
    }

    /**
        @notice Add more gOHM to your principal deposit.
        @param id_ Id of the deposit.
        @param amount_ Amount of sOHM to withdraw.
    */
    function addToDeposit(uint256 id_, uint256 amount_) external override {
        require(!depositDisabled, "Deposits currently disabled");
        require(depositInfo[id_].depositor == msg.sender, "Deposit is not yours");

        IERC20(gOHM).safeTransferFrom(msg.sender, address(this), amount_);
        
        _addToDeposit(id_, amount_);

        emit Deposited(msg.sender, amount_);
    }

    /**
        @notice Withdraw part of the principal amount deposited.
        @dev Does not allow all the principal to be withdrawn. If you would like to do that use withdrawAll(). Reason is because we want to delete the element in the active deposits array after withdrawing all the principal.
        @param id_ Id of the deposit.
        @param amount_ Amount of gOHM to withdraw.
    */
    function withdrawPrincipal(uint256 id_, uint256 amount_) external override {
        require(!withdrawDisabled, "Withdraws currently disabled");

        DepositInfo storage userDeposit = depositInfo[id_];
        require(userDeposit.depositor == msg.sender, "Deposit is not yours");
        require(amount_ < IgOHM(gOHM).balanceTo(userDeposit.principalAmount), "input >= principal");

        _withdrawPrincipal(id_, amount_);

        IERC20(gOHM).safeTransfer(msg.sender, amount_);

        emit Withdrawn(msg.sender, amount_);
    }

    /**
        @notice Withdraw excess yield from your deposit in gOHM.
        @dev  Use withdrawYieldAsDai() to withdraw yield as DAI.
        @param id_ Id of the deposit.
    */
    function withdrawYield(uint256 id_) external override {
        require(!withdrawDisabled, "Withdraws currently disabled");

        DepositInfo storage userDeposit = depositInfo[id_];
        require(userDeposit.depositor == msg.sender || userDeposit.recipient == msg.sender, "Deposit is not yours");

        upkeepInfo[id_].lastUpkeepTimestamp = block.timestamp;

        uint256 yield = _redeemYield(id_);

        IERC20(gOHM).safeTransfer(msg.sender, yield);
    }

    /**
        @notice Withdraw excess yield from your deposit in DAI
        @param id_ Id of the deposit
    */
    function withdrawYieldAsDai(uint256 id_) external override {
        require(!withdrawDisabled, "Withdraws currently disabled");
        require(depositInfo[id_].depositor == msg.sender || depositInfo[id_].recipient == msg.sender, "Deposit is not yours");

        upkeepInfo[id_].lastUpkeepTimestamp = block.timestamp;

        uint256 gOHMYield = _redeemYield(id_);
        uint256 totalOhmToSwap = staking.unwrap(address(this), gOHMYield);
        staking.unstake(address(this), totalOhmToSwap, false, false);

        require(IERC20(OHM).approve(address(sushiRouter), totalOhmToSwap), "approve failed");
        uint256[] memory calculatedAmounts = sushiRouter.getAmountsOut(totalOhmToSwap, sushiRouterPath);
        uint256[] memory amounts = sushiRouter.swapExactTokensForTokens(
            totalOhmToSwap,
            (calculatedAmounts[1] * (1000 - maxSwapSlippagePercent)) / 1000,
            sushiRouterPath,
            msg.sender,
            block.timestamp
        );

        uint256 daiToSend = upkeepInfo[id_].unclaimedDai + amounts[1];
        upkeepInfo[id_].unclaimedDai = 0;
        IERC20(DAI).safeTransfer(msg.sender, daiToSend);
    }

    /**
        @notice harvest all your unclaimed Dai
        @param id_ Id of the deposit
    */
    function harvestDai(uint256 id_) external override {
        require(!withdrawDisabled, "Withdraws currently disabled");

        DepositInfo storage userDeposit = depositInfo[id_];
        require(userDeposit.depositor == msg.sender || userDeposit.recipient == msg.sender, "Deposit is not yours");

        uint256 daiToSend = upkeepInfo[id_].unclaimedDai;
        upkeepInfo[id_].unclaimedDai = 0;
        IERC20(DAI).safeTransfer(msg.sender, daiToSend);
    }

    /**
        @notice Withdraw all gOHM from deposit. Includes both principal, yield and unclaimed DAI. Closes your deposit.
        @param id_ Id of the deposit
    */
    function withdrawAll(uint256 id_) external override {
        require(!withdrawDisabled, "Withdraws currently disabled");
        require(depositInfo[id_].depositor == msg.sender, "Deposit is not yours");

        (, uint256 totalGOHM) = _closeDeposit(id_);
        uint256 totalDai = upkeepInfo[id_].unclaimedDai;

        for (uint256 i = 0; i < activeDepositIds.length; i++) {
            // Remove id_ from activeDepositIds
            if (activeDepositIds[i] == id_) {
                activeDepositIds[i] = activeDepositIds[activeDepositIds.length - 1]; // Delete integer from array by swapping with last element and calling pop()
                activeDepositIds.pop();
                break;
            }
        }

        IERC20(gOHM).safeTransfer(msg.sender, totalGOHM);
        if(totalDai != 0) {
            IERC20(DAI).safeTransfer(msg.sender, totalDai);
        }

        emit Withdrawn(msg.sender, totalGOHM);
    }

    /**
        @notice User updates the minimum amount of DAI threshold before upkeep sends DAI to recipients wallet
        @param id_ Id of the deposit
        @param threshold_ amount of DAI
    */
    function updateUserMinDaiThreshold(uint256 id_, uint256 threshold_) external override {
        require(threshold_ >= minimumDaiThreshold, "minimumDaiThreshold too low");
        require(depositInfo[id_].depositor == msg.sender, "Deposit is not yours");

        upkeepInfo[id_].userMinimumDaiThreshold = threshold_;
    }

    /**
        @notice User updates the minimum amount of time passes before the deposit is included in upkeep
        @param id_ Id of the deposit
        @param paymentInterval_ amount of time in seconds
    */
    function updatePaymentInterval(uint256 id_, uint256 paymentInterval_) external override {
        require(depositInfo[id_].depositor == msg.sender, "Deposit is not yours");

        upkeepInfo[id_].paymentInterval = paymentInterval_;
    }

    /**
        @notice Upkeeps all deposits if they are eligible to be upkept. Converts excess yield from gOHM to DAI. Sends the yield to recipient wallets if above user set threshold.
    */
    function upkeep() external override {
        uint256 totalGOHM;

        for (uint256 i = 0; i < activeDepositIds.length; i++) {
            uint256 currentId = activeDepositIds[i];

            if (_isUpKeepEligible(currentId)) {
                totalGOHM += getOutstandingYield(currentId);
                upkeepInfo[currentId].lastUpkeepTimestamp = block.timestamp;
            }
        }

        uint256 feeToDao = (totalGOHM * feeToDaoPercent) / 1000;
        IERC20(gOHM).safeTransfer(authority.governor(), feeToDao);

        uint256 totalOhmToSwap = staking.unwrap(address(this), totalGOHM - feeToDao);
        staking.unstake(address(this), totalOhmToSwap, false, false);

        require(IERC20(OHM).approve(address(sushiRouter), totalOhmToSwap), "approve failed");
        uint256[] memory calculatedAmounts = sushiRouter.getAmountsOut(totalOhmToSwap, sushiRouterPath);
        uint256[] memory amounts = sushiRouter.swapExactTokensForTokens(
            totalOhmToSwap,
            (calculatedAmounts[1] * (1000 - maxSwapSlippagePercent)) / 1000,
            sushiRouterPath,
            address(this),
            block.timestamp
        );

        for (uint256 i = 0; i < activeDepositIds.length; i++) { // TODO: Is there a more gas efficient way than looping through this again and checking same condition
            uint256 currentId = activeDepositIds[i];

            if (_isUpKeepEligible(currentId)) {
                upkeepInfo storage currentUpkeepInfo = upkeepInfo[currentId];

                currentUpkeepInfo.unclaimedDai +=
                    (amounts[1] * _redeemYield(currentId)) /
                    totalGOHM;

                if (currentUpkeepInfo.unclaimedDai >= currentUpkeepInfo.userMinimumDaiThreshold) {
                    uint256 daiToSend = currentUpkeepInfo.unclaimedDai;
                    currentUpkeepInfo.unclaimedDai = 0;
                    IERC20(DAI).safeTransfer(currentUpkeepInfo.recipient, daiToSend);
                }
            }
        }

        emit UpkeepComplete(block.timestamp);
    }

    /************************
     * View Functions
     ************************/

    /**
        @notice Gets the number of deposits eligible for upkeep and amount of ohm of yield available to swap.
        @return numberOfDepositsEligible : number of deposits eligible for upkeep.
        @return amountOfYieldToSwap : total amount of yield in gOHM ready to be swapped in next upkeep.
     */
    function upkeepEligibility() external view returns (uint256 numberOfDepositsEligible, uint256 amountOfYieldToSwap) {
        for (uint256 i = 0; i < activeDepositIds.length; i++) {
            if (_isUpKeepEligible(activeDepositIds[i])) {
                numberOfDepositsEligible++;
                amountOfYieldToSwap += getOutstandingYield(activeDepositIds[i]);
            }
        }
    }

    /**
        @notice Returns the outstanding yield of a deposit.
        @param id_ Id of the deposit.
     */
    function getOutstandingYield(uint256 id_) public view returns (uint256) {
        return _getOutstandingYield(depositInfo[id_].principalAmount, depositInfo[id_].agnosticAmount);
    }

    /**
        @notice Returns whether deposit id is eligible for upkeep
        @return bool
     */
    function _isUpKeepEligible(uint256 id_) public view returns (bool) {
        if (block.timestamp >= upkeepInfo[id_].lastUpkeepTimestamp + upkeepInfo[id_].paymentInterval) {
            return true;
        }
        return false;
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
