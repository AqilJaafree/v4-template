import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";// SPDX-License-Identifier: MIT
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
import {CrossPoolHook} from "../src/CrossPoolHook.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

contract CrossPoolHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    CrossPoolHook hook;
    PoolId poolAId;
    PoolId poolBId;
    PoolKey poolKeyA;
    PoolKey poolKeyB;

    uint256 tokenIdA;
    uint256 tokenIdB;
    int24 tickLower;
    int24 tickUpper;
    
    // Constants for testing
    uint256 constant THRESHOLD = 1e17; // 0.1 tokens
    uint256 constant LARGE_SWAP_AMOUNT = 1e18; // 1 token
    uint256 constant SMALL_SWAP_AMOUNT = 1e16; // 0.01 tokens

    function setUp() public {
        // Create pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        
        // Create tokens for our pools using the existing Fixtures methods
        deployMintAndApprove2Currencies(); // This creates currency0 and currency1
        
        // For the third currency, we'll deploy a custom one
        Currency currency2;
        {
            // Deploy a new ERC20 token
            MockERC20 token = new MockERC20("Token C", "TC", 18);
            currency2 = Currency.wrap(address(token));
            
            // Mint tokens to test contract
            token.mint(address(this), 10_000_000 ether);
            
            // Approve tokens for necessary contracts
            token.approve(address(manager), type(uint256).max);
            token.approve(address(modifyLiquidityRouter), type(uint256).max);
            token.approve(address(swapRouter), type(uint256).max);
        }
        
        // Deploy and approve the position manager
        deployAndApprovePosm(manager);

        // Deploy the hook with the correct flags (just use afterSwap)
        address flags = address(
            uint160(
                Hooks.AFTER_SWAP_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(manager);
        deployCodeTo("CrossPoolHook.sol:CrossPoolHook", constructorArgs, flags);
        hook = CrossPoolHook(flags);

        // Create the first pool (A): currency0 <-> currency1
        poolKeyA = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolAId = poolKeyA.toId();
        manager.initialize(poolKeyA, SQRT_PRICE_1_1);

        // Create the second pool (B): currency1 <-> currency2
        poolKeyB = PoolKey(currency1, currency2, 3000, 60, IHooks(hook));
        poolBId = poolKeyB.toId();
        manager.initialize(poolKeyB, SQRT_PRICE_1_1);

        // Set up tick range for liquidity
        tickLower = TickMath.minUsableTick(poolKeyA.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKeyA.tickSpacing);

        // Add liquidity to pool A
        uint128 liquidityAmountA = 100e18;
        (uint256 amount0ExpectedA, uint256 amount1ExpectedA) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmountA
        );

        (tokenIdA,) = posm.mint(
            poolKeyA,
            tickLower,
            tickUpper,
            liquidityAmountA,
            amount0ExpectedA + 1,
            amount1ExpectedA + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );

        // Add liquidity to pool B
        uint128 liquidityAmountB = 100e18;
        (uint256 amount0ExpectedB, uint256 amount1ExpectedB) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmountB
        );

        (tokenIdB,) = posm.mint(
            poolKeyB,
            tickLower,
            tickUpper,
            liquidityAmountB,
            amount0ExpectedB + 1,
            amount1ExpectedB + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );

        // Link pools for cross-pool operations
        // When swapping in Pool A, it will trigger operations in Pool B
        hook.createCrossPoolLink(poolKeyA, poolKeyB, THRESHOLD);
        
        // Log setup information
        bytes32 poolAIdBytes = bytes32(abi.encode(poolAId));
        bytes32 poolBIdBytes = bytes32(abi.encode(poolBId));
        console.log("Pool A ID:");
        console.logBytes32(poolAIdBytes);
        console.log("Pool B ID:");
        console.logBytes32(poolBIdBytes);
        console.log("Cross-pool threshold:", THRESHOLD);
    }

    function testCrossPoolSwap() public {
        // Prepare for a swap in pool A
        bool zeroForOneA = true; // Swap currency0 for currency1 in pool A
        int256 amountSpecifiedA = -int256(LARGE_SWAP_AMOUNT); // Swap 1 token (exact input)
        
        // Get balances before swap
        uint256 currency0BalanceBefore = poolKeyA.currency0.balanceOf(address(this));
        uint256 currency1BalanceBefore = poolKeyA.currency1.balanceOf(address(this));
        uint256 currency2BalanceBefore = poolKeyB.currency1.balanceOf(address(this));
        
        console.log("==== Before Large Swap ====");
        console.log("Token A balance:", currency0BalanceBefore);
        console.log("Token B balance:", currency1BalanceBefore);
        console.log("Token C balance:", currency2BalanceBefore);
        
        // Execute swap in pool A
        console.log("\nExecuting large swap in Pool A (should trigger cross-pool action)");
        BalanceDelta swapDeltaA = swap(poolKeyA, zeroForOneA, amountSpecifiedA, ZERO_BYTES);
        
        // Get balances after swap
        uint256 currency0BalanceAfter = poolKeyA.currency0.balanceOf(address(this));
        uint256 currency1BalanceAfter = poolKeyA.currency1.balanceOf(address(this));
        uint256 currency2BalanceAfter = poolKeyB.currency1.balanceOf(address(this));
        
        console.log("==== After Large Swap ====");
        console.log("Token A balance:", currency0BalanceAfter);
        console.log("Token B balance:", currency1BalanceAfter);
        console.log("Token C balance:", currency2BalanceAfter);
        console.log("Swap delta amount0:", int256(swapDeltaA.amount0()));
        console.log("Swap delta amount1:", int256(swapDeltaA.amount1()));
        
        // Verify pool A swap results
        assertLt(int256(swapDeltaA.amount0()), 0, "Expected negative amount0 (tokens sold)");
        assertGt(int256(swapDeltaA.amount1()), 0, "Expected positive amount1 (tokens received)");
        
        // Test with a smaller swap that should not trigger cross-pool action
        vm.warp(block.timestamp + 100); // Advance time to clear cooldown
        
        // Get balances before small swap
        currency0BalanceBefore = poolKeyA.currency0.balanceOf(address(this));
        currency1BalanceBefore = poolKeyA.currency1.balanceOf(address(this));
        currency2BalanceBefore = poolKeyB.currency1.balanceOf(address(this));
        
        console.log("\n==== Before Small Swap ====");
        console.log("Token A balance:", currency0BalanceBefore);
        console.log("Token B balance:", currency1BalanceBefore);
        console.log("Token C balance:", currency2BalanceBefore);
        
        // Swap with amount below threshold
        int256 smallAmountA = -int256(SMALL_SWAP_AMOUNT); // 0.01 tokens, below the 0.1 threshold
        console.log("\nExecuting small swap in Pool A (should NOT trigger cross-pool action)");
        BalanceDelta smallSwapDeltaA = swap(poolKeyA, zeroForOneA, smallAmountA, ZERO_BYTES);
        
        // Get balances after small swap
        currency0BalanceAfter = poolKeyA.currency0.balanceOf(address(this));
        currency1BalanceAfter = poolKeyA.currency1.balanceOf(address(this));
        currency2BalanceAfter = poolKeyB.currency1.balanceOf(address(this));
        
        console.log("==== After Small Swap ====");
        console.log("Token A balance:", currency0BalanceAfter);
        console.log("Token B balance:", currency1BalanceAfter);
        console.log("Token C balance:", currency2BalanceAfter);
        console.log("Small swap delta amount0:", int256(smallSwapDeltaA.amount0()));
        console.log("Small swap delta amount1:", int256(smallSwapDeltaA.amount1()));
        
        // Verify the small swap results
        assertLt(int256(smallSwapDeltaA.amount0()), 0, "Expected negative amount0 for small swap");
    }
    
    function testModifyCrossPoolLink() public {
        // Test updating the threshold
        uint256 newThreshold = 2e17; // 0.2 tokens
        hook.createCrossPoolLink(poolKeyA, poolKeyB, newThreshold);
        
        // Verify the threshold was updated
        assertEq(hook.thresholds(poolAId), newThreshold, "Threshold should be updated");
        
        // Test a swap with amount between old and new thresholds (should NOT trigger cross-pool action)
        bool zeroForOneA = true;
        int256 betweenThresholdsAmount = -int256(1.5e17); // 0.15 tokens (between old and new thresholds)
        
        // Get Token C balance before swap
        uint256 currency2BalanceBefore = poolKeyB.currency1.balanceOf(address(this));
        
        // Execute swap
        console.log("\nExecuting swap with amount between old and new thresholds");
        swap(poolKeyA, zeroForOneA, betweenThresholdsAmount, ZERO_BYTES);
        
        // Get Token C balance after swap
        uint256 currency2BalanceAfter = poolKeyB.currency1.balanceOf(address(this));
        
        // Output the balances for debugging
        console.log("Token C balance before:", currency2BalanceBefore);
        console.log("Token C balance after:", currency2BalanceAfter);
    }
}