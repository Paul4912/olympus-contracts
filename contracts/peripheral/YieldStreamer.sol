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
    IStaking public immutable staking;

    bool public depositDisabled;
    bool public withdrawDisabled;
    bool public upkeepDisabled;

    struct DepositInfo {
        uint256 id;
        address depositor;
        address recipient;
        uint256 principalAmount; // Total amount of sOhm deposited as principal
        uint256 agnosticAmount; // Total amount deposited in gOhm
        uint256 lastUpkeepTimestamp;
        uint256 paymentInterval; // Time before yield is able to be swapped to DAI
        uint256 unclaimedDai;
    }

    DepositInfo[] public depositInfo;

    mapping(address => uint256[]) public depositIndices;

    event Deposited(address indexed depositor_, uint256 amount_);
    event Withdrawn(address indexed depositor_, uint256 amount_);
    event UpkeepComplete(uint indexed timestamp);
    event EmergencyShutdown(bool active_);

    constructor (address sOhm_, address OHM_, address DAI_, address sushiRouter_, address staking_, address authority_)
        OlympusAccessControlled(IOlympusAuthority(authority_))
    {
        require(sOhm_ != address(0), "Invalid address for sOHM");
        sOHM = sOhm_;
        OHM = OHM_;
        DAI = DAI_;
        sushiRouter = IUniswapV2Router(sushiRouter_);
        staking = staking_;
    }

    /**
        @notice Deposit sOHM, records sender address and assign rebases to recipient
        @param amount_ Amount of sOHM
        @param recipient_ Address to direct staking yield and vault shares to
        @param paymentInterval_ how much time must elapse before yield is able to be swapped for DAI
    */
    function deposit(uint amount_, address recipient_, uint paymentInterval_) external override {
        require(!depositDisabled, "Deposits currently disabled");
        require(amount_ > 0, "Invalid deposit amount");
        require(recipient_ != address(0), "Invalid recipient address");

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
                unclaimedDai: 0
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
        uint256 totalSOhmToSwap = 0;
        address[] recipients;
        uint256[] recieveAmounts;

        for(uint256 i = 0; i < depositInfo.length; i++) {
            if(block.timestamp >= depositInfo[i].lastUpkeepTimestamp + depositInfo[i].paymentInterval)
            {
                DepositInfo storage currentDeposit = depositInfo[i];
                uint256 outStandingYield = _getOutstandingYield(currentDeposit.principalAmount, currentDeposit.agnosticAmount);
                recipients.push(currentDeposit.recipient);
                recieveAmounts.push(outStandingYield);
                totalSOhmToSwap += _getOutstandingYield(currentDeposit.principalAmount, currentDeposit.agnosticAmount);
                currentDeposit.agnosticAmount = _toAgnostic(currentDeposit.principalAmount);
                currentDeposit.lastUpkeepTimestamp = block.timestamp;
            }
        }

        staking.unstake(address(this), totalSOhmToSwap, false, false);
        
        //find price and slippage
        require(IERC20(OHM).approve(address(sushiRouter), totalSOhmToSwap), 'approve failed');
        uint[] amounts = sushiRouter.swapExactTokensForTokens(totalSOhmToSwap, amountOutMin, [OHM, DAI], address(this), block.timestamp);

        //distribute dai
        for(uint256 i = 0; i < recipients.length; i++) {
            //set 
            uint256 amountOfDai = recieveAmounts[i] * amounts[1] / totalSOhmToSwap;
            IERC20(DAI).safeTransfer(recipients[i], amountOfDai);
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
    function _fromAgnosticAtIndex(uint256 amount_, uint256 index_) internal pure returns ( uint256 ) {
        return amount_
            * index_
            / 1e18;
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
