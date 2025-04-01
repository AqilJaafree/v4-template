// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Constants} from "v4-core/src/../test/utils/Constants.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {CrossPoolHook} from "../src/CrossPoolHook.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {EasyPosm} from "../test/utils/EasyPosm.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "../test/utils/forks/DeployPermit2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPositionDescriptor} from "v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

/// @notice Forge script for deploying v4 & hooks to **anvil**
contract CrossPoolHookScript is Script, DeployPermit2 {
    using EasyPosm for IPositionManager;
    using CurrencyLibrary for Currency;

    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    IPoolManager manager;
    IPositionManager posm;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;

    function setUp() public {}

    function run() public {
        vm.broadcast();
        manager = deployPoolManager();

        // hook contracts must have specific flags encoded in the address
        uint160 permissions = uint160(
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        // Mine a salt that will produce a hook address with the correct permissions
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, permissions, type(CrossPoolHook).creationCode, abi.encode(address(manager)));

        // ----------------------------- //
        // Deploy the hook using CREATE2 //
        // ----------------------------- //
        vm.broadcast();
        CrossPoolHook hook = new CrossPoolHook{salt: salt}(manager);
        require(address(hook) == hookAddress, "CrossPoolHookScript: hook address mismatch");

        // Additional helpers for interacting with the pool
        vm.startBroadcast();
        posm = deployPosm(manager);
        (lpRouter, swapRouter,) = deployRouters(manager);
        vm.stopBroadcast();

        // test the cross-pool lifecycle (create pools, add liquidity, setup link, swap)
        vm.startBroadcast();
        testCrossPoolLifecycle(address(hook));
        vm.stopBroadcast();
    }

    // -----------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------
    function deployPoolManager() internal returns (IPoolManager) {
        return IPoolManager(address(new PoolManager(address(0))));
    }

    function deployRouters(IPoolManager _manager)
        internal
        returns (PoolModifyLiquidityTest _lpRouter, PoolSwapTest _swapRouter, PoolDonateTest _donateRouter)
    {
        _lpRouter = new PoolModifyLiquidityTest(_manager);
        _swapRouter = new PoolSwapTest(_manager);
        _donateRouter = new PoolDonateTest(_manager);
    }

    function deployPosm(IPoolManager poolManager) public returns (IPositionManager) {
        anvilPermit2();
        return IPositionManager(
            new PositionManager(poolManager, permit2, 300_000, IPositionDescriptor(address(0)), IWETH9(address(0)))
        );
    }

    function approvePosmCurrency(IPositionManager _posm, Currency currency) internal {
        // Because POSM uses permit2, we must execute 2 permits/approvals.
        // 1. First, the caller must approve permit2 on the token.
        IERC20(Currency.unwrap(currency)).approve(address(permit2), type(uint256).max);
        // 2. Then, the caller must approve POSM as a spender of permit2
        permit2.approve(Currency.unwrap(currency), address(_posm), type(uint160).max, type(uint48).max);
    }

    function deployTokens() internal returns (MockERC20 token0, MockERC20 token1, MockERC20 token2) {
        MockERC20 tokenA = new MockERC20("MockA", "A", 18);
        MockERC20 tokenB = new MockERC20("MockB", "B", 18);
        MockERC20 tokenC = new MockERC20("MockC", "C", 18);
        
        // Sort token0 and token1
        if (uint160(address(tokenA)) < uint160(address(tokenB))) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }
        
        token2 = tokenC;
    }

    // Helper function to create a pool key with correctly ordered tokens
    function createSortedPoolKey(
        Currency currencyA, 
        Currency currencyB, 
        uint24 fee, 
        int24 tickSpacing, 
        IHooks hooks
    ) internal pure returns (PoolKey memory) {
        if (uint160(Currency.unwrap(currencyA)) < uint160(Currency.unwrap(currencyB))) {
            return PoolKey(currencyA, currencyB, fee, tickSpacing, hooks);
        } else {
            return PoolKey(currencyB, currencyA, fee, tickSpacing, hooks);
        }
    }

    function testCrossPoolLifecycle(address hook) internal {
        // Deploy 3 tokens for our cross-pool setup
        (MockERC20 token0, MockERC20 token1, MockERC20 token2) = deployTokens();
        
        // Mint tokens to sender
        token0.mint(msg.sender, 100_000 ether);
        token1.mint(msg.sender, 100_000 ether);
        token2.mint(msg.sender, 100_000 ether);

        int24 tickSpacing = 60;
        
        // Initialize Pool A with sorted tokens: token0/token1
        PoolKey memory poolKeyA = createSortedPoolKey(
            Currency.wrap(address(token0)), 
            Currency.wrap(address(token1)), 
            3000, tickSpacing, IHooks(hook)
        );
        manager.initialize(poolKeyA, Constants.SQRT_PRICE_1_1);
        
        // Initialize Pool B with sorted tokens: token1/token2
        PoolKey memory poolKeyB = createSortedPoolKey(
            Currency.wrap(address(token1)), 
            Currency.wrap(address(token2)), 
            3000, tickSpacing, IHooks(hook)
        );
        manager.initialize(poolKeyB, Constants.SQRT_PRICE_1_1);

        // Approve tokens for routers
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        token2.approve(address(lpRouter), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token2.approve(address(swapRouter), type(uint256).max);
        
        // Approve tokens for position manager
        approvePosmCurrency(posm, Currency.wrap(address(token0)));
        approvePosmCurrency(posm, Currency.wrap(address(token1)));
        approvePosmCurrency(posm, Currency.wrap(address(token2)));

        // Add liquidity to both pools
        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(tickSpacing);
        
        // Add liquidity to Pool A
        _addLiquidity(poolKeyA, tickLower, tickUpper);
        
        // Add liquidity to Pool B
        _addLiquidity(poolKeyB, tickLower, tickUpper);
        
        // Create cross-pool link from Pool A to Pool B with a threshold
        CrossPoolHook(hook).createCrossPoolLink(poolKeyA, poolKeyB, 0.1 ether);
        
        // Execute a swap in Pool A that should trigger a cross-pool action in Pool B
        _executeLargeSwap(poolKeyA);
    }

    function _addLiquidity(PoolKey memory poolKey, int24 tickLower, int24 tickUpper) internal {
        // Add liquidity to the pool
        IPoolManager.ModifyLiquidityParams memory liqParams =
            IPoolManager.ModifyLiquidityParams(tickLower, tickUpper, 100 ether, 0);
        lpRouter.modifyLiquidity(poolKey, liqParams, "");

        // Also add liquidity through posm for additional depth
        posm.mint(poolKey, tickLower, tickUpper, 100e18, 10_000e18, 10_000e18, msg.sender, block.timestamp + 300, "");
    }

    function _executeLargeSwap(PoolKey memory poolKey) internal {
        // Execute a large enough swap to trigger cross-pool action
        bool zeroForOne = true;
        int256 amountSpecified = -1 ether; // Exact input of 1 token
        
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1 // unlimited impact
        });
        
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        
        swapRouter.swap(poolKey, params, testSettings, "");
    }
}