pragma solidity ^0.8.10;

import "./interfaces/USTRouter.sol";
import "../types/BaseAllocator.sol";

error LUSDAllocator_InputTooLarge();
error LUSDAllocator_TreasuryAddressZero();

/**
 *  Contract deploys LUSD from treasury into the liquity stabilty pool. Each update, rewards are harvested.
 *  The allocator stakes the LQTY rewards and sells part of the ETH rewards to stack more LUSD.
 *  This contract inherits BaseAllocator is and meant to be used with Treasury extender.
 */
contract USTAllocator is BaseAllocator {
    using SafeERC20 for IERC20;

    /* ======== STATE VARIABLES ======== */
    address public treasuryAddress;
    address public immutable aUST = 0xa8De3e3c934e2A1BB08B010104CcaBBD4D6293ab;
    IRouterV2 public immutable ustRouterProxy = IRouterV2(0xcEF9E167d3f8806771e9bac1d4a0d568c39a9388);

    /**
     * @notice tokens in AllocatorInitData should be [UST Address]
     * UST Address (0xa47c8bf37f92aBed4A126BDA807A7b7498661acD)
     */
    constructor(
        AllocatorInitData memory data,
        address _treasuryAddress
    ) BaseAllocator(data) {
        treasuryAddress = _treasuryAddress;
        data.tokens[0].safeApprove(address(ustRouterProxy), type(uint256).max);
        IERC20(aUST).safeApprove(address(ustRouterProxy), type(uint256).max);
    }

    /**
     *  @notice Need this because StabilityPool::withdrawFromSP() and LQTYStaking::stake() will send ETH here
     */
    receive() external payable {}

    /* ======== CONFIGURE FUNCTIONS for Guardian only ======== */

    /**
     *  @notice Updates address of treasury to authority.vault()
     */
    function updateTreasury() public {
        _onlyGuardian();
        if (authority.vault() == address(0)) revert LUSDAllocator_TreasuryAddressZero();
        treasuryAddress = address(authority.vault());
    }

    /* ======== INTERNAL FUNCTIONS ======== */

    /**
     *  @notice 
     */
    function _update(uint256 id) internal override returns (uint128 gain, uint128 loss) {
        if (getETHRewards() > 0 || getLQTYRewards() > 0) {
            // 1.  Harvest from LUSD StabilityPool to get ETH+LQTY rewards
            lusdStabilityPool.withdrawFromSP(0); //Passing 0 b/c we don't want to withdraw from the pool but harvest - see https://discord.com/channels/700620821198143498/818895484956835912/908031137010581594
        }

        // 2.  Stake LQTY rewards from #1 and any other LQTY in wallet.
        uint256 balanceLqty = IERC20(lqtyTokenAddress).balanceOf(address(this));
        if (balanceLqty > 0) {
            lqtyStaking.stake(balanceLqty); //Stake LQTY, also receives any prior ETH+LUSD rewards from prior staking
        }

        // 3.  If we have eth, convert to weth, then swap a percentage of it to LUSD.
        uint256 ethBalance = address(this).balance; // Use total balance in case we have leftover from a prior failed attempt
        bool swappedLUSDSuccessfully;
        if (ethBalance > 0) {
            // Wrap ETH to WETH
            IWETH(wethAddress).deposit{value: ethBalance}();

            if (ethToLUSDRatio > 0) {
                uint256 wethBalance = IWETH(wethAddress).balanceOf(address(this)); //Base off of WETH balance in case we have leftover from a prior failed attempt
                uint256 amountWethToSwap = (wethBalance * ethToLUSDRatio) / FEE_PRECISION;
                uint256 amountLUSDMin = amountWethToSwap * minETHLUSDRate; //WETH and LUSD is 18 decimals

                // From https://docs.uniswap.org/protocol/guides/swaps/multihop-swaps#calling-the-function-1
                // Multiple pool swaps are encoded through bytes called a `path`. A path is a sequence of token addresses and poolFees that define the pools used in the swaps.
                // The format for pool encoding is (tokenIn, fee, tokenOut/tokenIn, fee, tokenOut) where tokenIn/tokenOut parameter is the shared token across the pools.
                // Since we are swapping WETH to DAI and then DAI to LUSD the path encoding is (WETH, 0.3%, DAI, 0.3%, LUSD).
                ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
                    path: abi.encodePacked(wethAddress, poolFee, hopTokenAddress, poolFee, address(_tokens[0])),
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountWethToSwap,
                    amountOutMinimum: amountLUSDMin
                });

                // Executes the swap
                if (swapRouter.exactInput(params) > 0) {
                    swappedLUSDSuccessfully = true;
                }
            }
        }

        // If swap was successful (or if percent to swap is 0), send the remaining WETH to the treasury.  Crucial check otherwise we'd send all our WETH to the treasury and not respect our desired percentage
        if (ethToLUSDRatio == 0 || swappedLUSDSuccessfully) {
            uint256 wethBalance = IWETH(wethAddress).balanceOf(address(this));
            if (wethBalance > 0) {
                IERC20(wethAddress).safeTransfer(treasuryAddress, wethBalance);
            }
        }

        // 4.  Deposit all LUSD in balance to into StabilityPool.
        uint256 lusdBalance = _tokens[0].balanceOf(address(this));
        if (lusdBalance > 0) {
            lusdStabilityPool.provideToSP(lusdBalance, address(0));

            uint128 total = uint128(lusdStabilityPool.getCompoundedLUSDDeposit(address(this)));
            uint128 last = extender.getAllocatorPerformance(id).gain + uint128(extender.getAllocatorAllocated(id));
            if (total >= last) gain = total - last;
            else loss = last - total;
        }
    }

    function deallocate(uint256[] memory amounts) public override {
        _onlyGuardian();
        if (amounts[0] > 0) lusdStabilityPool.withdrawFromSP(amounts[0]);
        if (amounts[1] > 0) lqtyStaking.unstake(amounts[1]);
    }

    function _deactivate(bool panic) internal override {
        if (panic) {
            // If panic unstake everything
            _withdrawEverything();
        }
    }

    function _prepareMigration() internal override {
        _withdrawEverything();

        // Could have leftover eth from unstaking unclaimed yield.
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            IWETH(wethAddress).deposit{value: ethBalance}();
        }

        // Don't need to transfer WETH since its a utility token it will be migrated
    }

    /**
     *  @notice Withdraws LUSD and LQTY from pools. This also may result in some ETH being sent to wallet due to unclaimed yield after withdrawing.
     */
    function _withdrawEverything() internal {
        // Will throw exception if nothing to unstake
        if (lqtyStaking.stakes(address(this)) > 0) {
            // If unstake amount > amount available to unstake will unstake everything. So max int ensures unstake max amount.
            lqtyStaking.unstake(type(uint256).max);
        }

        if (lusdStabilityPool.getCompoundedLUSDDeposit(address(this)) > 0) {
            lusdStabilityPool.withdrawFromSP(type(uint256).max);
        }
    }

    function _depositUST() internal {
        uint256 balance = IERC20(_tokens[0].balanceOf(address(this)));
        if(balance > 0) {
            address operation = ustRouterProxy.depositStable(balance);
            ustRouterProxy.finishDepositStable(operation);
        }
    }

    /* ======== VIEW FUNCTIONS ======== */

    function amountAllocated(uint256 id) public view override returns (uint256) {
        return lusdStabilityPool.getCompoundedLUSDDeposit(address(this));
    }

    function rewardTokens() public view override returns (IERC20[] memory) {
        IERC20[] memory empty = new IERC20[](0);
        return empty;
    }

    function utilityTokens() public view override returns (IERC20[] memory) {
        IERC20[] memory utility = new IERC20[](1);
        utility[0] = IERC20(aUST);
        return utility;
    }

    function name() external view override returns (string memory) {
        return "LUSD Allocator";
    }
}
