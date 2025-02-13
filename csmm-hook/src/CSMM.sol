// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

// This is theoretically the ideal curve for a stablecoin or pegged pairs (stETH/ETH)
// just an example of a custom curve, not for production

contract CSMM is BaseHook {
    using CurrencySettler for Currency;

    error AddLiquidityThroughHook();

    constructor(IPoolManager poolManager) BaseHook(poolManager) {}

    struct CallbackData {
        uint256 amountEach;
        Currency currency0;
        Currency currency1;
        address sender;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // Disable adding liquidity through the PM
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert AddLiquidityThroughHook();
    }

    function addLiquidity(PoolKey calldata key, uint256 amountEach) external {
        poolManager.unlock(
            abi.encode(
                CallbackData(
                    amountEach,
                    key.currency0,
                    key.currency1,
                    msg.sender
                )
            )
        );
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 amountInOutPositive = params.amountSpecified > 0
            ? uint256(params.amountSpecified)
            : uint256(-params.amountSpecified);

        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(
            int128(-params.amountSpecified), // eg specifiedAmount = +100
            int128(params.amountSpecified) // Unspecified amount (output delta) = -100
        );

        if (params.zeroForOne) {
            key.currency0.take(
                poolManager,
                address(this),
                amountInOutPositive,
                true
            );

            key.currency1.settle(
                poolManager,
                address(this),
                amountInOutPositive,
                true
            );
        } else {
            key.currency0.settle(
                poolManager,
                address(this),
                amountInOutPositive,
                true
            );
            key.currency1.take(
                poolManager,
                address(this),
                amountInOutPositive,
                true
            );
        }

        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }

    function _unlockCallback(
        bytes calldata data
    ) internal override returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        // Create a debit of `amountEach` of each currency with the Pool Manager
        callbackData.currency0.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false // actually transferring tokens, not burning ERC-6909 Claim Tokens
        );

        callbackData.currency1.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false
        );

        callbackData.currency0.take(
            poolManager,
            address(this),
            callbackData.amountEach,
            true // mint claim tokens for the hook, equivalent to money deposited to the PM
        );

        callbackData.currency1.take(
            poolManager,
            address(this),
            callbackData.amountEach,
            true
        );

        return "";
    }
}
