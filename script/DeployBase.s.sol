// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MembershipNFT} from "../src/MembershipNFT.sol";
import {LPMembershipNFT} from "../src/LPMembershipNFT.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockUSDT0} from "../src/mocks/MockUSDT0.sol";

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
    /// @dev Default membership validity: 365 days. Override by calling setDefaultExpiryDuration post-deploy.
    uint256 constant DEFAULT_EXPIRY_DURATION = 365 days;

    function run() external {
        address deployer    = vm.envAddress("DEPLOYER_ADDRESS");
        address institution = vm.envAddress("INSTITUTION_ADDRESS");

        vm.startBroadcast();

        MembershipNFT nft = new MembershipNFT(deployer);
        LPMembershipNFT lpNft = new LPMembershipNFT(deployer);

        // Configure default expiry so new memberships expire after 1 year by default.
        nft.setDefaultExpiryDuration(DEFAULT_EXPIRY_DURATION);

        // Deploy mock tokens for testnet
        MockUSDC  mockUSDC  = new MockUSDC();
        MockUSDT0 mockUSDT0 = new MockUSDT0();

        // Mint to operator — for seeding pool liquidity
        mockUSDC.mint(deployer,      500_000e6);
        mockUSDT0.mint(deployer,     500_000e6);

        // Mint to institution — for demo swaps and LP
        mockUSDC.mint(institution,   100_000e6);
        mockUSDT0.mint(institution,  100_000e6);

        vm.stopBroadcast();

        console2.log("=== Base Sepolia Deployment ===");
        console2.log("MembershipNFT:          ", address(nft));
        console2.log("LPMembershipNFT:        ", address(lpNft));
        console2.log("MockUSDC:               ", address(mockUSDC));
        console2.log("MockUSDT0:              ", address(mockUSDT0));
        console2.log("Admin:                  ", deployer);
        console2.log("DefaultExpiryDuration:  ", DEFAULT_EXPIRY_DURATION, "seconds (365 days)");
        console2.log("");
        console2.log("Operator USDC balance:     ", mockUSDC.balanceOf(deployer));
        console2.log("Institution USDC balance:  ", mockUSDC.balanceOf(institution));
        console2.log("");
        console2.log("Set in .env:");
        console2.log("  MEMBERSHIP_NFT=", address(nft));
        console2.log("  LP_MEMBERSHIP_NFT=", address(lpNft));
        console2.log("  USDC_ADDRESS=", address(mockUSDC));
        console2.log("  USDT0_ADDRESS=", address(mockUSDT0));
    }
}
