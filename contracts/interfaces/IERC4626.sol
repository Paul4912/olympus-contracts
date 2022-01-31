// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.10;

interface IERC4626 {
    function deposit(address to, uint256 value) external returns (uint256 shares);

    function mint(address to, uint256 shares) external returns (uint256 value);

    function withdraw(
        address from,
        address to,
        uint256 value
    ) external returns (uint256 shares);

    function redeem(
        address from,
        address to,
        uint256 shares
    ) external returns (uint256 value);

    function underlying() external view returns (address);

    function totalUnderlying() external view returns (uint256);

    function balanceOfUnderlying(address owner) external view returns (uint256);

    function exchangeRate() external view returns (uint256);

    function previewDeposit(uint256 underlyingAmount) external view returns (uint256 shareAmount);

    function previewMint(uint256 shareAmount) external view returns (uint256 underlyingAmount);

    function previewWithdraw(uint256 underlyingAmount) external view returns (uint256 shareAmount);

    function previewRedeem(uint256 shareAmount) external view returns (uint256 underlyingAmount);

    event Deposit(address indexed from, address indexed to, uint256 value);

    event Withdraw(address indexed from, address indexed to, uint256 value);
}
