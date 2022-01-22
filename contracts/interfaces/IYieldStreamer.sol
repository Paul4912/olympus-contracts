// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.7.5;

interface IYieldStreamer {
    // Write Functions
    function deposit(
        uint256 amount_,
        address recipient_,
        uint256 paymentInterval_,
        uint256 userMinimumDaiThreshold_
    ) external;

    function addToDeposit(uint256 id_, uint256 amount_) external;

    function withdrawPrincipal(uint256 id_, uint256 amount_) external;

    function withdrawYield(uint256 id_) external;

    function withdrawYieldAsDai(uint256 id_) external;

    function harvestDai(uint256 id_) external;

    function withdrawAll(uint256 id_) external;

    function updateUserMinDaiThreshold(uint256 id_, uint256 threshold_) external;

    function updatePaymentInterval(uint256 id_, uint256 paymentInterval) external;

    function upkeep() external;

    // View Functions
    function upkeepEligibility() external view returns (uint256 numberOfDepositsEligible, uint256 amountOfYieldToSwap);

    function getOutstandingYield(uint256 id_) external view returns (uint256);
}
