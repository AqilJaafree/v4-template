// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/**
 * @title DynamicFeeHook
 * @notice Hook that adjusts LP fees based on market volatility
 * @dev This hook monitors market conditions and adjusts fees dynamically
 */
contract DynamicFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    // Fee tiers
    uint24 public constant BASE_FEE = 500;     // 0.05% base fee
    uint24 public constant LOW_FEE = 1000;     // 0.1% during low volatility
    uint24 public constant MID_FEE = 3000;     // 0.3% during medium volatility
    uint24 public constant HIGH_FEE = 10000;   // 1% during high volatility
    uint24 public constant EXTREME_FEE = 30000; // 3% during extreme volatility

    // Volatility thresholds (basis points = 1/100 of 1%)
    uint24 public constant LOW_VOLATILITY = 50;     // 0.5% price change
    uint24 public constant MID_VOLATILITY = 200;    // 2% price change
    uint24 public constant HIGH_VOLATILITY = 500;   // 5% price change 
    uint24 public constant EXTREME_VOLATILITY = 1000; // 10% price change

    // Trading volume thresholds (in USD value, scaled by 1e18)
    uint256 public constant LOW_VOLUME = 10000 * 1e18;    // $10,000
    uint256 public constant MID_VOLUME = 100000 * 1e18;   // $100,000
    uint256 public constant HIGH_VOLUME = 1000000 * 1e18; // $1,000,000

    // Time window for volatility calculations
    uint256 public constant VOLATILITY_WINDOW = 1 hours;

    // Track latest price and volume data per pool
    struct PoolData {
        uint160 lastSqrtPriceX96;
        uint256 lastUpdateTimestamp;
        uint256 cumulativeVolume;
        uint256 volumeWindowStart;
        uint24 currentFee;
        mapping(uint256 => uint256) hourlyVolumes; // timestamp -> volume
        mapping(uint256 => uint160) historicalPrices; // timestamp -> sqrtPriceX96
    }

    // Mapping from poolId to pool data
    mapping(PoolId => PoolData) public poolData;

    // Mapping to track swap count (for debugging/analytics)
    mapping(PoolId => uint256) public swapCount;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------
    // Hook implementations
    // -----------------------------------------------

    function _beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        // Initialize pool data with default values
        PoolId poolId = key.toId();
        PoolData storage data = poolData[poolId];
        
        data.lastSqrtPriceX96 = sqrtPriceX96;
        data.lastUpdateTimestamp = block.timestamp;
        data.currentFee = BASE_FEE;
        data.volumeWindowStart = block.timestamp;
        
        return BaseHook.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        PoolData storage data = poolData[poolId];
        
        // Store initial price
        data.historicalPrices[block.timestamp] = sqrtPriceX96;
        
        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        swapCount[poolId]++;
        
        // Calculate dynamic fee based on current market conditions
        uint24 dynamicFee = calculateDynamicFee(key, params);
        
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, dynamicFee);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        
        // Since we can't directly access sqrtPriceX96 through a method like getState or getSlot0,
        // we'll use the price from the last update, with a small estimation based on the swap
        // This is a simplification - in a production implementation, you'd want to use a more accurate approach
        
        uint160 estimatedSqrtPriceX96 = estimateCurrentPrice(poolId);
        
        // Update pool data
        uint256 swapVolume = calculateSwapVolume(params, delta);
        updatePoolData(poolId, estimatedSqrtPriceX96, swapVolume);
        
        return (BaseHook.afterSwap.selector, 0);
    }

    // -----------------------------------------------
    // Helper functions
    // -----------------------------------------------

    /**
     * @notice Estimate the current sqrt price after a swap
     * @param poolId Pool identifier
     * @return Estimated sqrtPriceX96
     */
    function estimateCurrentPrice(
        PoolId poolId
    ) internal view returns (uint160) {
        PoolData storage data = poolData[poolId];
        
        // Simple price estimation based on the last known price
        // This is a rough approximation and should be replaced with actual price fetching in production
        if (data.lastSqrtPriceX96 == 0) {
            return uint160(1 << 96); // Default to 1.0 if no price history
        }
        
        // For simplicity, we're just returning the last price
        // In a real implementation, you would fetch the actual current price
        return data.lastSqrtPriceX96;
    }

    /**
     * @notice Calculate dynamic fee based on market conditions
     * @param key Pool key
     * @param params Swap parameters
     * @return Fee tier to apply for this swap
     */
    function calculateDynamicFee(PoolKey calldata key, IPoolManager.SwapParams calldata params) 
        internal 
        view 
        returns (uint24) 
    {
        PoolId poolId = key.toId();
        PoolData storage data = poolData[poolId];
        
        // If this is the first swap or too recently initialized, use base fee
        if (data.lastUpdateTimestamp == 0 || block.timestamp - data.lastUpdateTimestamp < 5 minutes) {
            return BASE_FEE;
        }
        
        // Calculate market volatility
        uint256 volatilityBps = calculateVolatility(poolId);
        
        // Calculate trading volume intensity
        uint256 hourlyVolume = getHourlyVolume(poolId);
        
        // Determine fee based on both volatility and volume
        // Higher volatility + higher volume = higher fees
        
        if (volatilityBps >= EXTREME_VOLATILITY || hourlyVolume >= HIGH_VOLUME) {
            return EXTREME_FEE;
        } else if (volatilityBps >= HIGH_VOLATILITY || hourlyVolume >= MID_VOLUME) {
            return HIGH_FEE;
        } else if (volatilityBps >= MID_VOLATILITY) {
            return MID_FEE;
        } else if (volatilityBps >= LOW_VOLATILITY) {
            return LOW_FEE;
        }
        
        // Default to base fee
        return BASE_FEE;
    }

    /**
     * @notice Calculate market volatility in basis points
     * @param poolId Pool identifier
     * @return Volatility in basis points (1/100 of 1%)
     */
    function calculateVolatility(PoolId poolId) internal view returns (uint256) {
        PoolData storage data = poolData[poolId];
        
        // In a real implementation, fetch the current price from the pool
        // For now, use the last known price as an approximation
        uint160 currentSqrtPriceX96 = data.lastSqrtPriceX96;
        
        // If we don't have a previous price, return 0 volatility
        if (data.lastSqrtPriceX96 == 0) {
            return 0;
        }
        
        // Calculate price change
        uint256 priceChangeRatio;
        if (currentSqrtPriceX96 > data.lastSqrtPriceX96) {
            // Price increased
            priceChangeRatio = (uint256(currentSqrtPriceX96) * 10000) / uint256(data.lastSqrtPriceX96);
            return priceChangeRatio > 10000 ? priceChangeRatio - 10000 : 0;
        } else {
            // Price decreased
            priceChangeRatio = (uint256(data.lastSqrtPriceX96) * 10000) / uint256(currentSqrtPriceX96);
            return priceChangeRatio > 10000 ? priceChangeRatio - 10000 : 0;
        }
    }

    /**
     * @notice Calculate swap volume in USD
     * @param params Swap parameters
     * @param delta Balance delta from the swap
     * @return Volume in USD (scaled by 1e18)
     */
    function calculateSwapVolume(IPoolManager.SwapParams calldata params, BalanceDelta delta) 
        internal 
        pure 
        returns (uint256) 
    {
        // This is a simplified calculation
        // In a real implementation, you would use an oracle to get token prices
        // and convert to USD value
        
        // For this example, we'll use the absolute value of the amount specified as volume
        return params.amountSpecified < 0 
            ? uint256(-params.amountSpecified) 
            : uint256(params.amountSpecified);
    }

    /**
     * @notice Update pool data after a swap
     * @param poolId Pool identifier
     * @param newSqrtPriceX96 New sqrt price
     * @param swapVolume Volume of the swap
     */
    function updatePoolData(PoolId poolId, uint160 newSqrtPriceX96, uint256 swapVolume) internal {
        PoolData storage data = poolData[poolId];
        
        // Update price data
        data.lastSqrtPriceX96 = newSqrtPriceX96;
        data.historicalPrices[block.timestamp] = newSqrtPriceX96;
        
        // Update volume data
        data.cumulativeVolume += swapVolume;
        
        // Update hourly volume tracking
        uint256 currentHour = block.timestamp / 1 hours;
        data.hourlyVolumes[currentHour] += swapVolume;
        
        // Update timestamp
        data.lastUpdateTimestamp = block.timestamp;
        
        // Reset volume window if needed
        if (block.timestamp - data.volumeWindowStart > VOLATILITY_WINDOW) {
            data.volumeWindowStart = block.timestamp;
        }
        
        // Update current fee based on the latest data
        // This ensures the getCurrentFee function returns the most recent value
        data.currentFee = calculateDynamicFeeForPool(poolId);
    }

    /**
     * @notice Calculate the current dynamic fee for a pool
     * @param poolId Pool identifier
     * @return Current fee tier
     */
    function calculateDynamicFeeForPool(PoolId poolId) internal view returns (uint24) {
        // Calculate current volatility and volume metrics
        uint256 volatilityBps = calculateVolatility(poolId);
        uint256 hourlyVolume = getHourlyVolume(poolId);
        
        // Determine fee based on metrics
        if (volatilityBps >= EXTREME_VOLATILITY || hourlyVolume >= HIGH_VOLUME) {
            return EXTREME_FEE;
        } else if (volatilityBps >= HIGH_VOLATILITY || hourlyVolume >= MID_VOLUME) {
            return HIGH_FEE;
        } else if (volatilityBps >= MID_VOLATILITY) {
            return MID_FEE;
        } else if (volatilityBps >= LOW_VOLATILITY) {
            return LOW_FEE;
        }
        
        // Default to base fee
        return BASE_FEE;
    }

    /**
     * @notice Get hourly trading volume
     * @param poolId Pool identifier
     * @return Volume in the last hour
     */
    function getHourlyVolume(PoolId poolId) internal view returns (uint256) {
        PoolData storage data = poolData[poolId];
        uint256 currentHour = block.timestamp / 1 hours;
        return data.hourlyVolumes[currentHour];
    }

    /**
     * @notice Get current fee tier for a pool
     * @param key Pool key
     * @return Current fee tier
     */
    function getCurrentFee(PoolKey calldata key) external view returns (uint24) {
        PoolId poolId = key.toId();
        return poolData[poolId].currentFee;
    }

    /**
     * @notice Get current volatility for a pool
     * @param key Pool key
     * @return Current volatility in basis points
     */
    function getCurrentVolatility(PoolKey calldata key) external view returns (uint256) {
        PoolId poolId = key.toId();
        return calculateVolatility(poolId);
    }

    /**
     * @notice Get hourly volume for a pool
     * @param key Pool key
     * @return Volume in the last hour
     */
    function getPoolHourlyVolume(PoolKey calldata key) external view returns (uint256) {
        PoolId poolId = key.toId();
        return getHourlyVolume(poolId);
    }

    /**
     * @notice Update the dynamic fee for a pool through the pool manager
     * @param key Pool key
     */
    function updatePoolFee(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        uint24 newFee = calculateDynamicFeeForPool(poolId);
        
        // Update the fee through the pool manager
        // This requires the hook to be authorized to update fees
        poolManager.updateDynamicLPFee(key, newFee);
    }
}