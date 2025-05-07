// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.19;

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {CLBaseHook} from "../CLBaseHook.sol";

/// @dev This hook is used to control the start time of swaps in a CL pool.
contract CLSwapStartTime is CLBaseHook, Ownable {
    uint256 public SWAP_START_TIME = type(uint256).max; // default value is max uint256, will forbid any swap before it is set
    bool public swapAlreadyStarted;

    error SwapNotStarted();

    constructor(ICLPoolManager poolManager) Ownable(msg.sender) CLBaseHook(poolManager) {}

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: false,
                afterInitialize: false,
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

    function _beforeSwap(address, PoolKey calldata, ICLPoolManager.SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!swapAlreadyStarted) {
            if (block.timestamp < SWAP_START_TIME) {
                revert SwapNotStarted();
            }
            swapAlreadyStarted = true;
        }
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function setSwapStartTime(uint256 swapStartTime) external onlyOwner {
        SWAP_START_TIME = swapStartTime;
    }
}
