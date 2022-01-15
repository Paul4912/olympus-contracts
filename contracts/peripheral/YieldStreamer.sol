// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.10;

import {IERC20} from "../interfaces/IERC20.sol";
import {IsOHM} from "../interfaces/IsOHM.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {IYieldStreamer} from "../interfaces/IYieldStreamer.sol";
import {OlympusAccessControlled, IOlympusAuthority} from "../types/OlympusAccessControlled.sol";

/**
    @title YieldStreamer
    @notice This contract allows users to deposit their gOhm and have their yield
            converted into DAI and sent to their address every interval.
 */
contract YieldStreamer is IYieldStreamer, OlympusAccessControlled {
    using SafeERC20 for IERC20;

    address public immutable sOHM;

    struct DepositInfo {
        address depositor;
        address recipient;
        uint256 deposit; // Total non-agnostic amount deposited
        uint256 yield; // Amount of sOHM accumulated over on deposit/withdraw
        uint256 indexAtLastChange; // Index of last deposit/withdraw/update

        
    }

    constructor (address sOhm_, address authority_)
        OlympusAccessControlled(IOlympusAuthority(authority_))
    {
        require(sOhm_ != address(0), "Invalid address for sOHM");

        sOHM = sOhm_;
    }

    function deposit(uint amount_, address recipient_, uint paymentInterval_) external override {

    }

	function withdraw(uint amount_) external override {
        
    }

	function withdrawAll() external override {
        
    }

	function upkeep() external override {
        
    }
}
