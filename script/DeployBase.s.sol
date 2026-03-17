// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MembershipNFT} from "../src/MembershipNFT.sol";

/// @notice Deploy MembershipNFT to Base Sepolia.
///
/// Usage:
///   source .env
///   forge script script/DeployBase.s.sol \
///     --rpc-url $BASE_SEPOLIA_RPC \
///     --broadcast \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     -vvv
contract DeployBase is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        vm.startBroadcast();

        MembershipNFT nft = new MembershipNFT(deployer);

        vm.stopBroadcast();

        console2.log("=== Base Sepolia Deployment ===");
        console2.log("MembershipNFT:", address(nft));
        console2.log("Admin:        ", deployer);
        console2.log("");
        console2.log("Set in .env:");
        console2.log("  MEMBERSHIP_NFT=", address(nft));
    }
}
