// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

// this is No-Ops hooks related stuff
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

/// @title GasPriceFeesHook

contract GasPriceFeesHook is BaseHook {
    using LPFeeLibrary for uint24;

    constructor(IPoolManager _manager) BaseHook(_manager) {
        updateMovingAverageGasPrice();
    }

    uint128 public movingAverageGasPrice; // current average gas price
    uint104 public movingAverageGasPriceCount; // number of gas price samples
    uint24 public constant BASE_FEES = 5000; // pips, 0.5% fee

    error MustUseDynamicFees();

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
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

    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFees();
        return this.beforeInitialize.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    )
        internal
        view
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = getFee();
        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            feeWithFlag
        );
    }

    function _afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override onlyPoolManager returns (bytes4, int128) {
        updateMovingAverageGasPrice();
        return (this.afterSwap.selector, 0);
    }

    function getFee() internal view returns (uint24) {
        uint128 gasPrice = uint128(tx.gasprice);
        if (gasPrice > (movingAverageGasPrice * 11) / 10) {
            return BASE_FEES / 2;
        }
        if (gasPrice < (movingAverageGasPrice * 9) / 10) {
            return BASE_FEES * 2;
        }
        return BASE_FEES;
    }

    function updateMovingAverageGasPrice() internal {
        uint128 gasPrice = uint128(tx.gasprice);
        movingAverageGasPrice =
            (movingAverageGasPrice * movingAverageGasPriceCount + gasPrice) /
            (movingAverageGasPriceCount + 1);
        movingAverageGasPriceCount++;
    }
}
