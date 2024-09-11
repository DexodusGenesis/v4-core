// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
// import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import "./utils/Deployers.sol";
import {Pool} from "../src/libraries/Pool.sol";
import {PoolIdLibrary} from "../src/types/PoolId.sol";

// forge test --match-contract DexodusPoolManagerTest -vv --ffi

contract DexodusPoolManagerTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using Pool for *;

    IPoolManager.ModifyLiquidityParams public LIQUIDITY_PARAMS1 =
        IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 100e18, salt: 0});
    IPoolManager.ModifyLiquidityParams public REMOVE_LIQUIDITY_PARAMS1 =
        IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -1e18, salt: 0});
    
    address public owner;

    Currency internal currencyA;
    Currency internal currencyB;

    function setUp() public {

        owner = vm.addr(0xEF);

        deployFreshManagerAndRouters();

        (currencyA, currencyB) = deployMintAndApprove2Currencies();

        MockERC20(Currency.unwrap(currencyA)).transfer(address(owner),  2 ** 255);
        MockERC20(Currency.unwrap(currencyB)).transfer(address(owner),  2 ** 255);
    }

    function test_Init_Pool() public {
        vm.startPrank(owner);

        MockERC20(Currency.unwrap(currencyA)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currencyB)).approve(address(modifyLiquidityRouter), type(uint256).max);

        (PoolKey memory _key, PoolId id) = initPool(currencyA, currencyB, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        vm.stopPrank();
    }

    function test_Add_Remove_Liquidity() public {
        vm.startPrank(owner);

        MockERC20(Currency.unwrap(currencyA)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currencyB)).approve(address(modifyLiquidityRouter), type(uint256).max);

        (PoolKey memory _key, PoolId id) = initPool(currencyA, currencyB, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        modifyLiquidityRouter.modifyLiquidity(_key, LIQUIDITY_PARAMS1, ZERO_BYTES);
        // modifyLiquidityRouter.modifyLiquidity(_key, REMOVE_LIQUIDITY_PARAMS1, ZERO_BYTES);

        vm.stopPrank();
    }

    function test_get_Liquidity_Pool_info() public {
        vm.startPrank(owner);

        MockERC20(Currency.unwrap(currencyA)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currencyB)).approve(address(modifyLiquidityRouter), type(uint256).max);

        (PoolKey memory _key, PoolId id) = initPool(currencyA, currencyB, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        uint160 sqrtPriceX96 = manager.getPool_sqrtPriceX96(_key.toId());
        int24 tick = manager.getPool_tick(_key.toId());
        uint160 price = (sqrtPriceX96 / 2**96) ** 2;

        console2.log("sqrtPriceX96", sqrtPriceX96);
        console2.log("tick", tick);
        console2.log("price", price);

        modifyLiquidityRouter.modifyLiquidity(_key, LIQUIDITY_PARAMS1, ZERO_BYTES);

        sqrtPriceX96 = manager.getPool_sqrtPriceX96(_key.toId());
        tick = manager.getPool_tick(_key.toId());
        price = (sqrtPriceX96 / 2**96) ** 2;

        console2.log("sqrtPriceX96", sqrtPriceX96);
        console2.log("tick", tick);
        console2.log("price", price);

        modifyLiquidityRouter.modifyLiquidity(_key, REMOVE_LIQUIDITY_PARAMS1, ZERO_BYTES);

        sqrtPriceX96 = manager.getPool_sqrtPriceX96(_key.toId());
        tick = manager.getPool_tick(_key.toId());
        price = (sqrtPriceX96 / 2**96) ** 2;

        console2.log("sqrtPriceX96", sqrtPriceX96);
        console2.log("tick", tick);
        console2.log("price", price);

        vm.stopPrank();
    }

    function test_swap() public {
        vm.startPrank(owner);

        MockERC20(Currency.unwrap(currencyA)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currencyB)).approve(address(modifyLiquidityRouter), type(uint256).max);

        MockERC20(Currency.unwrap(currencyA)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currencyB)).approve(address(swapRouter), type(uint256).max);

        (PoolKey memory _key, PoolId id) = initPool(currencyA, currencyB, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        uint160 sqrtPriceX96 = manager.getPool_sqrtPriceX96(_key.toId());
        int24 tick = manager.getPool_tick(_key.toId());
        uint256 price = (sqrtPriceX96 / 2**96) ** 2;

        console2.log("sqrtPriceX96", sqrtPriceX96);
        console2.log("tick", tick);
        console2.log("price", price);

        modifyLiquidityRouter.modifyLiquidity(_key, LIQUIDITY_PARAMS1, ZERO_BYTES);

        sqrtPriceX96 = manager.getPool_sqrtPriceX96(_key.toId());
        tick = manager.getPool_tick(_key.toId());
        price = (sqrtPriceX96 / 2**96) ** 2;

        console2.log("sqrtPriceX96", sqrtPriceX96);
        console2.log("tick", tick);
        console2.log("price", price);

        swapRouter.swap(
            _key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 1e18,
                sqrtPriceLimitX96: false ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        sqrtPriceX96 = manager.getPool_sqrtPriceX96(_key.toId());
        tick = manager.getPool_tick(_key.toId());
        price = (sqrtPriceX96 / 2**96) ** 2;

        console2.log("sqrtPriceX96", sqrtPriceX96);
        console2.log("tick", tick);
        console2.log("price", price);

        vm.stopPrank();
    }

    function test_swap_2() public {
        vm.startPrank(owner);

        MockERC20(Currency.unwrap(currencyA)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currencyB)).approve(address(modifyLiquidityRouter), type(uint256).max);

        MockERC20(Currency.unwrap(currencyA)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currencyB)).approve(address(swapRouter), type(uint256).max);

        (PoolKey memory _key, PoolId id) = initPool(currencyA, currencyB, IHooks(address(0)), 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        uint160 sqrtPriceX96 = manager.getPool_sqrtPriceX96(_key.toId());
        int24 tick = manager.getPool_tick(_key.toId());
        uint256 price = (sqrtPriceX96 / 2**96) ** 2;

        console2.log("sqrtPriceX96", sqrtPriceX96);
        console2.log("tick", tick);
        console2.log("price", price);

        modifyLiquidityRouter.modifyLiquidity(_key, LIQUIDITY_PARAMS1, ZERO_BYTES);

        sqrtPriceX96 = manager.getPool_sqrtPriceX96(_key.toId());
        tick = manager.getPool_tick(_key.toId());
        price = (sqrtPriceX96 / 2**96) ** 2;

        console2.log("sqrtPriceX96", sqrtPriceX96);
        console2.log("tick", tick);
        console2.log("price", price);

        swapRouter.swap(
            _key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 5e17,
                sqrtPriceLimitX96: false ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        sqrtPriceX96 = manager.getPool_sqrtPriceX96(_key.toId());
        tick = manager.getPool_tick(_key.toId());
        price = (sqrtPriceX96 / 2**96) ** 2;

        console2.log("sqrtPriceX96", sqrtPriceX96);
        console2.log("tick", tick);
        console2.log("price", price);

        swapRouter.swap(
            _key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 5e17,
                sqrtPriceLimitX96: false ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        sqrtPriceX96 = manager.getPool_sqrtPriceX96(_key.toId());
        tick = manager.getPool_tick(_key.toId());
        price = (sqrtPriceX96 / 2**96) ** 2;

        console2.log("sqrtPriceX96", sqrtPriceX96);
        console2.log("tick", tick);
        console2.log("price", price);

        vm.stopPrank();
    }

}
