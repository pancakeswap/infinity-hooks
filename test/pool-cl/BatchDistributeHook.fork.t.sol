// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {Constants} from "infinity-core/test/pool-cl/helpers/Constants.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BatchDistributeHook} from "../../src/pool-cl/batch-distribute/BatchDistributeHook.sol";
import {ISpraay} from "../../src/pool-cl/batch-distribute/interfaces/ISpraay.sol";
import {SpraayAddresses} from "../../src/pool-cl/batch-distribute/SpraayAddresses.sol";

/// @notice Runs the hook against the live Spraay and PancakeSwap Infinity deployments.
/// Skipped unless RPC_BSC_MAINNET / RPC_BASE_MAINNET are set, e.g.
///   RPC_BSC_MAINNET=https://bsc-dataseed.binance.org RPC_BASE_MAINNET=https://mainnet.base.org \
///     forge test --match-contract BatchDistributeHookForkTest
contract BatchDistributeHookForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    /// @dev PancakeSwap Infinity CLPoolManager, same address on BNB Chain and Base
    address constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");

    function test_Fork_BSC() public {
        _runFork("RPC_BSC_MAINNET", SpraayAddresses.BSC_MAINNET);
    }

    function test_Fork_Base() public {
        _runFork("RPC_BASE_MAINNET", SpraayAddresses.BASE_MAINNET);
    }

    function _runFork(string memory rpcEnv, address spraayAddr) internal {
        string memory rpc = vm.envOr(rpcEnv, string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        ISpraay spraay = ISpraay(spraayAddr);
        uint256 feeBps = spraay.feeBps();
        assertEq(spraay.MAX_RECIPIENTS(), 200);

        BatchDistributeHook hook =
            new BatchDistributeHook(ICLPoolManager(CL_POOL_MANAGER), spraayAddr, owner, operator);

        // a fresh pool on the live CLPoolManager that uses the hook
        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        (address t0, address t1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            hooks: hook,
            poolManager: ICLPoolManager(CL_POOL_MANAGER),
            fee: 3000,
            parameters: bytes32(uint256(hook.getHooksRegistrationBitmap())).setTickSpacing(60)
        });
        ICLPoolManager(CL_POOL_MANAGER).initialize(key, Constants.SQRT_RATIO_1_1);
        PoolId id = key.toId();
        assertTrue(hook.isRegisteredPool(id));

        address[] memory recipients = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            recipients[i] = makeAddr(string.concat("forkRecipient", vm.toString(i)));
            amounts[i] = (i + 1) * 1 ether;
        }
        uint256 total = 6 ether;
        uint256 required = total + total * feeBps / 10_000;
        assertEq(hook.quoteTotalCost(total), required);

        // ERC-20 via sprayToken
        MockERC20 reward = new MockERC20("R", "R", 18);
        reward.mint(operator, 1_000 ether);
        vm.startPrank(operator);
        reward.approve(address(hook), type(uint256).max);
        hook.batchDistribute(id, address(reward), recipients, amounts);
        // ERC-20 via sprayEqual
        hook.batchDistributeEqual(id, address(reward), recipients, 1 ether);
        vm.stopPrank();

        assertEq(reward.balanceOf(recipients[0]), 2 ether);
        assertEq(reward.balanceOf(recipients[2]), 4 ether);
        assertEq(1_000 ether - reward.balanceOf(operator), required + 3 ether + 3 ether * feeBps / 10_000);
        assertEq(reward.balanceOf(address(hook)), 0);

        // native via sprayETH, with excess refunded
        vm.deal(operator, 100 ether);
        vm.prank(operator);
        hook.batchDistribute{value: required + 1 ether}(id, address(0), recipients, amounts);
        assertEq(recipients[1].balance, 2 ether);
        assertEq(operator.balance, 100 ether - required);
        assertEq(address(hook).balance, 0);
    }
}
