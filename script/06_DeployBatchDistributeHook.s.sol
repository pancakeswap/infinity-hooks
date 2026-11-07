// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";

import {BatchDistributeHook} from "../src/pool-cl/batch-distribute/BatchDistributeHook.sol";
import {SpraayAddresses} from "../src/pool-cl/batch-distribute/SpraayAddresses.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";

/**
 * Supported configs: bsc-mainnet (chainId 56), base-mainnet (chainId 8453)
 *
 * Step 1: Deploy
 * SCRIPT_CONFIG=bsc-mainnet HOOK_OWNER=<owner> HOOK_OPERATOR=<operator> \
 * forge script script/06_DeployBatchDistributeHook.s.sol:DeployBatchDistributeHookScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow
 *
 * Step 2: Verify
 * forge verify-contract <address> BatchDistributeHook --watch \
 *      --chain <chain_id> --constructor-args $(cast abi-encode "constructor(address,address,address,address)" \
 *      "<clPoolManager>" "<spraay>" "<owner>" "<operator>")
 */
contract DeployBatchDistributeHookScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("INFINITY-HOOKS/BatchDistributeHook/1.0.0");
    }

    function run() public {
        Create3Factory factory = Create3Factory(getAddressFromConfig("create3Factory"));

        address clPoolManager = getAddressFromConfig("clPoolManager");
        emit log_named_address("CLPoolManager", clPoolManager);

        address spraay = getAddressFromConfig("spraay");
        require(spraay == SpraayAddresses.forChain(block.chainid), "Spraay address does not match chain");
        emit log_named_address("Spraay", spraay);

        address owner = vm.envAddress("HOOK_OWNER");
        address operator = vm.envOr("HOOK_OPERATOR", address(0));
        emit log_named_address("Owner", owner);
        emit log_named_address("Operator", operator);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        bytes memory creationCode = abi.encodePacked(
            type(BatchDistributeHook).creationCode, abi.encode(ICLPoolManager(clPoolManager), spraay, owner, operator)
        );
        address hookAddr;
        // PancakeSwap's Create3Factory only accepts whitelisted deployers; anyone else deploys directly
        if (factory.isUserWhitelisted(vm.addr(deployerPrivateKey))) {
            hookAddr = factory.deploy(getDeploymentSalt(), creationCode, keccak256(creationCode), 0, new bytes(0), 0);
        } else {
            hookAddr = address(new BatchDistributeHook(ICLPoolManager(clPoolManager), spraay, owner, operator));
        }
        emit log_named_address("BatchDistributeHook", hookAddr);

        vm.stopBroadcast();
    }
}
