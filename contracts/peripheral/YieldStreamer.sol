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
    uint256 public feeToDaoPercent; // as fraction /1000
    uint256 public minimumDaiThreshold; //MAKE SETTERS FOR ALL THESE

    struct DepositInfo {
        uint256 id; // Equal to index in array
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

        depositIndices[msg.sender].push(depositInfo.length);

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
        @dev Does not allow all the principal to be withdrawn. If you would like to do that use withdrawAll(). Reason is because we want to delete the element in the array after withdrawing all the principal.
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

        require(IERC20(OHM).approve(address(sushiRouter), ohmYield), 'approve failed');
        uint[] memory calculatedAmounts = sushiRouter.getAmountsOut(ohmYield, sushiRouterPath);
        uint[] memory amounts = sushiRouter.swapExactTokensForTokens(ohmYield, calculatedAmounts[1] * (1000 - maxSwapSlippagePercent)/1000, sushiRouterPath, address(this), block.timestamp);
        
        IERC20(DAI).safeTransfer(msg.sender, amounts[1]);
    }

    /**
        @notice Withdraw all sOhm from deposit. Includes both principal and yield
        @dev  withdrawAll() may change the id of an existing deposit. Frontend should handle this by finding the correct Id before performing any write actions.
        @param id_ Id of the deposit
    */
    function withdrawAll(uint256 id_) external override {
        require(!withdrawDisabled, "Withdraws currently disabled");

        DepositInfo storage userDeposit = depositInfo[id_];
        require(userDeposit.depositor == msg.sender, "Deposit is not yours");

        uint256 totalSOhm = _fromAgnostic(userDeposit.agnosticAmount);

        // If element was in middle of array, bring last element to index we want to delete. Update its id appropriately.
        uint256 lastIndex = depositInfo.length - 1;
        if(id_ != lastIndex) {
            depositInfo[id_] = depositInfo[lastIndex]; // Move last element in array to the slot we want to delete
            depositInfo[id_].id = id_; // Update its id from length - 1 to whatever the existing id of this slot is.

            address lastIndexDepositor = depositInfo[lastIndex].depositor;
            uint256[] storage lastIndexDepositorIndices =  depositIndices[lastIndexDepositor];
            for (uint256 i = 0; i < lastIndexDepositorIndices.length; i++) {
                if(lastIndexDepositorIndices[i] == lastIndex) {
                    lastIndexDepositorIndices[i] = id_; // Update the lastindex's depositor's indices array to reflect its new id slot
                    break;
                }
            }
        }
        depositInfo.pop(); // Remove last element 

        uint256[] storage userIndices = depositIndices[msg.sender];
        for (uint256 i = 0; i < userIndices.length; i++) {
            if(userIndices[i] == id_) { // Delete the index in the user's indices array after withdrawal
                userIndices[i] = userIndices[userIndices.length - 1];
                userIndices.pop();
                break;
            }
        }
        

        IERC20(sOHM).safeTransfer(msg.sender, totalSOhm);

        emit Withdrawn(msg.sender, totalSOhm);
    }

    function updateUserMinDaiThreshold(uint id_, uint threshold_) external override {

    }

	function updatePaymentInterval(uint id_, uint paymentInterval) external override {

    }

    /**
        @notice Upkeeps all deposits if they are eligible to be upkept. Converts excess yield from sOHM to DAI. Sends the yield to recipient wallets if above user set threshold.
    */
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
        uint256 feeToDao = totalOhm * feeToDaoPercent / 1000;
        IERC20(sOHM).safeTransfer(authority.governor(), feeToDao);
        uint256 totalOhmToSwap = totalOhm - feeToDao;
        
        require(IERC20(OHM).approve(address(sushiRouter), totalOhmToSwap), 'approve failed');
        uint[] memory calculatedAmounts = sushiRouter.getAmountsOut(totalOhmToSwap, sushiRouterPath);
        uint[] memory amounts = sushiRouter.swapExactTokensForTokens(totalOhmToSwap, calculatedAmounts[1] * (1000 - maxSwapSlippagePercent)/1000, sushiRouterPath, address(this), block.timestamp);
        
        for(uint256 i = 0; i < depositInfo.length; i++) {
            if(block.timestamp >= depositInfo[i].lastUpkeepTimestamp + depositInfo[i].paymentInterval) {
                DepositInfo storage currentDeposit = depositInfo[i];
                currentDeposit.unclaimedDai += amounts[1] * _getOutstandingYield(currentDeposit.principalAmount, currentDeposit.agnosticAmount) / totalOhmToSwap;
                currentDeposit.agnosticAmount = _toAgnostic(currentDeposit.principalAmount);

                if(currentDeposit.unclaimedDai >= currentDeposit.userMinimumDaiThreshold) {
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

	function getDepositIdsByRecipient(address recipient_) external view returns (uint256[] memory) {

    }

    /**
        @notice Returns the outstanding yield of a deposit.
        @return number of deposits eligible for upkeep.
     */
	function upkeepEligibility() external view returns (uint256) {
        uint256 numberOfDepositsEligible;
        for(uint256 i = 0; i < depositInfo.length; i++) {
            if(block.timestamp >= depositInfo[i].lastUpkeepTimestamp + depositInfo[i].paymentInterval) {
                numberOfDepositsEligible++;
            }
        }
        return (numberOfDepositsEligible);
    }

    /**
        @notice Returns the outstanding yield of a deposit.
        @param id_ Id of the deposit.
     */
	function getOutstandingYield(uint id_) external view returns (uint256) {
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
