// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

contract TakeProfitsHook is BaseHook, ERC1155 {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    mapping(PoolId poolId => mapping(int24 tickToExecuteAt => mapping(bool zerForOne => uint256 inputAmount)))
        public pendingOrders;
    mapping(uint256 poolId => uint256 claimSupply) public claimTokensSupply;

    constructor(IPoolManager _manager) BaseHook(_manager) ERC1155("") {}

    error NotEnoughTokens();

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) external override onlyPoolManager returns (bytes4) {
        return _afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        return _afterSwap(sender, key, params, delta, hookData);
    }

    function placeOrder(
        Poolkey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 inputAmount
    ) external returns (int24) {
        int24 tickToExecuteAt = getLowerUsableTick(tick, key.tickSpacing);
        pendingOrders[key.toId()][tickToExecuteAt][zeroForOne] = inputAmount;
        uint256 positionId = getPositionId(key, tickToExecuteAt, zeroForOne);
        claimTokensSupply[positionId] += inputAmount;
        _mint(msg.sender, positionId, inputAmount, "");
        address sellToken = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
        IERC20(sellToken).transferFrom(msg.sender, address(this), inputAmount);
        return tickToExecuteAt;
    }

    function cancelOrder(
        Poolkey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 amountToCancel
    ) external {
        int24 tickToExecuteAt = getLowerUsableTick(tick, key.tickSpacing);
        uint256 positionId = getPositionId(key, tickToExecuteAt, zeroForOne);
        uint256 positionTokens = balanceOf(msg.sender, positionId);
        if (positionTokens < amountToCancel) {
            revert NotEnoughTokens();
        }
        pendingOrders[key.toId()][tickToExecuteAt][
            zeroForOne
        ] -= amountToCancel;
        claimTokensSupply[positionId] -= amountToCancel;
        _burn(msg.sender, positionId, amountToCancel);
        Currency token = zeroForOne ? key.currency0 : key.currency1;
        token.transfer(msg.sender, amountToCancel);
    }

    function getLowerUsableTick(
        int24 tick,
        int24 tickSpacing
    ) private pure returns (int24) {
        int24 intervals = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) {
            intervals--;
        }
        return intervals * tickSpacing;
    }

    function getPositionId(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }
}
