// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SafeCast} from "./SafeCast.sol";
import {TickBitmap} from "./TickBitmap.sol";
import {Position} from "./Position.sol";
import {UnsafeMath} from "./UnsafeMath.sol";
import {FixedPoint128} from "./FixedPoint128.sol";
import {TickMath} from "./TickMath.sol";
import {SqrtPriceMath} from "./SqrtPriceMath.sol";
import {SwapMath} from "./SwapMath.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "../types/BalanceDelta.sol";
import {Slot0} from "../types/Slot0.sol";
import {ProtocolFeeLibrary} from "./ProtocolFeeLibrary.sol";
import {LiquidityMath} from "./LiquidityMath.sol";
import {LPFeeLibrary} from "./LPFeeLibrary.sol";
import {CustomRevert} from "./CustomRevert.sol";

/// @notice a library with all actions that can be performed on a pool
library Pool {
    using SafeCast for *;
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.State);
    using Position for Position.State;
    using Pool for State;
    using ProtocolFeeLibrary for *;
    using LPFeeLibrary for uint24;
    using CustomRevert for bytes4;

    /// @notice Thrown when tickLower is not below tickUpper
    /// @param tickLower The invalid tickLower
    /// @param tickUpper The invalid tickUpper
    error TicksMisordered(int24 tickLower, int24 tickUpper);

    /// @notice Thrown when tickLower is less than min tick
    /// @param tickLower The invalid tickLower
    error TickLowerOutOfBounds(int24 tickLower);

    /// @notice Thrown when tickUpper exceeds max tick
    /// @param tickUpper The invalid tickUpper
    error TickUpperOutOfBounds(int24 tickUpper);

    /// @notice For the tick spacing, the tick has too much liquidity
    error TickLiquidityOverflow(int24 tick);

    /// @notice Thrown when trying to initialize an already initialized pool
    error PoolAlreadyInitialized();

    /// @notice Thrown when trying to interact with a non-initialized pool
    error PoolNotInitialized();

    /// @notice Thrown when sqrtPriceLimitX96 on a swap has already exceeded its limit
    /// @param sqrtPriceCurrentX96 The invalid, already surpassed sqrtPriceLimitX96
    /// @param sqrtPriceLimitX96 The surpassed price limit
    error PriceLimitAlreadyExceeded(uint160 sqrtPriceCurrentX96, uint160 sqrtPriceLimitX96);

    /// @notice Thrown when sqrtPriceLimitX96 lies outside of valid tick/price range
    /// @param sqrtPriceLimitX96 The invalid, out-of-bounds sqrtPriceLimitX96
    error PriceLimitOutOfBounds(uint160 sqrtPriceLimitX96);

    /// @notice Thrown by donate if there is currently 0 liquidity, since the fees will not go to any liquidity providers
    error NoLiquidityToReceiveFees();

    /// @notice Thrown when trying to swap with max lp fee and specifying an output amount
    error InvalidFeeForExactOut();

    // info stored for each initialized individual tick
    struct TickInfo {
        // the total position liquidity that references this tick
        uint128 liquidityGross;
        // blocked liquidity for perp trading in the tick
        uint128 blockedLiquidityGross;
        // amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left),
        int128 liquidityNet;
        // fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        // track how much perp traders loss is accumalated by LPs, profits for LPs
        uint256 lossGrowthOutside0X128;
        uint256 lossGrowthOutside1X128;
        // track how much perp traders gains is accumalated, loss for LPs
        uint256 gainGrowthOutside0X128;
        uint256 gainGrowthOutside1X128;
    }

    /// @dev The state of a pool
    struct State {
        Slot0 slot0;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        // track how much perp traders loss is accumalated by LPs, profits for LPs
        uint256 lossGrowthGlobal0X128;
        uint256 lossGrowthGlobal1X128;
        // track how much perp traders gains is accumalated, loss for LPs
        uint256 gainGrowthGlobal0X128;
        uint256 gainGrowthGlobal1X128;
        uint128 liquidity;
        mapping(int24 tick => TickInfo) ticks;
        mapping(int16 wordPos => uint256) tickBitmap;
        mapping(bytes32 positionKey => Position.State) positions;
    }

    /// @dev Common checks for valid tick inputs.
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        if (tickLower >= tickUpper) TicksMisordered.selector.revertWith(tickLower, tickUpper);
        if (tickLower < TickMath.MIN_TICK) TickLowerOutOfBounds.selector.revertWith(tickLower);
        if (tickUpper > TickMath.MAX_TICK) TickUpperOutOfBounds.selector.revertWith(tickUpper);
    }

    function initialize(State storage self, uint160 sqrtPriceX96, uint24 protocolFee, uint24 lpFee)
        internal
        returns (int24 tick)
    {
        if (self.slot0.sqrtPriceX96() != 0) PoolAlreadyInitialized.selector.revertWith();

        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        self.slot0 = Slot0.wrap(bytes32(0)).setSqrtPriceX96(sqrtPriceX96).setTick(tick).setProtocolFee(protocolFee)
            .setLpFee(lpFee);
    }

    function setProtocolFee(State storage self, uint24 protocolFee) internal {
        self.checkPoolInitialized();
        self.slot0 = self.slot0.setProtocolFee(protocolFee);
    }

    /// @notice Only dynamic fee pools may update the lp fee.
    function setLPFee(State storage self, uint24 lpFee) internal {
        self.checkPoolInitialized();
        self.slot0 = self.slot0.setLpFee(lpFee);
    }

    struct ModifyLiquidityParams {
        // the address that owns the position
        address owner;
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // any change in liquidity
        int128 liquidityDelta;
        // the spacing between ticks
        int24 tickSpacing;
        // used to distinguish positions of the same owner, at the same tick range
        bytes32 salt;
    }

    struct ModifyLiquidityState {
        bool flippedLower;
        uint128 liquidityGrossAfterLower;
        bool flippedUpper;
        uint128 liquidityGrossAfterUpper;
    }

    /// @notice Effect changes to a position in a pool
    /// @dev PoolManager checks that the pool is initialized before calling
    /// @param params the position details and the change to the position's liquidity to effect
    /// @return delta the deltas of the token balances of the pool, from the liquidity change
    /// @return feeDelta the fees generated by the liquidity range
    function modifyLiquidity(State storage self, ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta, BalanceDelta feeDelta, BalanceDelta lossGainDelta)
    {
        int128 liquidityDelta = params.liquidityDelta;
        int24 tickLower = params.tickLower;
        int24 tickUpper = params.tickUpper;
        checkTicks(tickLower, tickUpper);

        {
            ModifyLiquidityState memory state;

            // if we need to update the ticks, do it
            if (liquidityDelta != 0) {
                (state.flippedLower, state.liquidityGrossAfterLower) =
                    updateTick(self, tickLower, liquidityDelta, false);
                (state.flippedUpper, state.liquidityGrossAfterUpper) = updateTick(self, tickUpper, liquidityDelta, true);

                // `>` and `>=` are logically equivalent here but `>=` is cheaper
                if (liquidityDelta >= 0) {
                    uint128 maxLiquidityPerTick = tickSpacingToMaxLiquidityPerTick(params.tickSpacing);
                    if (state.liquidityGrossAfterLower > maxLiquidityPerTick) {
                        TickLiquidityOverflow.selector.revertWith(tickLower);
                    }
                    if (state.liquidityGrossAfterUpper > maxLiquidityPerTick) {
                        TickLiquidityOverflow.selector.revertWith(tickUpper);
                    }
                }

                if (state.flippedLower) {
                    self.tickBitmap.flipTick(tickLower, params.tickSpacing);
                }
                if (state.flippedUpper) {
                    self.tickBitmap.flipTick(tickUpper, params.tickSpacing);
                }
            }

            {
                (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
                    getFeeGrowthInside(self, tickLower, tickUpper);

                Position.State storage position = self.positions.get(params.owner, tickLower, tickUpper, params.salt);
                (uint256 feesOwed0, uint256 feesOwed1) =
                    position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

                // Fees earned from LPing are calculated, and returned
                feeDelta = toBalanceDelta(feesOwed0.toInt128(), feesOwed1.toInt128());

                // new 4lsh4 section

                (uint256 lossGrowthInside0X128, uint256 lossGrowthInside1X128) =
                    getLossGrowthInside(self, tickLower, tickUpper);

                (uint256 gainGrowthInside0X128, uint256 gainGrowthInside1X128) =
                    getGainGrowthInside(self, tickLower, tickUpper);

                (uint256 lossOwed0, uint256 lossOwed1, uint256 gainOwed0, uint256 gainOwed1) =
                    position.updateLossAndGainGrowth(lossGrowthInside0X128,
                                                     lossGrowthInside1X128,
                                                     gainGrowthInside0X128,
                                                     gainGrowthInside1X128);

                // Loss earned from LPing are calculated, and returned
                BalanceDelta lossDelta = toBalanceDelta(lossOwed0.toInt128(), lossOwed1.toInt128());
                BalanceDelta gainDelta = toBalanceDelta(gainOwed0.toInt128(), gainOwed1.toInt128());
                lossGainDelta = lossDelta - gainDelta;
            }

            // clear any tick data that is no longer needed
            if (liquidityDelta < 0) {
                if (state.flippedLower) {
                    clearTick(self, tickLower);
                }
                if (state.flippedUpper) {
                    clearTick(self, tickUpper);
                }
            }
        }

        if (liquidityDelta != 0) {
            Slot0 _slot0 = self.slot0;
            (int24 tick, uint160 sqrtPriceX96) = (_slot0.tick(), _slot0.sqrtPriceX96());
            if (tick < tickLower) {
                // current tick is below the passed range; liquidity can only become in range by crossing from left to
                // right, when we'll need _more_ currency0 (it's becoming more valuable) so user must provide it
                delta = toBalanceDelta(
                    SqrtPriceMath.getAmount0Delta(
                        TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidityDelta
                    ).toInt128(),
                    0
                );
            } else if (tick < tickUpper) {
                delta = toBalanceDelta(
                    SqrtPriceMath.getAmount0Delta(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickUpper), liquidityDelta)
                        .toInt128(),
                    SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceX96, liquidityDelta)
                        .toInt128()
                );

                self.liquidity = LiquidityMath.addDelta(self.liquidity, liquidityDelta);
            } else {
                // current tick is above the passed range; liquidity can only become in range by crossing from right to
                // left, when we'll need _more_ currency1 (it's becoming more valuable) so user must provide it
                delta = toBalanceDelta(
                    0,
                    SqrtPriceMath.getAmount1Delta(
                        TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liquidityDelta
                    ).toInt128()
                );
            }
        }
    }

    // Tracks the state of a pool throughout a swap, and returns these values at the end of the swap
    struct SwapResult {
        // the current sqrt(price)
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        int24 tick;
        // the current liquidity in range
        uint128 liquidity;
    }

    struct StepComputations {
        // the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
        // the global fee growth of the input token. updated in storage at the end of swap
        uint256 feeGrowthGlobalX128;
    }

    struct SwapParams {
        int256 amountSpecified;
        int24 tickSpacing;
        bool zeroForOne;
        uint160 sqrtPriceLimitX96;
        uint24 lpFeeOverride;
    }

    /// @notice Executes a swap against the state, and returns the amount deltas of the pool
    /// @dev PoolManager checks that the pool is initialized before calling
    function swap(State storage self, SwapParams memory params)
        internal
        returns (BalanceDelta swapDelta, uint256 amountToProtocol, uint24 swapFee, SwapResult memory result)
    {
        Slot0 slot0Start = self.slot0;
        bool zeroForOne = params.zeroForOne;

        uint256 protocolFee =
            zeroForOne ? slot0Start.protocolFee().getZeroForOneFee() : slot0Start.protocolFee().getOneForZeroFee();

        // the amount remaining to be swapped in/out of the input/output asset. initially set to the amountSpecified
        int256 amountSpecifiedRemaining = params.amountSpecified;
        // the amount swapped out/in of the output/input asset. initially set to 0
        int256 amountCalculated = 0;
        // initialize to the current sqrt(price)
        result.sqrtPriceX96 = slot0Start.sqrtPriceX96();
        // initialize to the current tick
        result.tick = slot0Start.tick();
        // initialize to the current liquidity
        result.liquidity = self.liquidity;

        // if the beforeSwap hook returned a valid fee override, use that as the LP fee, otherwise load from storage
        // lpFee, swapFee, and protocolFee are all in pips
        {
            uint24 lpFee = params.lpFeeOverride.isOverride()
                ? params.lpFeeOverride.removeOverrideFlagAndValidate()
                : slot0Start.lpFee();

            swapFee = protocolFee == 0 ? lpFee : uint16(protocolFee).calculateSwapFee(lpFee);
        }

        // a swap fee totaling MAX_SWAP_FEE (100%) makes exact output swaps impossible since the input is entirely consumed by the fee
        if (swapFee >= SwapMath.MAX_SWAP_FEE) {
            // if exactOutput
            if (params.amountSpecified > 0) {
                InvalidFeeForExactOut.selector.revertWith();
            }
        }

        // swapFee is the pool's fee in pips (LP fee + protocol fee)
        // when the amount swapped is 0, there is no protocolFee applied and the fee amount paid to the protocol is set to 0
        if (params.amountSpecified == 0) return (BalanceDeltaLibrary.ZERO_DELTA, 0, swapFee, result);

        if (zeroForOne) {
            if (params.sqrtPriceLimitX96 >= slot0Start.sqrtPriceX96()) {
                PriceLimitAlreadyExceeded.selector.revertWith(slot0Start.sqrtPriceX96(), params.sqrtPriceLimitX96);
            }
            // Swaps can never occur at MIN_TICK, only at MIN_TICK + 1, except at initialization of a pool
            // Under certain circumstances outlined below, the tick will preemptively reach MIN_TICK without swapping there
            if (params.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) {
                PriceLimitOutOfBounds.selector.revertWith(params.sqrtPriceLimitX96);
            }
        } else {
            if (params.sqrtPriceLimitX96 <= slot0Start.sqrtPriceX96()) {
                PriceLimitAlreadyExceeded.selector.revertWith(slot0Start.sqrtPriceX96(), params.sqrtPriceLimitX96);
            }
            if (params.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
                PriceLimitOutOfBounds.selector.revertWith(params.sqrtPriceLimitX96);
            }
        }

        StepComputations memory step;
        step.feeGrowthGlobalX128 = zeroForOne ? self.feeGrowthGlobal0X128 : self.feeGrowthGlobal1X128;

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        while (!(amountSpecifiedRemaining == 0 || result.sqrtPriceX96 == params.sqrtPriceLimitX96)) {
            step.sqrtPriceStartX96 = result.sqrtPriceX96;

            (step.tickNext, step.initialized) =
                self.tickBitmap.nextInitializedTickWithinOneWord(result.tick, params.tickSpacing, zeroForOne);

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (step.tickNext <= TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            }
            if (step.tickNext >= TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtPriceAtTick(step.tickNext);

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            (result.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                result.sqrtPriceX96,
                SwapMath.getSqrtPriceTarget(zeroForOne, step.sqrtPriceNextX96, params.sqrtPriceLimitX96),
                result.liquidity,
                amountSpecifiedRemaining,
                swapFee
            );

            // if exactOutput
            if (params.amountSpecified > 0) {
                unchecked {
                    amountSpecifiedRemaining -= step.amountOut.toInt256();
                }
                amountCalculated -= (step.amountIn + step.feeAmount).toInt256();
            } else {
                // safe because we test that amountSpecified > amountIn + feeAmount in SwapMath
                unchecked {
                    amountSpecifiedRemaining += (step.amountIn + step.feeAmount).toInt256();
                }
                amountCalculated += step.amountOut.toInt256();
            }

            // if the protocol fee is on, calculate how much is owed, decrement feeAmount, and increment protocolFee
            if (protocolFee > 0) {
                unchecked {
                    // step.amountIn does not include the swap fee, as it's already been taken from it,
                    // so add it back to get the total amountIn and use that to calculate the amount of fees owed to the protocol
                    // this line cannot overflow due to limits on the size of protocolFee and params.amountSpecified
                    uint256 delta = (step.amountIn + step.feeAmount) * protocolFee / ProtocolFeeLibrary.PIPS_DENOMINATOR;
                    // subtract it from the total fee and add it to the protocol fee
                    step.feeAmount -= delta;
                    amountToProtocol += delta;
                }
            }

            // update global fee tracker
            if (result.liquidity > 0) {
                unchecked {
                    // FullMath.mulDiv isn't needed as the numerator can't overflow uint256 since tokens have a max supply of type(uint128).max
                    step.feeGrowthGlobalX128 +=
                        UnsafeMath.simpleMulDiv(step.feeAmount, FixedPoint128.Q128, result.liquidity);
                }
            }

            // Shift tick if we reached the next price, and preemptively decrement for zeroForOne swaps to tickNext - 1.
            // If the swap doesnt continue (if amountRemaining == 0 or sqrtPriceLimit is met), slot0.tick will be 1 less
            // than getTickAtSqrtPrice(slot0.sqrtPrice). This doesn't affect swaps, but donation calls should verify both
            // price and tick to reward the correct LPs.
            if (result.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = zeroForOne
                        ? (step.feeGrowthGlobalX128, self.feeGrowthGlobal1X128)
                        : (self.feeGrowthGlobal0X128, step.feeGrowthGlobalX128);
                    int128 liquidityNet =
                        Pool.crossTick(self, step.tickNext, feeGrowthGlobal0X128, feeGrowthGlobal1X128);
                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    unchecked {
                        if (zeroForOne) liquidityNet = -liquidityNet;
                    }

                    result.liquidity = LiquidityMath.addDelta(result.liquidity, liquidityNet);
                }

                unchecked {
                    result.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
                }
            } else if (result.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                result.tick = TickMath.getTickAtSqrtPrice(result.sqrtPriceX96);
            }
        }

        self.slot0 = slot0Start.setTick(result.tick).setSqrtPriceX96(result.sqrtPriceX96);

        // update liquidity if it changed
        if (self.liquidity != result.liquidity) self.liquidity = result.liquidity;

        // update fee growth global
        if (!zeroForOne) {
            self.feeGrowthGlobal1X128 = step.feeGrowthGlobalX128;
        } else {
            self.feeGrowthGlobal0X128 = step.feeGrowthGlobalX128;
        }

        unchecked {
            // "if currency1 is specified"
            if (zeroForOne != (params.amountSpecified < 0)) {
                swapDelta = toBalanceDelta(
                    amountCalculated.toInt128(), (params.amountSpecified - amountSpecifiedRemaining).toInt128()
                );
            } else {
                swapDelta = toBalanceDelta(
                    (params.amountSpecified - amountSpecifiedRemaining).toInt128(), amountCalculated.toInt128()
                );
            }
        }
    }

    /// @notice Donates the given amount of currency0 and currency1 to the pool
    function donate(State storage state, uint256 amount0, uint256 amount1) internal returns (BalanceDelta delta) {
        uint128 liquidity = state.liquidity;
        if (liquidity == 0) NoLiquidityToReceiveFees.selector.revertWith();
        unchecked {
            // negation safe as amount0 and amount1 are always positive
            delta = toBalanceDelta(-(amount0.toInt128()), -(amount1.toInt128()));
            // FullMath.mulDiv is unnecessary because the numerator is bounded by type(int128).max * Q128, which is less than type(uint256).max
            if (amount0 > 0) {
                state.feeGrowthGlobal0X128 += UnsafeMath.simpleMulDiv(amount0, FixedPoint128.Q128, liquidity);
            }
            if (amount1 > 0) {
                state.feeGrowthGlobal1X128 += UnsafeMath.simpleMulDiv(amount1, FixedPoint128.Q128, liquidity);
            }
        }
    }

    /// @notice Retrieves fee growth data
    /// @param self The Pool state struct
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @return feeGrowthInside0X128 The all-time fee growth in token0, per unit of liquidity, inside the position's tick boundaries
    /// @return feeGrowthInside1X128 The all-time fee growth in token1, per unit of liquidity, inside the position's tick boundaries
    function getFeeGrowthInside(State storage self, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        TickInfo storage lower = self.ticks[tickLower];
        TickInfo storage upper = self.ticks[tickUpper];
        int24 tickCurrent = self.slot0.tick();

        unchecked {
            if (tickCurrent < tickLower) {
                feeGrowthInside0X128 = lower.feeGrowthOutside0X128 - upper.feeGrowthOutside0X128;
                feeGrowthInside1X128 = lower.feeGrowthOutside1X128 - upper.feeGrowthOutside1X128;
            } else if (tickCurrent >= tickUpper) {
                feeGrowthInside0X128 = upper.feeGrowthOutside0X128 - lower.feeGrowthOutside0X128;
                feeGrowthInside1X128 = upper.feeGrowthOutside1X128 - lower.feeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 =
                    self.feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128 - upper.feeGrowthOutside0X128;
                feeGrowthInside1X128 =
                    self.feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128 - upper.feeGrowthOutside1X128;
            }
        }
    }

    /// @notice Retrieves loss growth data (loss for perp traders, profit for LPs)
    /// @param self The Pool state struct
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @return lossGrowthInside0X128 The all-time loss growth in token0, per unit of liquidity, inside the position's tick boundaries
    /// @return lossGrowthInside1X128 The all-time loss growth in token1, per unit of liquidity, inside the position's tick boundaries
    function getLossGrowthInside(State storage self, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 lossGrowthInside0X128, uint256 lossGrowthInside1X128)
    {
        TickInfo storage lower = self.ticks[tickLower];
        TickInfo storage upper = self.ticks[tickUpper];
        int24 tickCurrent = self.slot0.tick();

        unchecked {
            if (tickCurrent < tickLower) {
                lossGrowthInside0X128 = lower.lossGrowthOutside0X128 - upper.lossGrowthOutside0X128;
                lossGrowthInside1X128 = lower.lossGrowthOutside1X128 - upper.lossGrowthOutside1X128;
            } else if (tickCurrent >= tickUpper) {
                lossGrowthInside0X128 = upper.lossGrowthOutside0X128 - lower.lossGrowthOutside0X128;
                lossGrowthInside1X128 = upper.lossGrowthOutside1X128 - lower.lossGrowthOutside1X128;
            } else {
                lossGrowthInside0X128 =
                    self.lossGrowthGlobal0X128 - lower.lossGrowthOutside0X128 - upper.lossGrowthOutside0X128;
                lossGrowthInside1X128 =
                    self.lossGrowthGlobal1X128 - lower.lossGrowthOutside1X128 - upper.lossGrowthOutside1X128;
            }
        }
    }

    /// @notice Retrieves gain growth data (gain for perp traders, loss for LPs)
    /// @param self The Pool state struct
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @return gainGrowthInside0X128 The all-time gain growth in token0, per unit of liquidity, inside the position's tick boundaries
    /// @return gainGrowthInside1X128 The all-time gain growth in token1, per unit of liquidity, inside the position's tick boundaries
    function getGainGrowthInside(State storage self, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 gainGrowthInside0X128, uint256 gainGrowthInside1X128)
    {
        TickInfo storage lower = self.ticks[tickLower];
        TickInfo storage upper = self.ticks[tickUpper];
        int24 tickCurrent = self.slot0.tick();

        unchecked {
            if (tickCurrent < tickLower) {
                gainGrowthInside0X128 = lower.gainGrowthOutside0X128 - upper.gainGrowthOutside0X128;
                gainGrowthInside1X128 = lower.gainGrowthOutside1X128 - upper.gainGrowthOutside1X128;
            } else if (tickCurrent >= tickUpper) {
                gainGrowthInside0X128 = upper.gainGrowthOutside0X128 - lower.gainGrowthOutside0X128;
                gainGrowthInside1X128 = upper.gainGrowthOutside1X128 - lower.gainGrowthOutside1X128;
            } else {
                gainGrowthInside0X128 =
                    self.gainGrowthGlobal0X128 - lower.gainGrowthOutside0X128 - upper.gainGrowthOutside0X128;
                gainGrowthInside1X128 =
                    self.gainGrowthGlobal1X128 - lower.gainGrowthOutside1X128 - upper.gainGrowthOutside1X128;
            }
        }
    }

    /// @notice Updates a tick and returns true if the tick was flipped from initialized to uninitialized, or vice versa
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The tick that will be updated
    /// @param liquidityDelta A new amount of liquidity to be added (subtracted) when tick is crossed from left to right (right to left)
    /// @param upper true for updating a position's upper tick, or false for updating a position's lower tick
    /// @return flipped Whether the tick was flipped from initialized to uninitialized, or vice versa
    /// @return liquidityGrossAfter The total amount of liquidity for all positions that references the tick after the update
    function updateTick(State storage self, int24 tick, int128 liquidityDelta, bool upper)
        internal
        returns (bool flipped, uint128 liquidityGrossAfter)
    {
        TickInfo storage info = self.ticks[tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        int128 liquidityNetBefore = info.liquidityNet;

        liquidityGrossAfter = LiquidityMath.addDelta(liquidityGrossBefore, liquidityDelta);

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            // by convention, we assume that all growth before a tick was initialized happened _below_ the tick
            if (tick <= self.slot0.tick()) {
                info.feeGrowthOutside0X128 = self.feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = self.feeGrowthGlobal1X128;
            }
        }

        // when the lower (upper) tick is crossed left to right (right to left), liquidity must be added (removed)
        int128 liquidityNet = upper ? liquidityNetBefore - liquidityDelta : liquidityNetBefore + liquidityDelta;
        assembly ("memory-safe") {
            // liquidityGrossAfter and liquidityNet are packed in the first slot of `info`
            // So we can store them with a single sstore by packing them ourselves first
            sstore(
                info.slot,
                // bitwise OR to pack liquidityGrossAfter and liquidityNet
                or(
                    // Put liquidityGrossAfter in the lower bits, clearing out the upper bits
                    and(liquidityGrossAfter, 0xffffffffffffffffffffffffffffffff),
                    // Shift liquidityNet to put it in the upper bits (no need for signextend since we're shifting left)
                    shl(128, liquidityNet)
                )
            )
        }
    }

    /// @notice Derives max liquidity per tick from given tick spacing
    /// @dev Executed when adding liquidity
    /// @param tickSpacing The amount of required tick separation, realized in multiples of `tickSpacing`
    ///     e.g., a tickSpacing of 3 requires ticks to be initialized every 3rd tick i.e., ..., -6, -3, 0, 3, 6, ...
    /// @return result The max liquidity per tick
    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128 result) {
        // Equivalent to:
        // int24 minTick = (TickMath.MIN_TICK / tickSpacing);
        // int24 maxTick = (TickMath.MAX_TICK / tickSpacing);
        // uint24 numTicks = maxTick - minTick + 1;
        // return type(uint128).max / numTicks;
        int24 MAX_TICK = TickMath.MAX_TICK;
        int24 MIN_TICK = TickMath.MIN_TICK;
        // tick spacing will never be 0 since TickMath.MIN_TICK_SPACING is 1
        assembly ("memory-safe") {
            tickSpacing := signextend(2, tickSpacing)
            let minTick := sub(sdiv(MIN_TICK, tickSpacing), slt(smod(MIN_TICK, tickSpacing), 0))
            let maxTick := sdiv(MAX_TICK, tickSpacing)
            let numTicks := add(sub(maxTick, minTick), 1)
            result := div(sub(shl(128, 1), 1), numTicks)
        }
    }

    /// @notice Reverts if the given pool has not been initialized
    function checkPoolInitialized(State storage self) internal view {
        if (self.slot0.sqrtPriceX96() == 0) PoolNotInitialized.selector.revertWith();
    }

    /// @notice Clears tick data
    /// @param self The mapping containing all initialized tick information for initialized ticks
    /// @param tick The tick that will be cleared
    function clearTick(State storage self, int24 tick) internal {
        delete self.ticks[tick];
    }

    /// @notice Transitions to next tick as needed by price movement
    /// @param self The Pool state struct
    /// @param tick The destination tick of the transition
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1
    /// @return liquidityNet The amount of liquidity added (subtracted) when tick is crossed from left to right (right to left)
    function crossTick(State storage self, int24 tick, uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128)
        internal
        returns (int128 liquidityNet)
    {
        unchecked {
            TickInfo storage info = self.ticks[tick];
            info.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - info.feeGrowthOutside0X128;
            info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;
            liquidityNet = info.liquidityNet;
        }
    }

    // new functions by #4lsh4

    /**
    * @dev Blocks liquidity for a perpetual position within a specific tick range.
    *      This function calculates the lower and upper ticks based on the current tick and the tick spacing,
    *      then checks whether there is enough liquidity available and updates the blocked liquidity accordingly.
    * 
    * @param self The state of the pool, containing all liquidity and tick information.
    * @param liquidityDelta The amount of liquidity to block (must be positive).
    * @param tickSpacing The current tick of the pool when the perpetual position is opened.
    */
    function blockLiquidity(State storage self, int128 liquidityDelta, int24 tickSpacing) internal {
        require(liquidityDelta > 0, "Must be positive for blocking liquidity");

        // int24 currentTick = TickMath.getTickAtSqrtPrice(self.slot0.sqrtPriceX96());
        int24 currentTick = self.slot0.tick();

        // Calculate the lower and upper ticks based on the current tick and tick spacing
        int24 tickLower = currentTick - (currentTick % tickSpacing);
        int24 tickUpper = tickLower + tickSpacing;

        // Ensure there is enough liquidity to block in the relevant tick range
        checkAvailableLiquidity(self, liquidityDelta, tickLower, tickUpper);

        // Block liquidity for the lower tick
        self.ticks[tickLower].blockedLiquidityGross = LiquidityMath.addDelta(self.ticks[tickLower].blockedLiquidityGross, liquidityDelta);

        // Block liquidity for the upper tick
        self.ticks[tickUpper].blockedLiquidityGross = LiquidityMath.addDelta(self.ticks[tickUpper].blockedLiquidityGross, liquidityDelta);
    }

    /**
     * @dev Ensures that sufficient active liquidity exists for blocking the requested amount
     * @param self The pool's state
     * @param liquidityDelta The amount of liquidity to block
     * @param tickLower The lower tick boundary
     * @param tickUpper The upper tick boundary
     */
    function checkAvailableLiquidity(State storage self, int128 liquidityDelta, int24 tickLower, int24 tickUpper) internal view {
        // Check available liquidity in the lower tick
        uint128 availableLiquidityLower = self.ticks[tickLower].liquidityGross - self.ticks[tickLower].blockedLiquidityGross;
        require(availableLiquidityLower >= uint128(liquidityDelta), "Insufficient liquidity in lower tick");

        // Check available liquidity in the upper tick
        uint128 availableLiquidityUpper = self.ticks[tickUpper].liquidityGross - self.ticks[tickUpper].blockedLiquidityGross;
        require(availableLiquidityUpper >= uint128(liquidityDelta), "Insufficient liquidity in upper tick");
    }

    /**
    * @dev Unblocks liquidity for a perpetual position within a specific tick range.
    *      This function calculates the lower and upper ticks based on the current tick and tick spacing,
    *      then checks and unblocks the liquidity that was blocked during the opening of the position.
    *
    * @param self The state of the pool, containing all liquidity and tick information.
    * @param liquidityDelta The amount of liquidity to unblock (must be positive).
    * @param tickLower The tickLower was used to block liquidty when the position was opened.
    * @param tickUpper The tickUpper was used to block liquidty when the position was opened.
    */
    function unblockLiquidity(State storage self, int128 liquidityDelta, int24 tickLower, int24 tickUpper) internal {
        require(liquidityDelta < 0, "Must be negative for unblocking liquidity");

        // Ensure there is enough blocked liquidity to unblock in the relevant tick range
        checkBlockedLiquidity(self, liquidityDelta, tickLower, tickUpper);

        // Unblock liquidity for the lower tick
        self.ticks[tickLower].blockedLiquidityGross = LiquidityMath.addDelta(self.ticks[tickLower].blockedLiquidityGross, liquidityDelta);

        // Unblock liquidity for the upper tick
        self.ticks[tickUpper].blockedLiquidityGross = LiquidityMath.addDelta(self.ticks[tickUpper].blockedLiquidityGross, liquidityDelta);
    }

    /**
    * @dev Ensures that there is enough blocked liquidity to unblock the requested amount
    * @param self The pool's state
    * @param liquidityDelta The amount of liquidity to unblock
    * @param tickLower The lower tick boundary
    * @param tickUpper The upper tick boundary
    */
    function checkBlockedLiquidity(State storage self, int128 liquidityDelta, int24 tickLower, int24 tickUpper) internal view {
        // Check blocked liquidity in the lower tick
        uint128 blockedLiquidityLower = self.ticks[tickLower].blockedLiquidityGross;
        require(blockedLiquidityLower >= uint128(liquidityDelta), "Insufficient blocked liquidity in lower tick");

        // Check blocked liquidity in the upper tick
        uint128 blockedLiquidityUpper = self.ticks[tickUpper].blockedLiquidityGross;
        require(blockedLiquidityUpper >= uint128(liquidityDelta), "Insufficient blocked liquidity in upper tick");
    }

    /**
    * @notice Sends the profit in token0 and token1 to a trader after a successful trade.
    * @dev This function calculates the required liquidity to cover the profit amounts using the SqrtPriceMath library.
    *      It ensures there is sufficient liquidity in the tick range (liquidityGross), deducts the necessary liquidity, 
    *      and transfers the corresponding token amounts to the trader. The function also handles cases where the lowerTick 
    *      does not have enough liquidity by drawing from the upperTick if necessary.
    * @param self The state of the liquidity pool
    * @param profitAmount0 The profit amount in token0 to be paid to the trader
    * @param profitAmount1 The profit amount in token1 to be paid to the trader
    * @param tickLower The lower bound of the tick range in which the position was opened
    * @param tickUpper The upper bound of the tick range in which the position was opened
    */
    function updateFromTraderProfit(
        State storage self, 
        uint256 profitAmount0, 
        uint256 profitAmount1, 
        int24 tickLower, 
        int24 tickUpper
    ) internal {
        // Get the sqrt prices for the lower and upper ticks from the TickMath library
        // These are used to calculate the liquidity required for profit amounts
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        // Calculate the required liquidity for the profit in token0 using SqrtPriceMath
        // This calculates how much liquidity is needed to cover the token0 profit amount in the specified price range
        uint128 liquidityDelta0 = SqrtPriceMath.getLiquidityForAmount0(sqrtPriceLower, sqrtPriceUpper, profitAmount0);

        // Calculate the required liquidity for the profit in token1 using SqrtPriceMath
        // This calculates how much liquidity is needed to cover the token1 profit amount in the same price range
        uint128 liquidityDelta1 = SqrtPriceMath.getLiquidityForAmount1(sqrtPriceLower, sqrtPriceUpper, profitAmount1);

        // Use the maximum liquidity requirement between token0 and token1
        // The maximum of liquidityDelta0 and liquidityDelta1 is used since liquidity covers both tokens simultaneously
        uint128 requiredLiquidity = liquidityDelta0 > liquidityDelta1 ? liquidityDelta0 : liquidityDelta1;

        // Ensure the total liquidityGross in the tick range is sufficient to cover the required liquidity
        // This ensures that there is enough total liquidity in both the lower and upper ticks to cover the profit
        TickInfo storage lowerTick = self.ticks[tickLower];
        TickInfo storage upperTick = self.ticks[tickUpper];

        uint128 totalLiquidityInRange = lowerTick.liquidityGross + upperTick.liquidityGross;

        require(
            totalLiquidityInRange >= requiredLiquidity, 
            "Not enough liquidity in tick range to cover profit"
        );

        // Determine if liquidity needs to come from the lower tick, upper tick, or both
        if (self.slot0.tick() < tickLower) {
            // Current tick is below the lower range, so use liquidity from lowerTick first
            if (lowerTick.liquidityGross >= requiredLiquidity) {
                // Lower tick has enough liquidity
                lowerTick.liquidityGross -= requiredLiquidity;
            } else {
                // Lower tick does not have enough liquidity, deduct what we can
                uint128 remainingLiquidity = requiredLiquidity - lowerTick.liquidityGross;
                lowerTick.liquidityGross = 0; // Empty lowerTick
                upperTick.liquidityGross -= remainingLiquidity; // Deduct the remaining liquidity from upperTick
            }
        } else if (self.slot0.tick() >= tickUpper) {
            // Current tick is above or at the upper range, so use liquidity from upperTick first
            if (upperTick.liquidityGross >= requiredLiquidity) {
                // Upper tick has enough liquidity
                upperTick.liquidityGross -= requiredLiquidity;
            } else {
                // Upper tick does not have enough liquidity, deduct what we can
                uint128 remainingLiquidity = requiredLiquidity - upperTick.liquidityGross;
                upperTick.liquidityGross = 0; // Empty lowerTick
                lowerTick.liquidityGross -= remainingLiquidity; // Deduct the remaining liquidity from lowerTick
            }
        } else {
            // Current tick is within the range, split liquidity between lowerTick and upperTick
            uint128 liquidityFromLower = lowerTick.liquidityGross > requiredLiquidity 
                ? requiredLiquidity 
                : lowerTick.liquidityGross;

            lowerTick.liquidityGross -= liquidityFromLower;
            upperTick.liquidityGross -= (requiredLiquidity - liquidityFromLower);
        }

        // Transfer the calculated profits (in token0 and token1) to the trader's address
        // transferTokens(trader, profitAmount0, profitAmount1);
    }

    /**
    * @dev Updates the loss growth variables when a perpetual position is liquidated or closed with a loss.
    *      This ensures that LPs are rewarded with the proportional share of the trader's loss.
    * 
    * @param self The state of the pool.
    * @param lossAmount0 The amount of token0 loss to be distributed.
    * @param lossAmount1 The amount of token1 loss to be distributed.
    * @param tickLower The lower tick of the position range.
    * @param tickUpper The upper tick of the position range.
    */
    function updateLossGrowthOnLiquidationOrLoss(
        State storage self,
        uint256 lossAmount0,
        uint256 lossAmount1,
        int24 tickLower,
        int24 tickUpper
    ) internal {
        // 1. Update the global loss growth
        uint256 liquidity = self.liquidity; // The current active liquidity in the pool

        // Calculate the loss per unit of liquidity (scaled to X128 to match Uniswap precision)
        uint256 lossGrowthPerLiquidityUnit0 = (lossAmount0 << 128) / liquidity;
        uint256 lossGrowthPerLiquidityUnit1 = (lossAmount1 << 128) / liquidity;

        // Update global loss growth for token0 and token1
        self.lossGrowthGlobal0X128 += lossGrowthPerLiquidityUnit0;
        self.lossGrowthGlobal1X128 += lossGrowthPerLiquidityUnit1;

        // 2. Update the per-tick loss growth outside variables for tickLower and tickUpper
        updateTickLossGrowth(self, tickLower, lossGrowthPerLiquidityUnit0, lossGrowthPerLiquidityUnit1);
        updateTickLossGrowth(self, tickUpper, lossGrowthPerLiquidityUnit0, lossGrowthPerLiquidityUnit1);
    }

    /**
    * @dev Updates the loss growth outside for a specific tick.
    * @param self The state of the pool.
    * @param tick The tick to update.
    * @param lossGrowthUnit0 The loss growth per unit of liquidity for token0.
    * @param lossGrowthUnit1 The loss growth per unit of liquidity for token1.
    */
    function updateTickLossGrowth(
        State storage self,
        int24 tick,
        uint256 lossGrowthUnit0,
        uint256 lossGrowthUnit1
    ) internal {
        // Access the tick info for the given tick
        TickInfo storage tickInfo = self.ticks[tick];

        // Update the loss growth outside values for the tick
        tickInfo.lossGrowthOutside0X128 += lossGrowthUnit0;
        tickInfo.lossGrowthOutside1X128 += lossGrowthUnit1;
    }

    /**
    * @dev Updates the gain growth variables when a perpetual position is closed with a profit.
    *      This ensures that LPs incur the proportional share of the trader's gain (equivalent to LP's loss).
    * 
    * @param self The state of the pool.
    * @param gainAmount0 The amount of token0 profit (loss for LPs) to be distributed.
    * @param gainAmount1 The amount of token1 profit (loss for LPs) to be distributed.
    * @param tickLower The lower tick of the position range.
    * @param tickUpper The upper tick of the position range.
    */
    function updateGainGrowthOnProfit(
        State storage self,
        uint256 gainAmount0,
        uint256 gainAmount1,
        int24 tickLower,
        int24 tickUpper
    ) internal {
        // 1. Update the global gain growth
        uint256 liquidity = self.liquidity; // The current active liquidity in the pool

        // Calculate the gain per unit of liquidity (scaled to X128 to match Uniswap precision)
        uint256 gainGrowthPerLiquidityUnit0 = (gainAmount0 << 128) / liquidity;
        uint256 gainGrowthPerLiquidityUnit1 = (gainAmount1 << 128) / liquidity;

        // Update global gain growth for token0 and token1
        self.gainGrowthGlobal0X128 += gainGrowthPerLiquidityUnit0;
        self.gainGrowthGlobal1X128 += gainGrowthPerLiquidityUnit1;

        // 2. Update the per-tick gain growth outside variables for tickLower and tickUpper
        updateTickGainGrowth(self, tickLower, gainGrowthPerLiquidityUnit0, gainGrowthPerLiquidityUnit1);
        updateTickGainGrowth(self, tickUpper, gainGrowthPerLiquidityUnit0, gainGrowthPerLiquidityUnit1);
    }

    /**
    * @dev Updates the gain growth outside for a specific tick.
    * @param self The state of the pool.
    * @param tick The tick to update.
    * @param gainGrowthUnit0 The gain growth per unit of liquidity for token0.
    * @param gainGrowthUnit1 The gain growth per unit of liquidity for token1.
    */
    function updateTickGainGrowth(
        State storage self,
        int24 tick,
        uint256 gainGrowthUnit0,
        uint256 gainGrowthUnit1
    ) internal {
        // Access the tick info for the given tick
        TickInfo storage tickInfo = self.ticks[tick];

        // Update the gain growth outside values for the tick
        tickInfo.gainGrowthOutside0X128 += gainGrowthUnit0;
        tickInfo.gainGrowthOutside1X128 += gainGrowthUnit1;
    }

    /**
    * @dev Calculates the liquidity delta required to open a leveraged position based on the current tick and tick spacing.
    *      The function derives the lower and upper ticks from the current tick, calculates the respective sqrt prices,
    *      and computes the liquidity delta accordingly.
    * 
    * @param self The state of the pool, containing the current slot and liquidity information.
    * @param positionSize The total position size (size * leverage).
    * @param tickSpacing The tick spacing of the pool.
    * @return liquidityDelta The calculated liquidity delta required to open the position.
    */
    function calculateLiquidityDelta(
        State storage self, 
        uint256 positionSize,
        int24 tickSpacing
    ) internal view returns (uint128 liquidityDelta, int24 tickLower, int24 tickUpper) {
        // Get the current tick from the pool state
        int24 currentTick = self.slot0.tick();

        // Derive the lower and upper ticks based on the current tick and tick spacing
        tickLower = currentTick - (currentTick % tickSpacing);
        tickUpper = tickLower + tickSpacing;

        // Get the sqrt prices for the lower and upper ticks from the TickMath library
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        // Calculate liquidity delta for token0, using SqrtPriceMath for the given price range
        uint128 liquidityDeltaToken0 = SqrtPriceMath.getLiquidityForAmount0(
            sqrtPriceLower, 
            sqrtPriceUpper, 
            positionSize
        );

        // Calculate liquidity delta for token1, using SqrtPriceMath for the given price range
        uint128 liquidityDeltaToken1 = SqrtPriceMath.getLiquidityForAmount1(
            sqrtPriceLower, 
            sqrtPriceUpper, 
            positionSize
        );

        // Return the maximum of both liquidity deltas (as liquidity covers both token0 and token1)
        liquidityDelta = liquidityDeltaToken0 > liquidityDeltaToken1 ? liquidityDeltaToken0 : liquidityDeltaToken1;
    }
}
