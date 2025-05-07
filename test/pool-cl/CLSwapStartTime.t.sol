// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {SortTokens} from "infinity-core/test/helpers/SortTokens.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";

import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {ICLRouterBase} from "infinity-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {MockCLSwapRouter} from "./helpers/MockCLSwapRouter.sol";
import {MockCLPositionManager} from "./helpers/MockCLPositionManager.sol";
import {CLSwapStartTime} from "../../src/pool-cl/swap-start-time/CLSwapStartTime.sol";

import {console2} from "forge-std/console2.sol";

contract CLSwapStartTimeTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    uint160 constant SQRT_RATIO_10_1 = 250541448375047931186413801569;

    IVault vault;
    ICLPoolManager poolManager;
    IAllowanceTransfer permit2;
    MockCLPositionManager cpm;
    MockCLSwapRouter swapRouter;

    CLSwapStartTime swapStartTimeHook;

    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolId id;

    function setUp() public {
        (vault, poolManager) = createFreshManager();
        swapStartTimeHook = new CLSwapStartTime(poolManager);

        permit2 = IAllowanceTransfer(deployPermit2());
        cpm = new MockCLPositionManager(vault, poolManager, permit2);
        swapRouter = new MockCLSwapRouter(vault, poolManager);

        MockERC20[] memory tokens = deployTokens(2, type(uint256).max);
        token0 = tokens[0];
        token1 = tokens[1];
        (currency0, currency1) = SortTokens.sort(token0, token1);

        address[3] memory approvalAddress = [address(cpm), address(swapRouter), address(permit2)];
        for (uint256 i; i < approvalAddress.length; i++) {
            token0.approve(approvalAddress[i], type(uint256).max);
            token1.approve(approvalAddress[i], type(uint256).max);
        }
        permit2.approve(address(token0), address(cpm), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(cpm), type(uint160).max, type(uint48).max);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: swapStartTimeHook,
            poolManager: poolManager,
            fee: 3000,
            parameters: bytes32(uint256(swapStartTimeHook.getHooksRegistrationBitmap())).setTickSpacing(60)
        });
        id = key.toId();

        poolManager.initialize(key, SQRT_RATIO_1_1);

        cpm.mint(
            key,
            -120,
            120,
            // liquidity:
            10e18,
            // amount0Max:
            100e18,
            // amount1Max:
            100e18,
            // owner:
            address(this),
            // hookData:
            ZERO_BYTES
        );
    }

    function testSwapDefaultRevert() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(swapStartTimeHook),
                ICLHooks.beforeSwap.selector,
                abi.encodeWithSelector(CLSwapStartTime.SwapNotStarted.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 1e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp + 1
        );
    }

    function testSwapBeforeStartTimeRevert() public {
        uint256 swapStartTime = block.timestamp + 1 weeks;
        swapStartTimeHook.setSwapStartTime(swapStartTime);

        bool swapAlreadyStarted = swapStartTimeHook.swapAlreadyStarted();
        assertFalse(swapAlreadyStarted, "swapAlreadyStarted should be false");

        vm.warp(swapStartTime - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(swapStartTimeHook),
                ICLHooks.beforeSwap.selector,
                abi.encodeWithSelector(CLSwapStartTime.SwapNotStarted.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 1e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp + 1
        );
    }

    function testSwapAfterStartTime() public {
        uint256 swapStartTime = block.timestamp + 1 weeks;
        swapStartTimeHook.setSwapStartTime(swapStartTime);

        bool swapAlreadyStarted = swapStartTimeHook.swapAlreadyStarted();
        assertFalse(swapAlreadyStarted, "swapAlreadyStarted should be false");

        vm.warp(swapStartTime + 1);
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 1e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp + 1
        );
        swapAlreadyStarted = swapStartTimeHook.swapAlreadyStarted();
        assertTrue(swapAlreadyStarted, "swapAlreadyStarted should be true");
    }
}
