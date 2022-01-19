// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.7.5;

interface IYieldStreamer {
	// Write Functions
	function deposit(uint amount_, address recipient_, uint paymentInterval_, uint userMinimumDaiThreshold_) external;
	function addToDeposit(uint id_, uint amount_) external;
	function withdrawPrincipal(uint id_, uint amount_) external;
	function withdrawYield(uint id_) external;
	function withdrawYieldAsDai(uint id_) external;
	function withdrawAll(uint id_) external;
	function updateUserMinDaiThreshold(uint id_, uint threshold_) external;
	function updatePaymentInterval(uint id_, uint paymentInterval) external;
	function upkeep() external;

    // View Functions
	function getDepositIdsByRecipient(address recipient_) external view returns (uint256[] memory);
	function upkeepEligibility() external view returns (uint256);
	function getOutstandingYield(uint id_) external view returns (uint256);
}