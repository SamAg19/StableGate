// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console2} from "forge-std/Script.sol";
import {AllowlistReactiveContract} from "../src/AllowlistReactiveContract.sol";

/// @notice Deploy AllowlistReactiveContract to Reactive Lasna (Chain ID: 5318007).
///
///         The RSC subscribes to MembershipNFT Transfer events on Base Sepolia (84532)
///         and delivers callbacks to PermissionedCSMMHook on Unichain Sepolia (1301).
///
///         Prerequisites:
///           - MembershipNFT deployed on Base Sepolia → set MEMBERSHIP_NFT in .env
///           - PermissionedCSMMHook deployed on Unichain Sepolia → set HOOK_CONTRACT in .env
///           - Deployer wallet funded with lREACT on Reactive Lasna
///             (send SepETH to the Reactive faucet: 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434)
///
/// Usage:
///   source .env
///   forge script script/DeployReactive.s.sol \
///     --rpc-url $REACTIVE_LASNA_RPC \
///     --broadcast \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     -vvv
contract DeployReactive is Script {
    function run() external {
        address membershipNFT = vm.envAddress("MEMBERSHIP_NFT");
        address hookContract  = vm.envAddress("HOOK_CONTRACT");

        vm.startBroadcast();

        // Deploy with 0.1 lREACT to cover subscription costs.
        // The constructor calls SERVICE_ADDR.subscribe() on Reactive Network (not in ReactVM).
        AllowlistReactiveContract rsc = new AllowlistReactiveContract{value: 0.1 ether}(
            membershipNFT,
            hookContract
        );

        vm.stopBroadcast();

        console2.log("=== Reactive Lasna Deployment ===");
        console2.log("AllowlistReactiveContract:", address(rsc));
        console2.log("MembershipNFT (Base):     ", membershipNFT);
        console2.log("HookContract (Unichain):  ", hookContract);
        console2.log("");
        console2.log("Monitoring: Transfer events on Base Sepolia (chain 84532)");
        console2.log("Callbacks:  addToAllowlistReactive() on Unichain Sepolia (chain 1301)");
    }
}
