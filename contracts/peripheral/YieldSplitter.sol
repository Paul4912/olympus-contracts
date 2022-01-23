// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.10;

import {IERC20} from "../interfaces/IERC20.sol";
import {IsOHM} from "../interfaces/IsOHM.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {IYieldSplitter} from "../interfaces/IYieldSplitter.sol";
import {OlympusAccessControlled, IOlympusAuthority} from "../types/OlympusAccessControlled.sol";

/**
    @title YieldSplitter
    @notice Abstract contract allows users to deposit their sOhm and have their yield
            claimable by the specified recipient party.
 */
abstract contract YieldSplitter is OlympusAccessControlled {
    using SafeERC20 for IERC20;

    address public immutable sOHM;

    struct DepositInfo {
        uint256 id;
        address depositor;
        address recipient;
        uint256 principalAmount; // Total amount of sOhm deposited as principal
        uint256 agnosticAmount; // Total amount deposited priced in gOhm
    }

    uint256 public idCount;
    mapping(uint256 => DepositInfo) public depositInfo; // depositId -> DepositInfo
    mapping(address => uint256[]) public depositorIds; // address -> Array of the deposit id's deposited by user
    mapping(address => uint256[]) public recipientIds; // address -> Array of the deposit id's user is recipient of

    /**
        @notice Constructor
        @param sOhm_ Address of SOHM.
        @param authority_ Address of Olympus authority contract.
    */
    constructor(
        address sOhm_,
        address authority_
    ) OlympusAccessControlled(IOlympusAuthority(authority_)) {
        require(sOhm_ != address(0), "Invalid address for sOHM");
        sOHM = sOhm_;
    }

    /**
        @notice Create a deposit.
        @param depositor_ Address of depositor
        @param amount_ Amount of sOHM.
        @param recipient_ Address to direct staking yield to.
    */
    function _deposit(
        address depositor_,
        address recipient_,
        uint256 amount_
    ) internal returns (uint256 depositId) {
        depositorIds[depositor_].push(idCount);
        recipientIds[recipient_].push(idCount);

        depositInfo[idCount] = DepositInfo({
            id: idCount,
            depositor: depositor_,
            recipient: recipient_,
            principalAmount: amount_,
            agnosticAmount: _toAgnostic(amount_)
        });

        depositId = idCount;
        idCount++;
    }

    /**
        @notice Add more sOHM to the depositor's principal deposit.
        @param id_ Id of the deposit.
        @param amount_ Amount of sOHM to withdraw.
    */
    function _addToDeposit(
        uint256 id_, 
        uint256 amount_
    ) internal {
        DepositInfo storage userDeposit = depositInfo[id_];
        userDeposit.principalAmount += amount_;
        userDeposit.agnosticAmount += _toAgnostic(amount_);
    }

    /**
        @notice Withdraw part of the principal amount deposited.
        @dev Does not allow all the principal to be withdrawn. If you would like to do that use withdrawAll(). Reason is because we want to delete the element in the active deposits array after withdrawing all the principal.
        @param id_ Id of the deposit.
        @param amount_ Amount of sOHM to withdraw.
    */
    function _withdrawPrincipal(uint256 id_, uint256 amount_) internal {
        DepositInfo storage userDeposit = depositInfo[id_];
        require(amount_ <= userDeposit.principalAmount, "amount greater than principal");

        userDeposit.principalAmount -= amount_;
        userDeposit.agnosticAmount -= _toAgnostic(amount_);
    }

    /**
        @notice Redeem excess yield from your deposit in sOHM.
        @param id_ Id of the deposit.
    */
    function _redeemYield(uint256 id_) internal returns (uint256 amountRedeemed) {
        DepositInfo storage userDeposit = depositInfo[id_];

        userDeposit.agnosticAmount = _toAgnostic(userDeposit.principalAmount);
        amountRedeemed = _getOutstandingYield(userDeposit.principalAmount, userDeposit.agnosticAmount);
    }

    /**
        @notice Redeem all excess yield from your all deposits recipient can redeem from.
    */
    function _redeemAllYield(address recipient_) internal returns (uint256 amountRedeemed) {
        uint256[] storage recipientIdsArray = recipientIds[recipient_]; // Could probably optimise for gas. TODO later.

        for (uint256 i = 0; i < recipientIdsArray.length; i++) {
            DepositInfo storage currentDeposit = depositInfo[recipientIdsArray[i]];
            amountRedeemed += _getOutstandingYield(currentDeposit.principalAmount, currentDeposit.agnosticAmount);
            currentDeposit.agnosticAmount = _toAgnostic(currentDeposit.principalAmount);
        }
    }

    /**
        @notice Withdraw all principal deposit, returns principal and agnostic amounts.
        @param id_ Id of the deposit.
    */
    function _closeDeposit(uint256 id_) internal returns (uint256 principal, uint256 agnosticAmount) {
        principal = depositInfo[id_].principalAmount;
        agnosticAmount = depositInfo[id_].agnosticAmount;

        uint256[] storage depositorIdsArray = depositorIds[depositInfo[id_].depositor];
        for (uint256 i = 0; i < depositorIdsArray.length; i++) {
            if (depositorIdsArray[i] == id_) { // Remove id from depositor's ids array
                depositorIdsArray[i] = depositorIdsArray[depositorIdsArray.length - 1]; // Delete integer from array by swapping with last element and calling pop()
                depositorIdsArray.pop();
                break;
            }
        }

        uint256[] storage recipientIdsArray = depositorIds[depositInfo[id_].recipient];
        for (uint256 i = 0; i < recipientIdsArray.length; i++) {
            if (recipientIdsArray[i] == id_) { // Remove id from depositor's ids array
                recipientIdsArray[i] = recipientIdsArray[recipientIdsArray.length - 1]; // Delete integer from array by swapping with last element and calling pop()
                recipientIdsArray.pop();
                break;
            }
        }

        delete depositInfo[id_];
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
}
