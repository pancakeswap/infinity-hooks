pragma solidity ^0.8.19;

import "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {CLBaseHook} from "../CLBaseHook.sol";

contract SampleCLDynamicFeeHook is CLBaseHook {
    using PoolIdLibrary for PoolKey;

    uint24 DEFAULT_LP_FEE = 3000;
    uint24 FREE_LP_FEE = 0;

    bool enableLPFeeOverride = false;

    constructor(ICLPoolManager poolManager) CLBaseHook(poolManager) {}

    function toggleLPFeeOverride() external {
        enableLPFeeOverride = !enableLPFeeOverride;
    }

    function setDynamicLpFee(PoolKey memory key, uint24 fee) public {
        poolManager.updateDynamicLPFee(key, fee);
    }

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        setDynamicLpFee(key, DEFAULT_LP_FEE);
        return this.afterInitialize.selector;
    }

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // if enableLPFeeOverride, the lp fee for the ongoing swap will be 0
        if (enableLPFeeOverride) {
            return (
                this.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                LPFeeLibrary.OVERRIDE_FEE_FLAG & FREE_LP_FEE
            );
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
