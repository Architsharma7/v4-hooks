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
    using StateLibrary for IPoolManager;
    using FixedPointMathLib for uint256;

    mapping(PoolId poolId => mapping(int24 tickToExecuteAt => mapping(bool zerForOne => uint256 inputAmount)))
        public pendingOrders;
    mapping(uint256 poolId => uint256 claimSupply) public claimTokensSupply;
    mapping(uint256 positionId => uint256 outputClaimable)
        public claimableOutputTokens;
    mapping(PoolId poolId => int24 lastTick) public lastTicks;

    constructor(
        IPoolManager _manager,
        string memory _uri
    ) BaseHook(_manager) ERC1155(_uri) {}

    error NotEnoughTokens();
    error NothingToClaim();
    error NotEnoughToClaim();

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

    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) internal override onlyPoolManager returns (bytes4) {
        lastTicks[key.toId()] = tick;
        return this.afterInitialize.selector;
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override onlyPoolManager returns (bytes4, int128) {
        if (sender == address(this)) return (this.afterSwap.selector, 0);
        bool tryMore = true;
        int24 currentTick;

        while (tryMore) {
            (tryMore, currentTick) = tryExecutingOrders(
                key,
                !params.zeroForOne
            );
        }

        lastTicks[key.toId()] = currentTick;
        return (this.afterSwap.selector, 0);
    }

    function tryExecutingOrders(
        PoolKey calldata key,
        bool executeZeroForOne
    ) internal returns (bool tryMore, int24 newTick) {
        (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());
        int24 lastTick = lastTicks[key.toId()];

        // Given `currentTick` and `lastTick`, 2 cases are possible:
        // Case (1) - Tick has increased, i.e. `currentTick > lastTick`
        // or, Case (2) - Tick has decreased, i.e. `currentTick < lastTick`

        if (currentTick > lastTick) {
            for (
                int24 tick = lastTick;
                tick <= currentTick;
                tick += key.tickSpacing
            ) {
                uint256 inputAmount = pendingOrders[key.toId()][tick][
                    executeZeroForOne
                ];
                if (inputAmount > 0) {
                    executeOrder(key, tick, executeZeroForOne, inputAmount);

                    return (true, currentTick);
                }
            }
        } else {
            for (
                int24 tick = lastTick;
                tick >= currentTick;
                tick -= key.tickSpacing
            ) {
                uint256 inputAmount = pendingOrders[key.toId()][tick][
                    executeZeroForOne
                ];
                if (inputAmount > 0) {
                    executeOrder(key, tick, executeZeroForOne, inputAmount);
                    return (true, currentTick);
                }
            }
        }

        return (false, currentTick);
    }

    function placeOrder(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 inputAmount
    ) external returns (int24) {
        int24 tickToExecuteAt = getLowerUsableTick(
            tickToSellAt,
            key.tickSpacing
        );
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
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 amountToCancel
    ) external {
        int24 tickToExecuteAt = getLowerUsableTick(
            tickToSellAt,
            key.tickSpacing
        );
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

    function redeem(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 inputAmountToClaimFor
    ) external {
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 positionId = getPositionId(key, tick, zeroForOne);

        if (claimableOutputTokens[positionId] == 0) revert NothingToClaim();

        uint256 positionTokens = balanceOf(msg.sender, positionId);
        if (positionTokens < inputAmountToClaimFor) revert NotEnoughToClaim();

        uint256 totalClaimableForPosition = claimableOutputTokens[positionId];
        uint256 totalInputAmountForPosition = claimTokensSupply[positionId];
        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(
            totalClaimableForPosition,
            totalInputAmountForPosition
        );
        claimableOutputTokens[positionId] -= outputAmount;
        claimTokensSupply[positionId] -= inputAmountToClaimFor;
        _burn(msg.sender, positionId, inputAmountToClaimFor);

        Currency token = zeroForOne ? key.currency1 : key.currency0;
        token.transfer(msg.sender, outputAmount);
    }

    function executeOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        uint256 inputAmount
    ) internal {
        BalanceDelta delta = swapAndSettleBalances(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                // provide a negative value here to signify an "exact input for output" swap
                amountSpecified: -int256(inputAmount),
                // No slippage limits (maximum slippage possible)
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        pendingOrders[key.toId()][tick][zeroForOne] -= inputAmount;
        uint256 positionId = getPositionId(key, tick, zeroForOne);
        uint256 outputAmount = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));
        claimableOutputTokens[positionId] += outputAmount;
    }

    function swapAndSettleBalances(
        PoolKey calldata key,
        IPoolManager.SwapParams memory params
    ) internal returns (BalanceDelta) {
        BalanceDelta delta = poolManager.swap(key, params, "");
        if (params.zeroForOne) {
            // Negative Value => Money leaving user's wallet
            // Settle with PoolManager
            if (delta.amount0() < 0) {
                _settle(key.currency0, uint128(-delta.amount0()));
            }

            // Positive Value => Money coming into user's wallet
            // Take from PM
            if (delta.amount1() > 0) {
                _take(key.currency1, uint128(delta.amount1()));
            }
        } else {
            if (delta.amount1() < 0) {
                _settle(key.currency1, uint128(-delta.amount1()));
            }

            if (delta.amount0() > 0) {
                _take(key.currency0, uint128(delta.amount0()));
            }
        }

        return delta;
    }

    function _settle(Currency currency, uint128 amount) internal {
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, uint128 amount) internal {
        poolManager.take(currency, address(this), amount);
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
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }
}
