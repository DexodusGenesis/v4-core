// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {FullMath} from "./FullMath.sol";
import {FixedPoint128} from "./FixedPoint128.sol";
import {LiquidityMath} from "./LiquidityMath.sol";
import {CustomRevert} from "./CustomRevert.sol";

/// @title Position
/// @notice Positions represent an owner address' liquidity between a lower and upper tick boundary
/// @dev Positions store additional state for tracking fees owed to the position
library Position {
    using CustomRevert for bytes4;

    /// @notice Cannot update a position with no liquidity
    error CannotUpdateEmptyPosition();

    // info stored for each user's position
    struct State {
        // the amount of liquidity owned by this position
        uint128 liquidity;
        // fee growth per unit of liquidity as of the last update to liquidity or fees owed
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // loss growth per unit of liquidity as of the last update to liquidity (perp trader loss, profit for the LP)
        uint256 lossGrowthInside0LastX128;
        uint256 lossGrowthInside1LastX128;
        // gain growth per unit of liquidity as of the last update to liquidity (perp trader profits, loss for the LP)
        uint256 gainGrowthInside0LastX128;
        uint256 gainGrowthInside1LastX128;
    }

    /// @notice Returns the State struct of a position, given an owner and position boundaries
    /// @param self The mapping containing all user positions
    /// @param owner The address of the position owner
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @param salt A unique value to differentiate between multiple positions in the same range
    /// @return position The position info struct of the given owners' position
    function get(mapping(bytes32 => State) storage self, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        view
        returns (State storage position)
    {
        bytes32 positionKey = calculatePositionKey(owner, tickLower, tickUpper, salt);
        position = self[positionKey];
    }

    /// @notice A helper function to calculate the position key
    /// @param owner The address of the position owner
    /// @param tickLower the lower tick boundary of the position
    /// @param tickUpper the upper tick boundary of the position
    /// @param salt A unique value to differentiate between multiple positions in the same range, by the same owner. Passed in by the caller.
    function calculatePositionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32 positionKey)
    {
        // positionKey = keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt))
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            mstore(add(fmp, 0x26), salt) // [0x26, 0x46)
            mstore(add(fmp, 0x06), tickUpper) // [0x23, 0x26)
            mstore(add(fmp, 0x03), tickLower) // [0x20, 0x23)
            mstore(fmp, owner) // [0x0c, 0x20)
            positionKey := keccak256(add(fmp, 0x0c), 0x3a) // len is 58 bytes

            // now clean the memory we used
            mstore(add(fmp, 0x40), 0) // fmp+0x40 held salt
            mstore(add(fmp, 0x20), 0) // fmp+0x20 held tickLower, tickUpper, salt
            mstore(fmp, 0) // fmp held owner
        }
    }

    /// @notice Credits accumulated fees to a user's position
    /// @param self The individual position to update
    /// @param liquidityDelta The change in pool liquidity as a result of the position update
    /// @param feeGrowthInside0X128 The all-time fee growth in currency0, per unit of liquidity, inside the position's tick boundaries
    /// @param feeGrowthInside1X128 The all-time fee growth in currency1, per unit of liquidity, inside the position's tick boundaries
    /// @return feesOwed0 The amount of currency0 owed to the position owner
    /// @return feesOwed1 The amount of currency1 owed to the position owner
    function update(
        State storage self,
        int128 liquidityDelta,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) internal returns (uint256 feesOwed0, uint256 feesOwed1) {
        uint128 liquidity = self.liquidity;

        if (liquidityDelta == 0) {
            // disallow pokes for 0 liquidity positions
            if (liquidity == 0) CannotUpdateEmptyPosition.selector.revertWith();
        } else {
            self.liquidity = LiquidityMath.addDelta(liquidity, liquidityDelta);
        }

        // calculate accumulated fees. overflow in the subtraction of fee growth is expected
        unchecked {
            feesOwed0 =
                FullMath.mulDiv(feeGrowthInside0X128 - self.feeGrowthInside0LastX128, liquidity, FixedPoint128.Q128);
            feesOwed1 =
                FullMath.mulDiv(feeGrowthInside1X128 - self.feeGrowthInside1LastX128, liquidity, FixedPoint128.Q128);
        }

        // update the position
        self.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        self.feeGrowthInside1LastX128 = feeGrowthInside1X128;
    }

    /**
    * @dev Updates the loss and gain growth variables for a position.
    *      This function calculates the accumulated losses (profit for LPs) and gains (loss for LPs)
    *      based on the difference between the global loss/gain growth and the position's last recorded values.
    * @param self The position state to update.
    * @param lossGrowthInside0X128 The all-time loss growth in token0, per unit of liquidity, inside the position's tick boundaries.
    * @param lossGrowthInside1X128 The all-time loss growth in token1, per unit of liquidity, inside the position's tick boundaries.
    * @param gainGrowthInside0X128 The all-time gain growth in token0, per unit of liquidity, inside the position's tick boundaries.
    * @param gainGrowthInside1X128 The all-time gain growth in token1, per unit of liquidity, inside the position's tick boundaries.
    */
    function updateLossAndGainGrowth(
        State storage self,
        uint256 lossGrowthInside0X128,
        uint256 lossGrowthInside1X128,
        uint256 gainGrowthInside0X128,
        uint256 gainGrowthInside1X128
    ) internal returns (uint256 lossOwed0, uint256 lossOwed1, uint256 gainOwed0, uint256 gainOwed1) {
        uint128 liquidity = self.liquidity;

        // Calculate accumulated losses and gains. Overflow in the subtraction of loss/gain growth is expected
        unchecked {
            lossOwed0 = FullMath.mulDiv(
                lossGrowthInside0X128 - self.lossGrowthInside0LastX128, 
                liquidity, 
                FixedPoint128.Q128
            );
            lossOwed1 = FullMath.mulDiv(
                lossGrowthInside1X128 - self.lossGrowthInside1LastX128, 
                liquidity, 
                FixedPoint128.Q128
            );

            gainOwed0 = FullMath.mulDiv(
                gainGrowthInside0X128 - self.gainGrowthInside0LastX128, 
                liquidity, 
                FixedPoint128.Q128
            );
            gainOwed1 = FullMath.mulDiv(
                gainGrowthInside1X128 - self.gainGrowthInside1LastX128, 
                liquidity, 
                FixedPoint128.Q128
            );
        }

        // Update the position with the latest loss and gain growth values
        self.lossGrowthInside0LastX128 = lossGrowthInside0X128;
        self.lossGrowthInside1LastX128 = lossGrowthInside1X128;
        self.gainGrowthInside0LastX128 = gainGrowthInside0X128;
        self.gainGrowthInside1LastX128 = gainGrowthInside1X128;
    }

}
