// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Hooks} from "../libraries/Hooks.sol";
import {Pool} from "../libraries/Pool.sol";
import {SafeCast} from "../libraries/SafeCast.sol";
import {Position} from "../libraries/Position.sol";
import {LPFeeLibrary} from "../libraries/LPFeeLibrary.sol";
import {Currency} from "../types/Currency.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {TickMath} from "../libraries/TickMath.sol";
import {NoDelegateCall} from "../NoDelegateCall.sol";
import {IHooks} from "../interfaces/IHooks.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../interfaces/callback/IUnlockCallback.sol";
import {ProtocolFees} from "../ProtocolFees.sol";
import {ERC6909Claims} from "../ERC6909Claims.sol";
import {PoolId} from "../types/PoolId.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";
import {Lock} from "../libraries/Lock.sol";
import {CurrencyDelta} from "../libraries/CurrencyDelta.sol";
import {NonzeroDeltaCount} from "../libraries/NonzeroDeltaCount.sol";
import {CurrencyReserves} from "../libraries/CurrencyReserves.sol";
import {Extsload} from "../Extsload.sol";
import {Exttload} from "../Exttload.sol";
import {CustomRevert} from "../libraries/CustomRevert.sol";

/// @notice A proxy pool manager that delegates calls to the real/delegate pool manager
contract ProxyPoolManager is IPoolManager, ProtocolFees, NoDelegateCall, ERC6909Claims, Extsload, Exttload {
    using SafeCast for *;
    using Pool for *;
    using Hooks for IHooks;
    using Position for mapping(bytes32 => Position.State);
    using CurrencyDelta for Currency;
    using LPFeeLibrary for uint24;
    using CurrencyReserves for Currency;
    using CustomRevert for bytes4;

    int24 private constant MAX_TICK_SPACING = TickMath.MAX_TICK_SPACING;

    int24 private constant MIN_TICK_SPACING = TickMath.MIN_TICK_SPACING;

    mapping(PoolId id => Pool.State) internal _pools;

    address internal immutable _delegateManager;

    constructor(address delegateManager) {
        _delegateManager = delegateManager;
    }

    /// @notice This will revert if the contract is locked
    modifier onlyWhenUnlocked() {
        if (!Lock.isUnlocked()) ManagerLocked.selector.revertWith();
        _;
    }

    /// @inheritdoc IPoolManager
    function unlock(bytes calldata data) external noDelegateCall returns (bytes memory result) {
        if (Lock.isUnlocked()) AlreadyUnlocked.selector.revertWith();

        Lock.unlock();

        // the caller does everything in this callback, including paying what they owe via calls to settle
        result = IUnlockCallback(msg.sender).unlockCallback(data);

        if (NonzeroDeltaCount.read() != 0) CurrencyNotSettled.selector.revertWith();
        Lock.lock();
    }

    /// @inheritdoc IPoolManager
    function initialize(PoolKey memory key, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        noDelegateCall
        returns (int24 tick)
    {
        // see TickBitmap.sol for overflow conditions that can arise from tick spacing being too large
        if (key.tickSpacing > MAX_TICK_SPACING) TickSpacingTooLarge.selector.revertWith(key.tickSpacing);
        if (key.tickSpacing < MIN_TICK_SPACING) TickSpacingTooSmall.selector.revertWith(key.tickSpacing);
        if (key.currency0 >= key.currency1) {
            CurrenciesOutOfOrderOrEqual.selector.revertWith(
                Currency.unwrap(key.currency0), Currency.unwrap(key.currency1)
            );
        }
        if (!key.hooks.isValidHookAddress(key.fee)) Hooks.HookAddressNotValid.selector.revertWith(address(key.hooks));

        uint24 lpFee = key.fee.getInitialLPFee();

        key.hooks.beforeInitialize(key, sqrtPriceX96, hookData);

        PoolId id = key.toId();
        uint24 protocolFee = _fetchProtocolFee(key);

        tick = _pools[id].initialize(sqrtPriceX96, protocolFee, lpFee);

        key.hooks.afterInitialize(key, sqrtPriceX96, tick, hookData);

        // emit all details of a pool key. poolkeys are not saved in storage and must always be provided by the caller
        // the key's fee may be a static fee or a sentinel to denote a dynamic fee.
        emit Initialize(id, key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks, sqrtPriceX96, tick);
    }

    /// @inheritdoc IPoolManager
    function modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes calldata hookData
    ) external onlyWhenUnlocked noDelegateCall returns (BalanceDelta callerDelta, BalanceDelta feesAccrued) {
        bytes memory result = _delegateCall(
            _delegateManager, abi.encodeWithSelector(this.modifyLiquidity.selector, key, params, hookData)
        );

        return abi.decode(result, (BalanceDelta, BalanceDelta));
    }

    /// @inheritdoc IPoolManager
    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata hookData)
        external
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta swapDelta)
    {
        bytes memory result =
            _delegateCall(_delegateManager, abi.encodeWithSelector(this.swap.selector, key, params, hookData));

        return abi.decode(result, (BalanceDelta));
    }

    /// @inheritdoc IPoolManager
    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta delta)
    {
        bytes memory result = _delegateCall(
            _delegateManager, abi.encodeWithSelector(this.donate.selector, key, amount0, amount1, hookData)
        );

        return abi.decode(result, (BalanceDelta));
    }

    /// @inheritdoc IPoolManager
    function sync(Currency currency) public {
        // address(0) is used for the native currency
        if (currency.isAddressZero()) {
            // The reserves balance is not used for native settling, so we only need to reset the currency.
            CurrencyReserves.resetCurrency();
        } else {
            uint256 balance = currency.balanceOfSelf();
            CurrencyReserves.syncCurrencyAndReserves(currency, balance);
        }
    }

    /// @inheritdoc IPoolManager
    function take(Currency currency, address to, uint256 amount) external onlyWhenUnlocked noDelegateCall {
        _delegateCall(_delegateManager, abi.encodeWithSelector(this.take.selector, currency, to, amount));
    }

    /// @inheritdoc IPoolManager
    function settle() external payable onlyWhenUnlocked noDelegateCall returns (uint256 paid) {
        bytes memory result = _delegateCall(_delegateManager, abi.encodeWithSelector(this.settle.selector));

        return abi.decode(result, (uint256));
    }

    /// @inheritdoc IPoolManager
    function settleFor(address recipient) external payable onlyWhenUnlocked noDelegateCall returns (uint256 paid) {
        bytes memory result =
            _delegateCall(_delegateManager, abi.encodeWithSelector(this.settleFor.selector, recipient));

        return abi.decode(result, (uint256));
    }

    /// @inheritdoc IPoolManager
    function clear(Currency currency, uint256 amount) external onlyWhenUnlocked {
        _delegateCall(_delegateManager, abi.encodeWithSelector(this.clear.selector, currency, amount));
    }

    /// @inheritdoc IPoolManager
    function mint(address to, uint256 id, uint256 amount) external onlyWhenUnlocked noDelegateCall {
        _delegateCall(_delegateManager, abi.encodeWithSelector(this.mint.selector, to, id, amount));
    }

    /// @inheritdoc IPoolManager
    function burn(address from, uint256 id, uint256 amount) external onlyWhenUnlocked noDelegateCall {
        _delegateCall(_delegateManager, abi.encodeWithSelector(this.burn.selector, from, id, amount));
    }

    /// @inheritdoc IPoolManager
    function updateDynamicLPFee(PoolKey memory key, uint24 newDynamicLPFee) external {
        if (!key.fee.isDynamicFee() || msg.sender != address(key.hooks)) {
            UnauthorizedDynamicLPFeeUpdate.selector.revertWith();
        }
        newDynamicLPFee.validate();
        PoolId id = key.toId();
        _pools[id].setLPFee(newDynamicLPFee);
    }

    /// @notice Make a delegate call, bubble up any error or return the result
    function _delegateCall(address target, bytes memory data) internal returns (bytes memory result) {
        (bool success, bytes memory returnData) = target.delegatecall(data);

        if (!success) {
            if (returnData.length == 0) {
                revert();
            } else {
                assembly {
                    let size := mload(returnData)
                    revert(add(32, returnData), size)
                }
            }
        }

        return returnData;
    }

    /// @notice Implementation of the _getPool function defined in ProtocolFees
    function _getPool(PoolId id) internal view override returns (Pool.State storage) {
        return _pools[id];
    }

    /// @notice Implementation of the _isUnlocked function defined in ProtocolFees
    function _isUnlocked() internal view override returns (bool) {
        return Lock.isUnlocked();
    }

    // new functions by #4lsh4

    /**
    * @dev Opens a leveraged perpetual position by calculating the required liquidity based on the size and leverage,
    *      then blocks that amount of liquidity in the pool's current tick range.
    * 
    * @param key The PoolKey identifying the pool to update.
    * @param collateral The collateral of the position being opened (e.g., the notional value in token0 or token1).
    * @param leverage The leverage multiplier (e.g., 2x, 5x, etc.).
    * @param tickSpacing The tick spacing of the pool.
    */
    function openPerpPosition(
        PoolKey memory key,
        uint256 collateral, 
        uint256 leverage, 
        int24 tickSpacing
    ) external /*onlyFutures*/ returns (int24, int24) {
        require(collateral > 0, "Collateral must be greater than zero");
        require(leverage > 0, "Leverage must be greater than zero");

        // Convert the PoolKey to the PoolId
        PoolId id = key.toId();

        // Access the pool's state using the pool library
        Pool.State storage pool = _getPool(id);

        // Calculate the total position size, which is collateral * leverage
        uint256 totalPositionSize = collateral * leverage;

        // Calculate the liquidity delta based on the position size
        (uint128 liquidityDelta, int24 tickLower, int24 tickUpper) = pool.calculateLiquidityDelta(totalPositionSize, tickSpacing);

        // Block the liquidity required to open the leveraged position
        pool.blockLiquidity(int128(liquidityDelta), tickSpacing);

        return (tickLower, tickUpper);
    }

    /**
    * @dev Handles the process of a trader closing a position. It updates the liquidity based on the trader's profit, 
    *      unblocks any previously blocked liquidity, and transfers the earned currency amounts (token0 and token1) to the trader.
    * 
    * @param key The PoolKey identifying the pool to update.
    * @param trader The address of the trader closing the position.
    * @param profitAmount0 The profit amount in token0 to be transferred to the trader.
    * @param profitAmount1 The profit amount in token1 to be transferred to the trader.
    * @param collateral The collateral of the position being opened (e.g., the notional value in token0 or token1).
    * @param leverage The leverage multiplier (e.g., 2x, 5x, etc.).
    * @param tickLower The lower bound of the tick range in which the position was opened.
    * @param tickUpper The upper bound of the tick range in which the position was opened.
    * @param tickSpacing The tick spacing of the pool.
    */
    function closePerpPositionProfit(
        PoolKey memory key,
        address trader,
        uint256 profitAmount0,
        uint256 profitAmount1,
        uint256 collateral, 
        uint256 leverage, 
        int24 tickLower,
        int24 tickUpper,
        int24 tickSpacing
    ) external /*onlyFutures*/ {

        // Convert the PoolKey to the PoolId
        PoolId id = key.toId();

        // Access the pool's state using the pool library
        Pool.State storage pool = _getPool(id);

        // Update gain growth for the LPs based on the trader's profits
        updateGainGrowthOnProfit(key, profitAmount0, profitAmount1, tickLower, tickUpper);

        // Update liquidity based on the trader's profit
        pool.updateFromTraderProfit(profitAmount0, profitAmount1, tickLower, tickUpper);

        // Calculate the total position size, which is collateral * leverage
        uint256 totalPositionSize = collateral * leverage;

        // Calculate the liquidity delta based on the position size
        (uint128 liquidityDelta,,) = pool.calculateLiquidityDelta(totalPositionSize, tickSpacing);

        // Unblock liquidity that was blocked when the position was opened
        pool.unblockLiquidity(-int128(liquidityDelta), tickLower, tickUpper);

        // Transfer the profit amounts (in token0 and token1) to the trader's address
        transferTokens(key, trader, profitAmount0, profitAmount1);
    }

    /**
    * @dev Transfers token0 and token1 profits to the trader.
    * @param key The PoolKey identifying the pool to update.
    * @param trader The address of the trader receiving the tokens.
    * @param amount0 The amount of token0 to transfer.
    * @param amount1 The amount of token1 to transfer.
    */
    function transferTokens(PoolKey memory key, address trader, uint256 amount0, uint256 amount1) internal {
        key.currency0.transfer(trader, amount0);
        key.currency1.transfer(trader, amount1);
    }

    /**
    * @dev Handles the process of a trader closing a position with a loss. It updates the liquidity based on the trader's loss,
    *      unblocks any previously blocked liquidity, and adjusts the LP's balances accordingly by transferring the loss from the LPs.
    * 
    * @param key The PoolKey identifying the pool to update.
    * @param lossAmount0 The loss amount in token0 to be deducted from the LPs.
    * @param lossAmount1 The loss amount in token1 to be deducted from the LPs.
    * @param collateral The collateral of the position being opened (e.g., the notional value in token0 or token1).
    * @param leverage The leverage multiplier (e.g., 2x, 5x, etc.).
    * @param tickLower The lower bound of the tick range in which the position was opened.
    * @param tickUpper The upper bound of the tick range in which the position was opened.
    * @param tickSpacing The tick spacing of the pool.
    */
    function closePerpPositionLoss(
        PoolKey memory key,
        uint256 lossAmount0,
        uint256 lossAmount1,
        uint256 collateral, 
        uint256 leverage, 
        int24 tickLower,
        int24 tickUpper,
        int24 tickSpacing
    ) external /*onlyFutures*/ {

        // Convert the PoolKey to the PoolId
        PoolId id = key.toId();

        // Access the pool's state using the pool library
        Pool.State storage pool = _getPool(id);

        // Update loss growth for the LPs based on the trader's loss
        updateLossGrowthOnLiquidationOrLoss(key, lossAmount0, lossAmount1, tickLower, tickUpper);

        // Calculate the total position size, which is collateral * leverage
        uint256 totalPositionSize = collateral * leverage;

        // Calculate the liquidity delta based on the position size
        (uint128 liquidityDelta,,) = pool.calculateLiquidityDelta(totalPositionSize, tickSpacing);

        // Unblock liquidity that was blocked when the position was opened
        pool.unblockLiquidity(-int128(liquidityDelta), tickLower, tickUpper);

        // tokens from loss will be send from futures contract to manager
    }

    /**
    * @notice Updates the loss growth when a perpetual trader is liquidated or position closed with loss.
    *         This ensures LPs receive the proportional share of the trader's loss as profit.
    * @dev This function updates both the global and per-tick loss growth variables for the pool,
    *      ensuring LPs are fairly compensated for the trader's liquidation.
    * @param key The PoolKey identifying the pool to update.
    * @param lossAmount0 The amount of token0 loss to be distributed (profit for LPs).
    * @param lossAmount1 The amount of token1 loss to be distributed (profit for LPs).
    * @param tickLower The lower tick of the trader's position range.
    * @param tickUpper The upper tick of the trader's position range.
    */
    function updateLossGrowthOnLiquidationOrLoss(
        PoolKey memory key,
        uint256 lossAmount0,
        uint256 lossAmount1,
        int24 tickLower,
        int24 tickUpper
    ) internal {
        // Convert the PoolKey to the PoolId
        PoolId id = key.toId();

        // Access the pool's state using the pool library
        Pool.State storage pool = _getPool(id);

        // Check if the pool is initialized
        pool.checkPoolInitialized();

        // Call the internal function to update loss growth
        pool.updateLossGrowthOnLiquidationOrLoss(lossAmount0, lossAmount1, tickLower, tickUpper);
    }

    /**
    * @notice Updates the gain growth when a perpetual trader closes a position with profit. This ensures LPs
    *         incur the proportional share of the trader's gain (equivalent to LP's loss).
    * @dev This function updates both the global and per-tick gain growth variables for the pool,
    *      ensuring LPs are fairly impacted by the trader's profit.
    * @param key The PoolKey identifying the pool to update.
    * @param gainAmount0 The amount of token0 profit (loss for LPs) to be distributed.
    * @param gainAmount1 The amount of token1 profit (loss for LPs) to be distributed.
    * @param tickLower The lower tick of the trader's position range.
    * @param tickUpper The upper tick of the trader's position range.
    */
    function updateGainGrowthOnProfit(
        PoolKey memory key,
        uint256 gainAmount0,
        uint256 gainAmount1,
        int24 tickLower,
        int24 tickUpper
    ) internal {
        // Convert the PoolKey to the PoolId
        PoolId id = key.toId();

        // Access the pool's state using the pool library
        Pool.State storage pool = _getPool(id);

        // Check if the pool is initialized
        pool.checkPoolInitialized();

        // Call the internal function to update gain growth
        pool.updateGainGrowthOnProfit(gainAmount0, gainAmount1, tickLower, tickUpper);
    }

    function getPool_sqrtPriceX96(PoolId id) external view returns (uint160) {
        return _pools[id].slot0.sqrtPriceX96();
    }
    
    function getPool_tick(PoolId id) external view returns (int24) {
        return _pools[id].slot0.tick();
    }
}
