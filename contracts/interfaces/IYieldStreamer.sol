// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.7.5;

interface IYieldStreamer {
	function deposit(uint amount_, address recipient_, uint paymentInterval_) external;
	function withdraw(uint amount_) external;
	function withdrawAll() external;
	function upkeep() external;
    // any view functions needed?
}