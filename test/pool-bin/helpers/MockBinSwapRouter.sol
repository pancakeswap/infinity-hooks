pragma solidity ^0.8.19;

import {CommonBase} from "forge-std/Base.sol";
import {MockInfinityRouter} from "infinity-periphery/test/mocks/MockInfinityRouter.sol";
import {IInfinityRouter} from "infinity-periphery/src/interfaces/IInfinityRouter.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {Planner, Plan} from "infinity-periphery/src/libraries/Planner.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

contract MockBinSwapRouter is MockInfinityRouter, CommonBase {
    using Planner for Plan;

    constructor(IVault _vault, IBinPoolManager _binPoolManager)
        MockInfinityRouter(_vault, ICLPoolManager(address(0)), _binPoolManager)
    {}

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert();
        _;
    }

    function exactInputSingle(IInfinityRouter.BinSwapExactInputSingleParams calldata params, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
    {
        Plan memory planner = Planner.init().add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        Currency inputCurrency = params.swapForY ? params.poolKey.currency0 : params.poolKey.currency1;
        Currency outputCurrency = params.swapForY ? params.poolKey.currency1 : params.poolKey.currency0;
        bytes memory data = planner.finalizeSwap(inputCurrency, outputCurrency, msg.sender);

        vm.prank(msg.sender);
        this.executeActions(data);
    }

    function exactInput(IInfinityRouter.BinSwapExactInputParams calldata params, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
    {
        Plan memory planner = Planner.init().add(Actions.BIN_SWAP_EXACT_IN, abi.encode(params));
        Currency inputCurrency = params.currencyIn;
        Currency outputCurrency = params.path[params.path.length - 1].intermediateCurrency;
        bytes memory data = planner.finalizeSwap(inputCurrency, outputCurrency, msg.sender);

        vm.prank(msg.sender);
        this.executeActions(data);
    }

    function exactOutputSingle(IInfinityRouter.BinSwapExactOutputSingleParams calldata params, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
    {
        Plan memory planner = Planner.init().add(Actions.BIN_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        Currency inputCurrency = params.swapForY ? params.poolKey.currency0 : params.poolKey.currency1;
        Currency outputCurrency = params.swapForY ? params.poolKey.currency1 : params.poolKey.currency0;
        bytes memory data = planner.finalizeSwap(inputCurrency, outputCurrency, msg.sender);

        vm.prank(msg.sender);
        this.executeActions(data);
    }

    function exactOutput(IInfinityRouter.BinSwapExactOutputParams calldata params, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
    {
        Plan memory planner = Planner.init().add(Actions.BIN_SWAP_EXACT_OUT, abi.encode(params));
        Currency inputCurrency = params.path[params.path.length - 1].intermediateCurrency;
        Currency outputCurrency = params.currencyOut;
        bytes memory data = planner.finalizeSwap(inputCurrency, outputCurrency, msg.sender);

        vm.prank(msg.sender);
        this.executeActions(data);
    }
}
