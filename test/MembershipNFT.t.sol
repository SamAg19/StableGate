// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MembershipNFT} from "../src/MembershipNFT.sol";

contract MembershipNFTTest is Test {
    MembershipNFT nft;

    address admin = makeAddr("admin");
    address institution1 = makeAddr("institution1");
    address institution2 = makeAddr("institution2");
    address nonAdmin = makeAddr("nonAdmin");

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
}
