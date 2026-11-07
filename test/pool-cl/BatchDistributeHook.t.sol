// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {SortTokens} from "infinity-core/test/helpers/SortTokens.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {BatchDistributeHook} from "../../src/pool-cl/batch-distribute/BatchDistributeHook.sol";
import {MockSpraay} from "./helpers/MockSpraay.sol";

contract BatchDistributeHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    uint256 constant FEE_BPS = 30;

    IVault vault;
    ICLPoolManager poolManager;
    BatchDistributeHook hook;
    MockSpraay spraay;

    MockERC20 token0;
    MockERC20 token1;
    MockERC20 rewardToken;
    PoolKey key;
    PoolId id;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address feeRecipient = makeAddr("spraayFeeRecipient");
    address stranger = makeAddr("stranger");

    function setUp() public {
        MockERC20[] memory tokens = deployTokens(3, type(uint256).max);
        (Currency currency0, Currency currency1) = SortTokens.sort(tokens[0], tokens[1]);
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));
        rewardToken = tokens[2];

        (vault, poolManager) = createFreshManager();
        spraay = new MockSpraay(feeRecipient, FEE_BPS);
        hook = new BatchDistributeHook(poolManager, address(spraay), owner, operator);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: hook,
            poolManager: poolManager,
            fee: 3000,
            parameters: bytes32(uint256(hook.getHooksRegistrationBitmap())).setTickSpacing(60)
        });
        id = key.toId();

        poolManager.initialize(key, SQRT_RATIO_1_1);

        rewardToken.transfer(operator, 1_000_000 ether);
        vm.deal(operator, 1_000_000 ether);
        vm.prank(operator);
        rewardToken.approve(address(hook), type(uint256).max);
    }

    // ============ Setup / hook callbacks ============

    function test_Constructor() public view {
        assertEq(address(hook.spraay()), address(spraay));
        assertEq(hook.owner(), owner);
        assertTrue(hook.isOperator(operator));
        assertEq(hook.MAX_RECIPIENTS(), 200);
    }

    function test_AfterInitialize_RegistersPool() public view {
        assertTrue(hook.isRegisteredPool(id));
    }

    function test_AfterDonate_EmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(hook));
        emit BatchDistributeHook.PoolDonation(id, address(this), 1, 2);
        vm.prank(address(poolManager));
        hook.afterDonate(address(this), key, 1, 2, "");
    }

    function test_HookCallbacks_OnlyPoolManager() public {
        vm.expectRevert();
        hook.afterDonate(address(this), key, 1, 2, "");
    }

    // ============ sprayToken path ============

    function test_BatchDistribute_ERC20() public {
        (address[] memory recipients, uint256[] memory amounts, uint256 total) = _batch(5, 1 ether);
        uint256 fee = total * FEE_BPS / 10_000;
        uint256 operatorBefore = rewardToken.balanceOf(operator);

        vm.expectEmit(true, true, true, true, address(hook));
        emit BatchDistributeHook.BatchDistributed(id, operator, address(rewardToken), 5, total, fee);
        vm.prank(operator);
        hook.batchDistribute(id, address(rewardToken), recipients, amounts);

        for (uint256 i; i < recipients.length; ++i) {
            assertEq(rewardToken.balanceOf(recipients[i]), amounts[i]);
        }
        assertEq(rewardToken.balanceOf(feeRecipient), fee);
        assertEq(operatorBefore - rewardToken.balanceOf(operator), total + fee);
        // non-custodial: nothing left behind, no dangling approval
        assertEq(rewardToken.balanceOf(address(hook)), 0);
        assertEq(rewardToken.balanceOf(address(spraay)), 0);
        assertEq(rewardToken.allowance(address(hook), address(spraay)), 0);
    }

    function test_BatchDistribute_ERC20_RevertIfNativeSent() public {
        (address[] memory recipients, uint256[] memory amounts,) = _batch(2, 1 ether);
        vm.prank(operator);
        vm.expectRevert(BatchDistributeHook.UnexpectedNativeAmount.selector);
        hook.batchDistribute{value: 1}(id, address(rewardToken), recipients, amounts);
    }

    function test_QuoteTotalCost() public view {
        assertEq(hook.quoteTotalCost(10_000), 10_030);
    }

    // ============ sprayETH path ============

    function test_BatchDistribute_Native() public {
        (address[] memory recipients, uint256[] memory amounts, uint256 total) = _batch(4, 0.5 ether);
        uint256 fee = total * FEE_BPS / 10_000;
        uint256 operatorBefore = operator.balance;

        vm.expectEmit(true, true, true, true, address(hook));
        emit BatchDistributeHook.BatchDistributed(id, operator, address(0), 4, total, fee);
        vm.prank(operator);
        hook.batchDistribute{value: total + fee}(id, address(0), recipients, amounts);

        for (uint256 i; i < recipients.length; ++i) {
            assertEq(recipients[i].balance, amounts[i]);
        }
        assertEq(feeRecipient.balance, fee);
        assertEq(operatorBefore - operator.balance, total + fee);
        assertEq(address(hook).balance, 0);
    }

    function test_BatchDistribute_Native_RefundsExcess() public {
        (address[] memory recipients, uint256[] memory amounts, uint256 total) = _batch(3, 1 ether);
        uint256 fee = total * FEE_BPS / 10_000;
        uint256 operatorBefore = operator.balance;

        vm.prank(operator);
        hook.batchDistribute{value: total + fee + 7 ether}(id, address(0), recipients, amounts);

        assertEq(operatorBefore - operator.balance, total + fee);
        assertEq(address(hook).balance, 0);
        assertEq(address(spraay).balance, 0);
    }

    function test_BatchDistribute_Native_RevertIfInsufficient() public {
        (address[] memory recipients, uint256[] memory amounts, uint256 total) = _batch(3, 1 ether);
        uint256 required = total + total * FEE_BPS / 10_000;

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(BatchDistributeHook.InsufficientNativeAmount.selector, required, total)
        );
        hook.batchDistribute{value: total}(id, address(0), recipients, amounts);
    }

    // ============ sprayEqual path ============

    function test_BatchDistributeEqual_ERC20() public {
        (address[] memory recipients,,) = _batch(10, 0);
        uint256 amountEach = 3 ether;
        uint256 total = amountEach * 10;
        uint256 fee = total * FEE_BPS / 10_000;
        uint256 operatorBefore = rewardToken.balanceOf(operator);

        vm.expectEmit(true, true, true, true, address(hook));
        emit BatchDistributeHook.BatchDistributed(id, operator, address(rewardToken), 10, total, fee);
        vm.prank(operator);
        hook.batchDistributeEqual(id, address(rewardToken), recipients, amountEach);

        for (uint256 i; i < recipients.length; ++i) {
            assertEq(rewardToken.balanceOf(recipients[i]), amountEach);
        }
        assertEq(rewardToken.balanceOf(feeRecipient), fee);
        assertEq(operatorBefore - rewardToken.balanceOf(operator), total + fee);
        assertEq(rewardToken.balanceOf(address(hook)), 0);
        assertEq(rewardToken.allowance(address(hook), address(spraay)), 0);
    }

    function test_BatchDistributeEqual_Native() public {
        (address[] memory recipients,,) = _batch(6, 0);
        uint256 amountEach = 0.25 ether;
        uint256 total = amountEach * 6;
        uint256 fee = total * FEE_BPS / 10_000;
        uint256 operatorBefore = operator.balance;

        vm.prank(operator);
        hook.batchDistributeEqual{value: total + fee + 1 ether}(id, address(0), recipients, amountEach);

        for (uint256 i; i < recipients.length; ++i) {
            assertEq(recipients[i].balance, amountEach);
        }
        assertEq(feeRecipient.balance, fee);
        assertEq(operatorBefore - operator.balance, total + fee);
        assertEq(address(hook).balance, 0);
    }

    // ============ Access control ============

    function test_RevertIfNotOperator() public {
        (address[] memory recipients, uint256[] memory amounts, uint256 total) = _batch(2, 1 ether);
        rewardToken.transfer(stranger, 100 ether);
        vm.deal(stranger, 100 ether);

        vm.startPrank(stranger);
        rewardToken.approve(address(hook), type(uint256).max);

        vm.expectRevert(BatchDistributeHook.NotOperator.selector);
        hook.batchDistribute(id, address(rewardToken), recipients, amounts);

        vm.expectRevert(BatchDistributeHook.NotOperator.selector);
        hook.batchDistribute{value: total * 2}(id, address(0), recipients, amounts);

        vm.expectRevert(BatchDistributeHook.NotOperator.selector);
        hook.batchDistributeEqual(id, address(rewardToken), recipients, 1 ether);
        vm.stopPrank();
    }

    function test_OwnerIsNotImplicitlyOperator() public {
        (address[] memory recipients, uint256[] memory amounts,) = _batch(2, 1 ether);
        vm.prank(owner);
        vm.expectRevert(BatchDistributeHook.NotOperator.selector);
        hook.batchDistribute(id, address(rewardToken), recipients, amounts);
    }

    function test_SetOperator() public {
        vm.prank(owner);
        hook.setOperator(stranger, true);
        assertTrue(hook.isOperator(stranger));

        vm.prank(owner);
        hook.setOperator(operator, false);
        assertFalse(hook.isOperator(operator));

        (address[] memory recipients, uint256[] memory amounts,) = _batch(2, 1 ether);
        vm.prank(operator);
        vm.expectRevert(BatchDistributeHook.NotOperator.selector);
        hook.batchDistribute(id, address(rewardToken), recipients, amounts);
    }

    function test_SetOperator_RevertIfNotOwner() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        hook.setOperator(stranger, true);
    }

    function test_SetSpraayContract() public {
        MockSpraay newSpraay = new MockSpraay(feeRecipient, 50);

        vm.expectEmit(true, true, false, false, address(hook));
        emit BatchDistributeHook.SpraayContractUpdated(address(spraay), address(newSpraay));
        vm.prank(owner);
        hook.setSpraayContract(address(newSpraay));
        assertEq(address(hook.spraay()), address(newSpraay));

        // distributions now route through the new contract and its fee
        (address[] memory recipients, uint256[] memory amounts, uint256 total) = _batch(2, 1 ether);
        vm.prank(operator);
        hook.batchDistribute(id, address(rewardToken), recipients, amounts);
        assertEq(rewardToken.balanceOf(feeRecipient), total * 50 / 10_000);
    }

    function test_SetSpraayContract_RevertIfNotOwner() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        hook.setSpraayContract(address(1));
    }

    function test_SetSpraayContract_RevertIfZero() public {
        vm.prank(owner);
        vm.expectRevert(BatchDistributeHook.ZeroAddress.selector);
        hook.setSpraayContract(address(0));
    }

    function test_RescueTokens() public {
        rewardToken.transfer(address(hook), 5 ether);
        vm.prank(owner);
        hook.rescueTokens(address(rewardToken), owner, 5 ether);
        assertEq(rewardToken.balanceOf(owner), 5 ether);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        hook.rescueTokens(address(rewardToken), operator, 0);
    }

    // ============ Recipient limits / validation ============

    function test_MaxRecipients_200Succeeds() public {
        (address[] memory recipients, uint256[] memory amounts,) = _batch(200, 1 ether);
        vm.prank(operator);
        hook.batchDistribute(id, address(rewardToken), recipients, amounts);
        assertEq(rewardToken.balanceOf(recipients[199]), 200 ether);

        vm.prank(operator);
        hook.batchDistributeEqual(id, address(rewardToken), recipients, 1 ether);
        assertEq(rewardToken.balanceOf(recipients[199]), 201 ether);
    }

    function test_MaxRecipients_201Reverts() public {
        (address[] memory recipients, uint256[] memory amounts, uint256 total) = _batch(201, 1 ether);
        bytes memory err = abi.encodeWithSelector(BatchDistributeHook.TooManyRecipients.selector, 201, 200);

        vm.startPrank(operator);
        vm.expectRevert(err);
        hook.batchDistribute(id, address(rewardToken), recipients, amounts);

        vm.expectRevert(err);
        hook.batchDistribute{value: total * 2}(id, address(0), recipients, amounts);

        vm.expectRevert(err);
        hook.batchDistributeEqual(id, address(rewardToken), recipients, 1 ether);
        vm.stopPrank();
    }

    function test_RevertIfNoRecipients() public {
        vm.prank(operator);
        vm.expectRevert(BatchDistributeHook.NoRecipients.selector);
        hook.batchDistribute(id, address(rewardToken), new address[](0), new uint256[](0));
    }

    function test_RevertIfLengthMismatch() public {
        (address[] memory recipients,,) = _batch(3, 1 ether);
        vm.prank(operator);
        vm.expectRevert(BatchDistributeHook.LengthMismatch.selector);
        hook.batchDistribute(id, address(rewardToken), recipients, new uint256[](2));
    }

    function test_RevertIfPoolNotRegistered() public {
        (address[] memory recipients, uint256[] memory amounts,) = _batch(2, 1 ether);
        vm.prank(operator);
        vm.expectRevert(BatchDistributeHook.PoolNotRegistered.selector);
        hook.batchDistribute(PoolId.wrap(bytes32(uint256(1))), address(rewardToken), recipients, amounts);
    }

    function testFuzz_BatchDistribute_ERC20(uint8 count, uint96 amountEach) public {
        count = uint8(bound(count, 1, 200));
        amountEach = uint96(bound(amountEach, 1, 10 ether));
        (address[] memory recipients, uint256[] memory amounts, uint256 total) = _batch(count, amountEach);
        uint256 operatorBefore = rewardToken.balanceOf(operator);

        vm.prank(operator);
        hook.batchDistribute(id, address(rewardToken), recipients, amounts);

        assertEq(operatorBefore - rewardToken.balanceOf(operator), total + total * FEE_BPS / 10_000);
        assertEq(rewardToken.balanceOf(address(hook)), 0);
    }

    // ============ Helpers ============

    /// @dev Builds `count` fresh EOA recipients; amounts vary per recipient (amountEach * (i + 1))
    function _batch(uint256 count, uint256 amountEach)
        internal
        returns (address[] memory recipients, uint256[] memory amounts, uint256 total)
    {
        recipients = new address[](count);
        amounts = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            recipients[i] = makeAddr(string.concat("recipient", vm.toString(i)));
            amounts[i] = amountEach * (i + 1);
            total += amounts[i];
        }
    }
}
