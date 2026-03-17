// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MembershipNFT} from "../src/MembershipNFT.sol";
import {IStableGate} from "../src/interfaces/IStableGate.sol";

contract MembershipNFTTest is Test {
    MembershipNFT nft;

    address admin = makeAddr("admin");
    address institution1 = makeAddr("institution1");
    address institution2 = makeAddr("institution2");
    address nonAdmin = makeAddr("nonAdmin");

    // Re-declare for vm.expectEmit — must match IStableGate (tier is indexed)
    event TierUpdated(address indexed institution, IStableGate.Tier indexed tier);

    function setUp() public {
        nft = new MembershipNFT(admin);
    }

    function test_initialState() public {
        assertEq(nft.admin(), admin);
        assertEq(nft.nextTokenId(), 1);
        assertEq(nft.name(), "StableGate Membership");
        assertEq(nft.symbol(), "SGM");
    }

    function test_grantMembership() public {
        vm.prank(admin);
        uint256 tokenId = nft.grantMembership(institution1);

        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(1), institution1);
        assertTrue(nft.isMember(institution1));
        assertEq(nft.nextTokenId(), 2);
    }

    function test_grantMultipleMemberships() public {
        vm.prank(admin);
        uint256 id1 = nft.grantMembership(institution1);

        vm.prank(admin);
        uint256 id2 = nft.grantMembership(institution2);

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertTrue(nft.isMember(institution1));
        assertTrue(nft.isMember(institution2));
        assertEq(nft.nextTokenId(), 3);
    }

    function test_revokeMembership() public {
        vm.prank(admin);
        uint256 tokenId = nft.grantMembership(institution1);

        vm.prank(admin);
        nft.revokeMembership(tokenId);

        assertFalse(nft.isMember(institution1));
    }

    function test_revert_nonAdminMint() public {
        vm.prank(nonAdmin);
        vm.expectRevert(MembershipNFT.NotAdmin.selector);
        nft.grantMembership(institution1);
    }

    function test_revert_nonAdminRevoke() public {
        vm.prank(admin);
        uint256 tokenId = nft.grantMembership(institution1);

        vm.prank(nonAdmin);
        vm.expectRevert(MembershipNFT.NotAdmin.selector);
        nft.revokeMembership(tokenId);
    }

    function test_revert_mintToZero() public {
        vm.prank(admin);
        vm.expectRevert(MembershipNFT.ZeroAddress.selector);
        nft.grantMembership(address(0));
    }

    function test_transferAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        nft.transferAdmin(newAdmin);

        assertEq(nft.admin(), newAdmin);

        // old admin is blocked
        vm.prank(admin);
        vm.expectRevert(MembershipNFT.NotAdmin.selector);
        nft.grantMembership(institution1);

        // new admin can mint
        vm.prank(newAdmin);
        uint256 tokenId = nft.grantMembership(institution1);
        assertEq(tokenId, 1);
    }

    function test_mintEmitsTransferEvent() public {
        // This is the ERC721 Transfer(address(0), to, tokenId) event that the RSC subscribes to
        vm.expectEmit(true, true, true, false);
        emit Transfer(address(0), institution1, 1);

        vm.prank(admin);
        nft.grantMembership(institution1);
    }

    // Declare the ERC721 Transfer event for expectEmit
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    // ─── Step 18: Tier & Expiry Tests ─────────────────────────────────────────

    function test_defaultTierIsBronze() public {
        vm.prank(admin);
        uint256 tokenId = nft.grantMembership(institution1);
        assertEq(uint8(nft.tokenTier(tokenId)), uint8(IStableGate.Tier.Bronze));
        assertEq(uint8(nft.getTier(institution1)), uint8(IStableGate.Tier.Bronze));
    }

    function test_grantWithTier() public {
        vm.prank(admin);
        uint256 tokenId = nft.grantMembershipWithTier(institution1, IStableGate.Tier.Gold);
        assertEq(uint8(nft.tokenTier(tokenId)), uint8(IStableGate.Tier.Gold));
        assertEq(uint8(nft.getTier(institution1)), uint8(IStableGate.Tier.Gold));
    }

    function test_setTier() public {
        vm.prank(admin);
        uint256 tokenId = nft.grantMembership(institution1);

        // tier is indexed (topic_2), data is empty — check topic1 + topic2, no data
        vm.expectEmit(true, true, false, false, address(nft));
        emit TierUpdated(institution1, IStableGate.Tier.Gold);

        vm.prank(admin);
        nft.setTier(tokenId, IStableGate.Tier.Gold);

        assertEq(uint8(nft.tokenTier(tokenId)), uint8(IStableGate.Tier.Gold));
    }

    function test_revert_setTierNonAdmin() public {
        vm.prank(admin);
        uint256 tokenId = nft.grantMembership(institution1);

        vm.prank(nonAdmin);
        vm.expectRevert(MembershipNFT.NotAdmin.selector);
        nft.setTier(tokenId, IStableGate.Tier.Gold);
    }

    function test_expirySetOnMint() public {
        vm.prank(admin);
        nft.setDefaultExpiryDuration(365 days);

        vm.warp(1000);
        vm.prank(admin);
        uint256 tokenId = nft.grantMembership(institution1);

        assertEq(nft.tokenExpiry(tokenId), 1000 + 365 days);
    }

    function test_isExpiredFalseWhenFresh() public {
        vm.prank(admin);
        nft.setDefaultExpiryDuration(365 days);

        vm.prank(admin);
        uint256 tokenId = nft.grantMembership(institution1);

        assertFalse(nft.isExpired(tokenId));
    }

    function test_isExpiredTrueAfterWarp() public {
        vm.prank(admin);
        nft.setDefaultExpiryDuration(365 days);

        vm.prank(admin);
        uint256 tokenId = nft.grantMembership(institution1);

        vm.warp(block.timestamp + 365 days + 1);
        assertTrue(nft.isExpired(tokenId));
    }

    function test_setExpiry() public {
        vm.prank(admin);
        uint256 tokenId = nft.grantMembership(institution1);

        // no expiry by default (defaultExpiryDuration == 0)
        assertFalse(nft.isExpired(tokenId));

        vm.prank(admin);
        nft.setExpiry(tokenId, block.timestamp + 1 days);

        assertFalse(nft.isExpired(tokenId));

        vm.warp(block.timestamp + 2 days);
        assertTrue(nft.isExpired(tokenId));
    }

    function test_revert_transferBlocked() public {
        vm.prank(admin);
        nft.grantMembership(institution1);

        vm.prank(institution1);
        vm.expectRevert(MembershipNFT.TransferRestricted.selector);
        nft.transferFrom(institution1, institution2, 1);
    }

    function test_burnStillWorks() public {
        vm.prank(admin);
        uint256 tokenId = nft.grantMembership(institution1);

        vm.prank(admin);
        nft.revokeMembership(tokenId);

        assertFalse(nft.isMember(institution1));
    }
}
