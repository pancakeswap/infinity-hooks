// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {SortTokens} from "infinity-core/test/helpers/SortTokens.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {ICLRouterBase} from "infinity-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {MockCLSwapRouter} from "./helpers/MockCLSwapRouter.sol";
import {MockCLPositionManager} from "./helpers/MockCLPositionManager.sol";

import {CLFullRange} from "../../src/pool-cl/full-range/CLFullRange.sol";
import {PancakeFullRangeERC20} from "../../src/pool-cl/full-range/libraries/PancakeFullRangeERC20.sol";

contract CLFullRangeHookTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;
    using CurrencyLibrary for Currency;

    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    uint16 constant MINIMUM_LIQUIDITY = 1000;
    uint256 constant MAX_TICK_LIQUIDITY = 11505069308564788430434325881101412;

    IVault vault;
    ICLPoolManager poolManager;
    IAllowanceTransfer permit2;
    MockCLPositionManager cpm;
    MockCLSwapRouter swapRouter;

    CLFullRange fullRange;

    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;

    PoolKey key;
    PoolId id;

    PoolKey key2;
    PoolId id2;

    PoolKey keyWithLiq;
    PoolId idWithLiq;

    function setUp() public {
        (vault, poolManager) = createFreshManager();
        fullRange = new CLFullRange(poolManager);

        permit2 = IAllowanceTransfer(deployPermit2());
        cpm = new MockCLPositionManager(vault, poolManager, permit2);
        swapRouter = new MockCLSwapRouter(vault, poolManager);

        MockERC20[] memory tokens = deployTokens(3, 2 ** 128);
        token0 = tokens[0];
        token1 = tokens[1];
        token2 = tokens[2];

        {
            (Currency currency0, Currency currency1) = SortTokens.sort(token0, token1);
            key = PoolKey({
                currency0: currency0,
                currency1: currency1,
                hooks: fullRange,
                poolManager: poolManager,
                fee: 3000,
                parameters: bytes32(uint256(fullRange.getHooksRegistrationBitmap())).setTickSpacing(60)
            });
            id = key.toId();
        }

        {
            (Currency currency0, Currency currency1) = SortTokens.sort(token1, token2);
            key2 = PoolKey({
                currency0: currency0,
                currency1: currency1,
                hooks: fullRange,
                poolManager: poolManager,
                fee: 3000,
                parameters: bytes32(uint256(fullRange.getHooksRegistrationBitmap())).setTickSpacing(60)
            });
            id2 = key2.toId();
        }

        {
            (Currency currency0, Currency currency1) = SortTokens.sort(token0, token2);
            keyWithLiq = PoolKey({
                currency0: currency0,
                currency1: currency1,
                hooks: fullRange,
                poolManager: poolManager,
                fee: 3000,
                parameters: bytes32(uint256(fullRange.getHooksRegistrationBitmap())).setTickSpacing(60)
            });
            idWithLiq = keyWithLiq.toId();
        }

        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        token2.approve(address(fullRange), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token2.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        token2.approve(address(permit2), type(uint256).max);

        permit2.approve(address(token0), address(cpm), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(cpm), type(uint160).max, type(uint48).max);
        permit2.approve(address(token2), address(cpm), type(uint160).max, type(uint48).max);

        poolManager.initialize(keyWithLiq, SQRT_RATIO_1_1);

        fullRange.addLiquidity(
            CLFullRange.AddLiquidityParams({
                currency0: keyWithLiq.currency0,
                currency1: keyWithLiq.currency1,
                fee: keyWithLiq.fee,
                parameters: keyWithLiq.parameters,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                to: address(this),
                deadline: block.timestamp
            })
        );
    }

    function test_RevertIfWrongTickSpacing() public {
        PoolKey memory wrongKey = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            hooks: fullRange,
            poolManager: poolManager,
            fee: 3000,
            parameters: bytes32(uint256(fullRange.getHooksRegistrationBitmap())).setTickSpacing(61)
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(fullRange),
                ICLHooks.beforeInitialize.selector,
                abi.encodeWithSelector(CLFullRange.TickSpacingNotDefault.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(wrongKey, SQRT_RATIO_1_1);
    }

    function test_RevertIfNoPool() public {
        vm.expectRevert(CLFullRange.PoolNotInitialized.selector);
        fullRange.addLiquidity(
            CLFullRange.AddLiquidityParams({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                parameters: key.parameters,
                amount0Desired: 10 ether,
                amount1Desired: 10 ether,
                amount0Min: 0,
                amount1Min: 0,
                to: address(this),
                deadline: block.timestamp
            })
        );

        vm.expectRevert(CLFullRange.PoolNotInitialized.selector);
        fullRange.removeLiquidity(
            CLFullRange.RemoveLiquidityParams({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                parameters: key.parameters,
                liquidity: 1e18,
                deadline: block.timestamp
            })
        );
    }

    function test_RevertIfTooMuchSlippage() public {
        poolManager.initialize(key, SQRT_RATIO_1_1);

        fullRange.addLiquidity(
            CLFullRange.AddLiquidityParams({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                parameters: key.parameters,
                amount0Desired: 10 ether,
                amount1Desired: 10 ether,
                amount0Min: 0,
                amount1Min: 0,
                to: address(this),
                deadline: block.timestamp
            })
        );

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 1e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        vm.expectRevert(CLFullRange.TooMuchSlippage.selector);
        fullRange.addLiquidity(
            CLFullRange.AddLiquidityParams({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                parameters: key.parameters,
                amount0Desired: 10 ether,
                amount1Desired: 10 ether,
                amount0Min: 10 ether,
                amount1Min: 10 ether,
                to: address(this),
                deadline: block.timestamp
            })
        );
    }

    function test_AddLiquidity() public {
        poolManager.initialize(key, SQRT_RATIO_1_1);

        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        fullRange.addLiquidity(
            CLFullRange.AddLiquidityParams({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                parameters: key.parameters,
                amount0Desired: 10 ether,
                amount1Desired: 10 ether,
                amount0Min: 0,
                amount1Min: 0,
                to: address(this),
                deadline: block.timestamp
            })
        );

        (bool hasAccruedFees, address liquidityToken) = fullRange.poolInfo(id);
        uint256 liquidityTokenBalance = PancakeFullRangeERC20(liquidityToken).balanceOf(address(this));

        assertEq(poolManager.getLiquidity(id), liquidityTokenBalance + MINIMUM_LIQUIDITY);

        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 10 ether);

        assertEq(liquidityTokenBalance, 10 ether - MINIMUM_LIQUIDITY);
        assertEq(hasAccruedFees, false);

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 1e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        (hasAccruedFees,) = fullRange.poolInfo(id);
        assertEq(hasAccruedFees, true);

        fullRange.addLiquidity(
            CLFullRange.AddLiquidityParams({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                parameters: key.parameters,
                amount0Desired: 10 ether,
                amount1Desired: 10 ether,
                amount0Min: 0,
                amount1Min: 0,
                to: address(this),
                deadline: block.timestamp
            })
        );

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: 1e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        (hasAccruedFees,) = fullRange.poolInfo(id);
        assertEq(hasAccruedFees, true);

        fullRange.addLiquidity(
            CLFullRange.AddLiquidityParams({
                currency0: keyWithLiq.currency0,
                currency1: keyWithLiq.currency1,
                fee: keyWithLiq.fee,
                parameters: keyWithLiq.parameters,
                amount0Desired: 10 ether,
                amount1Desired: 10 ether,
                amount0Min: 0,
                amount1Min: 0,
                to: address(this),
                deadline: block.timestamp
            })
        );
    }

    function testFuzz_AddLiquidity(uint256 amount) public {
        poolManager.initialize(key, SQRT_RATIO_1_1);

        if (amount <= MINIMUM_LIQUIDITY) {
            vm.expectRevert(CLFullRange.LiquidityDoesntMeetMinimum.selector);
            fullRange.addLiquidity(
                CLFullRange.AddLiquidityParams({
                    currency0: key.currency0,
                    currency1: key.currency1,
                    fee: key.fee,
                    parameters: key.parameters,
                    amount0Desired: amount,
                    amount1Desired: amount,
                    amount0Min: amount,
                    amount1Min: amount,
                    to: address(this),
                    deadline: block.timestamp
                })
            );
        } else if (amount > MAX_TICK_LIQUIDITY) {
            vm.expectRevert();
            fullRange.addLiquidity(
                CLFullRange.AddLiquidityParams({
                    currency0: key.currency0,
                    currency1: key.currency1,
                    fee: key.fee,
                    parameters: key.parameters,
                    amount0Desired: amount,
                    amount1Desired: amount,
                    amount0Min: amount,
                    amount1Min: amount,
                    to: address(this),
                    deadline: block.timestamp
                })
            );
        } else {
            fullRange.addLiquidity(
                CLFullRange.AddLiquidityParams({
                    currency0: key.currency0,
                    currency1: key.currency1,
                    fee: key.fee,
                    parameters: key.parameters,
                    amount0Desired: amount,
                    amount1Desired: amount,
                    amount0Min: 0,
                    amount1Min: 0,
                    to: address(this),
                    deadline: block.timestamp
                })
            );

            (bool hasAccruedFees, address liquidityToken) = fullRange.poolInfo(id);
            uint256 liquidityTokenBalance = PancakeFullRangeERC20(liquidityToken).balanceOf(address(this));

            assertEq(poolManager.getLiquidity(id), liquidityTokenBalance + MINIMUM_LIQUIDITY);
            assertEq(hasAccruedFees, false);
        }
    }

    function test_RevertIfNoLiquidity() public {
        poolManager.initialize(key, SQRT_RATIO_1_1);

        (, address liquidityToken) = fullRange.poolInfo(id);

        PancakeFullRangeERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        vm.expectRevert();
        fullRange.removeLiquidity(
            CLFullRange.RemoveLiquidityParams({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                parameters: key.parameters,
                liquidity: 1e18,
                deadline: block.timestamp
            })
        );
    }

    function test_RemoveLiquidity() public {
        uint256 prevBalance0 = keyWithLiq.currency0.balanceOf(address(this));
        uint256 prevBalance1 = keyWithLiq.currency1.balanceOf(address(this));

        (, address liquidityToken) = fullRange.poolInfo(idWithLiq);

        PancakeFullRangeERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(
            CLFullRange.RemoveLiquidityParams({
                currency0: keyWithLiq.currency0,
                currency1: keyWithLiq.currency1,
                fee: keyWithLiq.fee,
                parameters: keyWithLiq.parameters,
                liquidity: 1e18,
                deadline: block.timestamp
            })
        );

        (bool hasAccruedFees,) = fullRange.poolInfo(idWithLiq);
        uint256 liquidityTokenBalance = PancakeFullRangeERC20(liquidityToken).balanceOf(address(this));

        assertEq(poolManager.getLiquidity(idWithLiq), liquidityTokenBalance + MINIMUM_LIQUIDITY);
        assertEq(PancakeFullRangeERC20(liquidityToken).balanceOf(address(this)), 99 ether - MINIMUM_LIQUIDITY + 5);
        assertEq(keyWithLiq.currency0.balanceOf(address(this)), prevBalance0 + 1 ether - 1);
        assertEq(keyWithLiq.currency1.balanceOf(address(this)), prevBalance1 + 1 ether - 1);
        assertEq(hasAccruedFees, false);
    }

    function testFuzz_RemoveLiquidity(uint256 amount) public {
        poolManager.initialize(key, SQRT_RATIO_1_1);

        fullRange.addLiquidity(
            CLFullRange.AddLiquidityParams({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                parameters: key.parameters,
                amount0Desired: 1000 ether,
                amount1Desired: 1000 ether,
                amount0Min: 0,
                amount1Min: 0,
                to: address(this),
                deadline: block.timestamp
            })
        );

        (, address liquidityToken) = fullRange.poolInfo(id);

        PancakeFullRangeERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        if (amount > PancakeFullRangeERC20(liquidityToken).balanceOf(address(this))) {
            vm.expectRevert();
            fullRange.removeLiquidity(
                CLFullRange.RemoveLiquidityParams({
                    currency0: key.currency0,
                    currency1: key.currency1,
                    fee: key.fee,
                    parameters: key.parameters,
                    liquidity: amount,
                    deadline: block.timestamp
                })
            );
        } else {
            uint256 prevLiquidityTokenBalance = PancakeFullRangeERC20(liquidityToken).balanceOf(address(this));

            fullRange.removeLiquidity(
                CLFullRange.RemoveLiquidityParams({
                    currency0: key.currency0,
                    currency1: key.currency1,
                    fee: key.fee,
                    parameters: key.parameters,
                    liquidity: amount,
                    deadline: block.timestamp
                })
            );

            uint256 liquidityTokenBalance = PancakeFullRangeERC20(liquidityToken).balanceOf(address(this));
            (bool hasAccruedFees,) = fullRange.poolInfo(id);

            assertEq(prevLiquidityTokenBalance - liquidityTokenBalance, amount);
            assertEq(poolManager.getLiquidity(id), liquidityTokenBalance + MINIMUM_LIQUIDITY);
            assertEq(hasAccruedFees, false);
        }
    }
}
