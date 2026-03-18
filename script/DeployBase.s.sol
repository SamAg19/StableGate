// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MembershipNFT} from "../src/MembershipNFT.sol";
import {LPMembershipNFT} from "../src/LPMembershipNFT.sol";

/// @notice Deploy MembershipNFT + LPMembershipNFT to Base Sepolia.
///
/// Usage:
///   source .env
///   forge script script/DeployBase.s.sol \
///     --rpc-url $BASE_SEPOLIA_RPC \
///     --broadcast \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     -vvv
contract DeployBase is Script {
    /// @dev Default membership validity: 365 days. Override by calling setDefaultExpiryDuration post-deploy.
    uint256 constant DEFAULT_EXPIRY_DURATION = 365 days;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        vm.startBroadcast();

        MembershipNFT nft = new MembershipNFT(deployer);
        LPMembershipNFT lpNft = new LPMembershipNFT(deployer);

        // Configure default expiry so new memberships expire after 1 year by default.
        nft.setDefaultExpiryDuration(DEFAULT_EXPIRY_DURATION);

        vm.stopBroadcast();

        console2.log("=== Base Sepolia Deployment ===");
        console2.log("MembershipNFT:          ", address(nft));
        console2.log("LPMembershipNFT:        ", address(lpNft));
        console2.log("Admin:                  ", deployer);
        console2.log("DefaultExpiryDuration:  ", DEFAULT_EXPIRY_DURATION, "seconds (365 days)");
        console2.log("");
        console2.log("Set in .env:");
        console2.log("  MEMBERSHIP_NFT=", address(nft));
        console2.log("  LP_MEMBERSHIP_NFT=", address(lpNft));
    }
}
