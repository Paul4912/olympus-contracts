interface IRouterV2 {

    // ======================= deposit stable ======================= //

    function depositStable(uint256 _amount) external returns (address);

    function depositStable(address _operator, uint256 _amount)
        external
        returns (address);

    function initDepositStable(uint256 _amount) external returns (address);

    function finishDepositStable(address _operation) external;

    // ======================= redeem stable ======================= //

    function redeemStable(uint256 _amount) external returns (address);

    function redeemStable(address _operator, uint256 _amount)
        external
        returns (address);

    function initRedeemStable(uint256 _amount) external returns (address);

    function finishRedeemStable(address _operation) external;
}