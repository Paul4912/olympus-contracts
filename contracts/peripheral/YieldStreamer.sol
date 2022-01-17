// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.10;

import {IERC20} from "../interfaces/IERC20.sol";
import {IsOHM} from "../interfaces/IsOHM.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {IYieldStreamer} from "../interfaces/IYieldStreamer.sol";
import {OlympusAccessControlled, IOlympusAuthority} from "../types/OlympusAccessControlled.sol";
import {IUniswapV2Router} from "../interfaces/IUniswapV2Router.sol";
import {IStaking} from "../interfaces/IStaking.sol";

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
    address[] public sushiRouterPath = new address[](2);
    IStaking public immutable staking;

    bool public depositDisabled;
    bool public withdrawDisabled;
    bool public upkeepDisabled;

    uint256 public maxSwapSlippagePercent; // as fraction / 1000
    uint256 public feeToDaoPercent; // as fraction /1000
    uint256 public minimumDaiThreshold;

    struct DepositInfo {
        uint256 id;
        address depositor;
        address recipient;
        uint256 principalAmount; // Total amount of sOhm deposited as principal
        uint256 agnosticAmount; // Total amount deposited priced in gOhm
        uint256 lastUpkeepTimestamp;
        uint256 paymentInterval; // Time before yield is able to be swapped to DAI
        uint256 unclaimedDai;
        uint256 userMinimumDaiThreshold;
    }

    uint256 public idCount;
    mapping(uint256 => DepositInfo) public depositInfo; // depositId -> DepositInfo
    mapping(address => uint256[]) public userDepositIds; // address -> Array of the deposit id's deposited by user
    uint256[] public activeDepositIds; // All deposit ids that are not empty or deleted

    event Deposited(address indexed depositor_, uint256 amount_);
    event Withdrawn(address indexed depositor_, uint256 amount_);
    event UpkeepComplete(uint256 indexed timestamp);
    event EmergencyShutdown(bool active_);

    /**
        @notice Constructor
        @param sOhm_ Address of SOHM.
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
        @notice Deposit sOHM, creates a deposit in the active deposit pool to be unkept.
        @param amount_ Amount of sOHM.
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
        require(recipient_ != address(0), "Invalid recipient address");
        require(userMinimumDaiThreshold_ >= minimumDaiThreshold, "minimumDaiThreshold too low");

        IERC20(sOHM).safeTransferFrom(msg.sender, address(this), amount_);

        userDepositIds[msg.sender].push(idCount);
        activeDepositIds.push(idCount);

        depositInfo[idCount] = DepositInfo({
            id: idCount,
            depositor: msg.sender,
            recipient: recipient_,
            principalAmount: amount_,
            agnosticAmount: _toAgnostic(amount_),
            lastUpkeepTimestamp: block.timestamp,
            paymentInterval: paymentInterval_,
            unclaimedDai: 0,
            userMinimumDaiThreshold: userMinimumDaiThreshold_
        });

        idCount++;

        emit Deposited(msg.sender, amount_);
    }

    /**
        @notice Add more sOHM to your principal deposit.
        @param id_ Id of the deposit.
        @param amount_ Amount of sOHM to withdraw.
    */
    function addToDeposit(uint256 id_, uint256 amount_) external override {
        require(!depositDisabled, "Deposits currently disabled");
        require(amount_ > 0, "Invalid deposit amount");

        DepositInfo storage userDeposit = depositInfo[id_];
        require(userDeposit.depositor == msg.sender, "Deposit is not yours");

        IERC20(sOHM).safeTransferFrom(msg.sender, address(this), amount_);
        userDeposit.principalAmount += amount_;
        userDeposit.agnosticAmount += _toAgnostic(amount_);

        emit Deposited(msg.sender, amount_);
    }

    /**
        @notice Withdraw part of the principal amount deposited.
        @dev Does not allow all the principal to be withdrawn. If you would like to do that use withdrawAll(). Reason is because we want to delete the element in the active deposits array after withdrawing all the principal.
        @param id_ Id of the deposit.
        @param amount_ Amount of sOHM to withdraw.
    */
    function withdrawPrincipal(uint256 id_, uint256 amount_) external override {
        require(!withdrawDisabled, "Withdraws currently disabled");
        require(amount_ > 0, "Invalid withdraw amount");

        DepositInfo storage userDeposit = depositInfo[id_];
        require(userDeposit.depositor == msg.sender, "Deposit is not yours");
        require(amount_ < userDeposit.principalAmount, "input >= principal");

        userDeposit.principalAmount -= amount_;
        userDeposit.agnosticAmount -= _toAgnostic(amount_);
        IERC20(sOHM).safeTransfer(msg.sender, amount_);

        emit Withdrawn(msg.sender, amount_);
    }

    /**
        @notice Withdraw excess yield from your deposit in sOHM.
        @dev  Use withdrawYieldAsDai() to withdraw yield as DAI.
        @param id_ Id of the deposit.
    */
    function withdrawYield(uint256 id_) external override {
        require(!withdrawDisabled, "Withdraws currently disabled");

        DepositInfo storage userDeposit = depositInfo[id_];
        require(userDeposit.depositor == msg.sender || userDeposit.recipient == msg.sender, "Deposit is not yours");

        uint256 yield = _getOutstandingYield(userDeposit.principalAmount, userDeposit.agnosticAmount);
        userDeposit.lastUpkeepTimestamp = block.timestamp;
        userDeposit.agnosticAmount = _toAgnostic(userDeposit.principalAmount);
        IERC20(sOHM).safeTransfer(msg.sender, yield);
    }

    /**
        @notice Withdraw excess yield from your deposit in DAI
        @param id_ Id of the deposit
    */
    function withdrawYieldAsDai(uint256 id_) external override {
        require(!withdrawDisabled, "Withdraws currently disabled");

        DepositInfo storage userDeposit = depositInfo[id_];
        require(userDeposit.depositor == msg.sender || userDeposit.recipient == msg.sender, "Deposit is not yours");

        uint256 ohmYield = _getOutstandingYield(userDeposit.principalAmount, userDeposit.agnosticAmount);
        userDeposit.lastUpkeepTimestamp = block.timestamp;
        userDeposit.agnosticAmount = _toAgnostic(userDeposit.principalAmount);

        require(IERC20(OHM).approve(address(sushiRouter), ohmYield), "approve failed");
        uint256[] memory calculatedAmounts = sushiRouter.getAmountsOut(ohmYield, sushiRouterPath);
        uint256[] memory amounts = sushiRouter.swapExactTokensForTokens(
            ohmYield,
            (calculatedAmounts[1] * (1000 - maxSwapSlippagePercent)) / 1000,
            sushiRouterPath,
            msg.sender,
            block.timestamp
        );

        uint256 daiToSend = userDeposit.unclaimedDai + amounts[1];
        userDeposit.unclaimedDai = 0;
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

        uint256 daiToSend = userDeposit.unclaimedDai;
        userDeposit.unclaimedDai = 0;
        IERC20(DAI).safeTransfer(msg.sender, daiToSend);
    }

    /**
        @notice Withdraw all sOhm from deposit. Includes both principal and yield
        @param id_ Id of the deposit
    */
    function withdrawAll(uint256 id_) external override {
        require(!withdrawDisabled, "Withdraws currently disabled");

        DepositInfo memory userDeposit = depositInfo[id_]; // remove this more gas efficient? test later
        require(userDeposit.depositor == msg.sender, "Deposit is not yours");

        uint256 totalSOhm = _fromAgnostic(userDeposit.agnosticAmount);
        uint256 totalDai = userDeposit.unclaimedDai;

        delete depositInfo[id_];

        for (uint256 i = 0; i < activeDepositIds.length; i++) {
            // Remove id_ from activeDepositIds
            if (activeDepositIds[i] == id_) {
                activeDepositIds[i] = activeDepositIds[activeDepositIds.length - 1]; // Delete integer from array by swapping with last element and calling pop()
                activeDepositIds.pop();
                break;
            }
        }

        uint256[] storage userIndices = userDepositIds[msg.sender];
        for (uint256 i = 0; i < userIndices.length; i++) {
            // Remove id_ from donor's depositId array
            if (userIndices[i] == id_) {
                userIndices[i] = userIndices[userIndices.length - 1]; // Delete integer from array by swapping with last element and calling pop()
                userIndices.pop();
                break;
            }
        }

        IERC20(sOHM).safeTransfer(msg.sender, totalSOhm);
        IERC20(DAI).safeTransfer(msg.sender, totalDai);

        emit Withdrawn(msg.sender, totalSOhm);
    }

    /**
        @notice User updates the minimum amount of DAI threshold before upkeep sends DAI to recipients wallet
        @param id_ Id of the deposit
        @param threshold_ amount of DAI
    */
    function updateUserMinDaiThreshold(uint256 id_, uint256 threshold_) external override {
        require(threshold_ >= minimumDaiThreshold, "minimumDaiThreshold too low");

        DepositInfo storage userDeposit = depositInfo[id_];
        require(userDeposit.depositor == msg.sender, "Deposit is not yours");

        userDeposit.userMinimumDaiThreshold = threshold_;
    }

    /**
        @notice User updates the minimum amount of time passes before the deposit is included in upkeep
        @param id_ Id of the deposit
        @param paymentInterval_ amount of time in seconds
    */
    function updatePaymentInterval(uint256 id_, uint256 paymentInterval_) external override {
        DepositInfo storage userDeposit = depositInfo[id_];
        require(userDeposit.depositor == msg.sender, "Deposit is not yours");

        userDeposit.paymentInterval = paymentInterval_;
    }

    /**
        @notice Upkeeps all deposits if they are eligible to be upkept. Converts excess yield from sOHM to DAI. Sends the yield to recipient wallets if above user set threshold.
    */
    function upkeep() external override {
        uint256 totalOhm;

        for (uint256 i = 0; i < activeDepositIds.length; i++) {
            uint256 currentId = activeDepositIds[i];

            if (_isUpKeepEligible(currentId)) {
                DepositInfo storage currentDeposit = depositInfo[currentId];
                totalOhm += _getOutstandingYield(currentDeposit.principalAmount, currentDeposit.agnosticAmount);
                currentDeposit.lastUpkeepTimestamp = block.timestamp;
            }
        }

        uint256 feeToDao = (totalOhm * feeToDaoPercent) / 1000;
        IERC20(sOHM).safeTransfer(authority.governor(), feeToDao);
        uint256 totalOhmToSwap = totalOhm - feeToDao;
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

        for (uint256 i = 0; i < activeDepositIds.length; i++) {
            uint256 currentId = activeDepositIds[i];

            if (_isUpKeepEligible(currentId)) {
                DepositInfo storage currentDeposit = depositInfo[currentId];
                currentDeposit.unclaimedDai +=
                    (amounts[1] * _getOutstandingYield(currentDeposit.principalAmount, currentDeposit.agnosticAmount)) /
                    totalOhmToSwap;
                currentDeposit.agnosticAmount = _toAgnostic(currentDeposit.principalAmount);

                if (currentDeposit.unclaimedDai >= currentDeposit.userMinimumDaiThreshold) {
                    currentDeposit.unclaimedDai = 0;
                    IERC20(DAI).safeTransfer(currentDeposit.recipient, currentDeposit.unclaimedDai);
                }
            }
        }

        emit UpkeepComplete(block.timestamp);
    }

    /************************
     * View Functions
     ************************/

    /**
        @notice Returns number of deposits eligible for upkeep and amount of ohm of yield available to swap
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

    /************************
     * Internal Utility Functions
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
    function _toAgnostic(uint256 amount_) internal view returns (uint256) {
        return (amount_ * 1e18) / (IsOHM(sOHM).index());
    }

    /**
        @notice Convert agnostic value(gOhm amount) at current index to flat sOHM value
        @dev Agnostic value earns rebases. Agnostic value is amount / rebase_index.
             1e18 is because gOHM has 18 decimals.
     */
    function _fromAgnostic(uint256 amount_) internal view returns (uint256) {
        return (amount_ * (IsOHM(sOHM).index())) / 1e18;
    }

    /**
        @notice Returns whether deposit id is eligible for upkeep
        @return bool
     */
    function _isUpKeepEligible(uint256 id_) internal view returns (bool) {
        if (block.timestamp >= depositInfo[id_].lastUpkeepTimestamp + depositInfo[id_].paymentInterval) {
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
