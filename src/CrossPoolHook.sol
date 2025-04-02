// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/**
 * @title CrossPoolHook
 * @notice A hook for cross-pool operations on Uniswap v4
 * @dev This hook listens for swaps in one pool and triggers actions in another pool
 */
contract CrossPoolHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using SafeCast for int256;

    // Maps a source pool to its corresponding target pool for cross-pool operations
    mapping(PoolId => PoolKey) public crossPoolLinks;
    
    // Stores amount thresholds for triggering cross-pool actions
    mapping(PoolId => uint256) public thresholds;
    
    // Tracks when the last cross-pool action was executed
    mapping(PoolId => uint256) public lastActionTimestamp;
    
    // Cooldown period between cross-pool actions (to prevent excessive operations)
    uint256 public constant COOLDOWN_PERIOD = 60; // 60 seconds
    
    // Events
    event CrossPoolActionExecuted(PoolId indexed sourcePoolId, PoolId indexed targetPoolId, int256 amountIn, int256 amountOut);
    event CrossPoolLinkCreated(PoolId indexed sourcePoolId, PoolId indexed targetPoolId, uint256 threshold);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @notice Set up a link between two pools for cross-pool operations
     * @param sourceKey The source pool that will trigger actions
     * @param targetKey The target pool where actions will be executed
     * @param threshold Minimum swap amount to trigger a cross-pool action
     */
    function createCrossPoolLink(PoolKey calldata sourceKey, PoolKey calldata targetKey, uint256 threshold) external {
        PoolId sourcePoolId = sourceKey.toId();
        PoolId targetPoolId = targetKey.toId();
        
        // Store the cross-pool relationship
        crossPoolLinks[sourcePoolId] = targetKey;
        thresholds[sourcePoolId] = threshold;
        
        emit CrossPoolLinkCreated(sourcePoolId, targetPoolId, threshold);
    }

    /**
     * @notice Returns permission flags for the hook
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
     * @notice Execute a swap in the target pool after a swap in the source pool
     * @dev This function is called automatically after a swap in the source pool
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId sourcePoolId = key.toId();
        PoolKey storage targetKey = crossPoolLinks[sourcePoolId];
        
        // Check if this pool has a cross-pool link configured
        if (targetKey.currency0.toId() == 0) {
            return (BaseHook.afterSwap.selector, 0);
        }
        
        // Get absolute swap amount
        uint256 swapAmount;
        if (params.zeroForOne) {
            int256 amount0 = int256(delta.amount0());
            swapAmount = amount0 < 0 ? uint256(-amount0) : uint256(amount0);
        } else {
            int256 amount1 = int256(delta.amount1());
            swapAmount = amount1 < 0 ? uint256(-amount1) : uint256(amount1);
        }
        
        // Check if the swap amount exceeds the threshold and cooldown period has passed
        if (swapAmount >= thresholds[sourcePoolId] && 
            block.timestamp >= lastActionTimestamp[sourcePoolId] + COOLDOWN_PERIOD) {
            
            // Update last action timestamp
            lastActionTimestamp[sourcePoolId] = block.timestamp;
            
            // Execute cross-pool action
            _executeCrossPoolAction(sender, key, targetKey, params, delta);
        }
        
        // Settle once more before returning
        poolManager.settle();
        
        return (BaseHook.afterSwap.selector, 0);
    }
    
    /**
     * @notice Execute a cross-pool action
     * @dev This is an internal function that contains the cross-pool strategy logic
     */
    function _executeCrossPoolAction(
        address sender,
        PoolKey calldata sourceKey,
        PoolKey memory targetKey,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta
    ) internal {
        // Settle all currencies before we start (clean slate)
        poolManager.settle();
        
        // Determine swap parameters and get currencies
        bool targetZeroForOne = _determineTargetSwapDirection(sourceKey, targetKey, params.zeroForOne);
        int256 targetSwapAmount = _calculateTargetSwapAmount(sourceKey, targetKey, params, delta);
        
        // Create swap params
        IPoolManager.SwapParams memory targetParams = IPoolManager.SwapParams({
            zeroForOne: targetZeroForOne,
            amountSpecified: targetSwapAmount,
            sqrtPriceLimitX96: targetZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        
        // Get currencies
        Currency inputCurrency = targetZeroForOne ? targetKey.currency0 : targetKey.currency1;
        Currency outputCurrency = targetZeroForOne ? targetKey.currency1 : targetKey.currency0;
        
        if (targetSwapAmount < 0) {
            uint256 inputAmount = uint256(-targetSwapAmount);
            bool takenFromOriginal = false;
            
            // Take tokens for the cross-pool swap
            if (params.zeroForOne && outputCurrency == sourceKey.currency1) {
                poolManager.take(sourceKey.currency1, address(this), inputAmount);
                takenFromOriginal = true;
            } else if (!params.zeroForOne && outputCurrency == sourceKey.currency0) {
                poolManager.take(sourceKey.currency0, address(this), inputAmount);
                takenFromOriginal = true;
            }
            
            if (!takenFromOriginal) {
                // Settle and return if we can't source tokens
                poolManager.settle();
                return;
            }
        }
        
        // Settle after taking tokens
        poolManager.settle();
        
        // Execute the swap
        try poolManager.swap(targetKey, targetParams, "") returns (BalanceDelta targetDelta) {
            // Calculate output amount
            int256 outputAmount = targetZeroForOne ? targetDelta.amount1() : targetDelta.amount0();
            
            // Take output tokens and send to sender
            if (outputAmount > 0) {
                poolManager.take(outputCurrency, sender, uint256(outputAmount));
                // Settle after taking tokens
                poolManager.settle();
            }
            
            // Final settle to ensure all currencies are settled
            poolManager.settle();
            
            emit CrossPoolActionExecuted(
                sourceKey.toId(),
                targetKey.toId(),
                targetSwapAmount,
                outputAmount
            );
        } catch (bytes memory) {
            // Settle on error
            poolManager.settle();
        }
        
        // Final settle outside try/catch
        poolManager.settle();
        
        // Additional settle call to ensure everything is clean
        poolManager.settle();
    }
    
    /**
     * @notice Determine the swap direction for the target pool
     * @dev This logic will depend on your specific cross-pool strategy
     */
    function _determineTargetSwapDirection(
        PoolKey calldata sourceKey,
        PoolKey memory targetKey,
        bool sourceZeroForOne
    ) internal pure returns (bool) {
        // Check if the target pool shares a token with the source pool
        if (sourceKey.currency0 == targetKey.currency0 || sourceKey.currency0 == targetKey.currency1) {
            // If token0 of source is in target pool
            if (sourceZeroForOne) {
                // Selling token0 in source, should sell the same token in target
                return sourceKey.currency0 == targetKey.currency0;
            } else {
                // Buying token0 in source, should buy the same token in target
                return !(sourceKey.currency0 == targetKey.currency0);
            }
        } else if (sourceKey.currency1 == targetKey.currency0 || sourceKey.currency1 == targetKey.currency1) {
            // If token1 of source is in target pool
            if (sourceZeroForOne) {
                // Selling token0 in source (buying token1), should buy the same token in target
                return !(sourceKey.currency1 == targetKey.currency0);
            } else {
                // Buying token0 in source (selling token1), should sell the same token in target
                return sourceKey.currency1 == targetKey.currency0;
            }
        }
        
        // If no shared tokens, default to true
        return true;
    }
    
    /**
     * @notice Calculate the swap amount for the target pool
     * @dev This logic will depend on your specific cross-pool strategy
     */
    function _calculateTargetSwapAmount(
        PoolKey calldata /* sourceKey */,
        PoolKey memory /* targetKey */,
        IPoolManager.SwapParams calldata sourceParams,
        BalanceDelta sourceDelta
    ) internal pure returns (int256) {
        // This is where you would implement your specific cross-pool strategy
        
        // Example: Use a percentage of the source swap amount
        uint256 swapPercentage = 50; // 50% of the source swap
        
        int256 sourceAmount;
        if (sourceParams.zeroForOne) {
            sourceAmount = int256(sourceDelta.amount0());
        } else {
            sourceAmount = int256(sourceDelta.amount1());
        }
        
        // Take the absolute value, calculate percentage, then apply sign
        uint256 absAmount = sourceAmount < 0 ? uint256(-sourceAmount) : uint256(sourceAmount);
        uint256 targetAmount = (absAmount * swapPercentage) / 100;
        
        // Always use exact input in this example (negative value)
        return -int256(targetAmount);
    }
    
    /**
     * @notice Handle returns from afterSwap
     */
    function afterSwapReturnDelta(
        address /* sender */,
        PoolKey calldata /* key */,
        IPoolManager.SwapParams calldata /* params */,
        BalanceDelta /* delta */,
        bytes calldata /* hookData */
    ) external view returns (int128) {
        // Ensure this is only called by the pool manager
        require(msg.sender == address(poolManager), "Only callable by pool manager");
        
        return 0; // No protocol fee taken
    }
}