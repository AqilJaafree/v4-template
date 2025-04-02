// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

import {DynamicFeeHook} from "../src/DynamicFeeHook.sol";

contract DynamicFeeHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    DynamicFeeHook hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        // Create the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | 
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            ) ^ (0x5555 << 144) // Namespace the hook to avoid collisions
        );
        
        bytes memory constructorArgs = abi.encode(manager);
        deployCodeTo("DynamicFeeHook.sol:DynamicFeeHook", constructorArgs, flags);
        hook = DynamicFeeHook(flags);

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = posm.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
    }

    function testInitialFee() public {
        // Check that the initial fee is the BASE_FEE
        assertEq(hook.getCurrentFee(key), hook.BASE_FEE());
    }

    function testFeeAfterSmallSwap() public {
        // Perform a small swap to test BASE_FEE is maintained for small activity
        bool zeroForOne = true;
        int256 amountSpecified = -1e16; // 0.01 tokens, small swap
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        
        // Assert the swap was successful
        assertEq(int256(swapDelta.amount0()), amountSpecified);
        
        // For small, non-volatile activity, fee should remain at BASE_FEE
        assertEq(hook.getCurrentFee(key), hook.BASE_FEE());
        
        // Check that swap count is incremented
        assertEq(hook.swapCount(poolId), 1);
    }

    function testFeeAfterMultipleSwaps() public {
        // Perform multiple swaps to simulate higher activity
        for (uint i = 0; i < 5; i++) {
            bool zeroForOne = true;
            int256 amountSpecified = -5e17; // 0.5 tokens each time
            swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
            
            // Small time increase to simulate time passing
            vm.warp(block.timestamp + 60); // 1 minute
        }
        
        // Check swap count is correct
        assertEq(hook.swapCount(poolId), 5);
        
        // Get the current fee after these swaps
        uint24 currentFee = hook.getCurrentFee(key);
        
        // We expect the fee to potentially increase, but this depends on the implementation
        // In realistic conditions, we'd expect larger fee with higher volume/volatility
        assertTrue(
            currentFee >= hook.BASE_FEE(),
            "Fee should be at least the base fee"
        );
        
        // Get current volatility
        uint256 volatility = hook.getCurrentVolatility(key);
        console.log("Current volatility (bps):", volatility);
        
        // Get current volume
        uint256 volume = hook.getPoolHourlyVolume(key);
        console.log("Current hourly volume:", volume);
    }

    function testHighVolatilityFees() public {
        // Simulate high volatility with large price-moving swaps
        
        // Large swap in one direction
        bool zeroForOne = true;
        int256 largeAmount = -10e18; // 10 tokens
        swap(key, zeroForOne, largeAmount, ZERO_BYTES);
        
        // Warp time a bit
        vm.warp(block.timestamp + 120); // 2 minutes
        
        // Large swap in opposite direction to create volatility
        zeroForOne = false;
        largeAmount = 8e18; // 8 tokens
        swap(key, zeroForOne, largeAmount, ZERO_BYTES);
        
        // Get the fee after high volatility swaps
        uint24 highVolatilityFee = hook.getCurrentFee(key);
        
        // Log diagnostics
        console.log("Fee after high volatility swaps:", highVolatilityFee);
        console.log("Volatility (bps):", hook.getCurrentVolatility(key));
        
        // Fee should likely be higher than base fee after high volatility
        assertTrue(
            highVolatilityFee > hook.BASE_FEE(),
            "Fee should increase after high volatility"
        );
    }

    function testFeeUpdateCallingMethod() public {
        // Test the updatePoolFee method
        
        // Perform some swaps to change market conditions
        bool zeroForOne = true;
        int256 amountSpecified = -5e18; // 5 tokens
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        
        // Call the update method
        hook.updatePoolFee(key);
        
        // Check the fee after update
        uint24 currentFee = hook.getCurrentFee(key);
        console.log("Fee after manual update:", currentFee);
        
        // The updatePoolFee should have called poolManager.updateDynamicLPFee
        // to apply the latest calculated fee
    }
}