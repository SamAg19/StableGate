// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LPMembershipNFT} from "../src/LPMembershipNFT.sol";

contract LPMembershipNFTTest is Test {
    LPMembershipNFT nft;

    address admin = makeAddr("admin");
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address nonAdmin = makeAddr("nonAdmin");

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    function setUp() public {
        nft = new LPMembershipNFT(admin);
    }

    function test_initialState() public {
        assertEq(nft.admin(), admin);
        assertEq(nft.nextTokenId(), 1);
        assertEq(nft.name(), "StableGate LP Membership");
        assertEq(nft.symbol(), "SGLP");
    }

    function test_grantLPMembership() public {
        vm.prank(admin);
        uint256 tokenId = nft.grantLPMembership(lp1);

        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(1), lp1);
        assertTrue(nft.isLPMember(lp1));
        assertEq(nft.nextTokenId(), 2);
    }

    function test_grantMultiple() public {
        vm.prank(admin);
        uint256 id1 = nft.grantLPMembership(lp1);
        vm.prank(admin);
        uint256 id2 = nft.grantLPMembership(lp2);

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertTrue(nft.isLPMember(lp1));
        assertTrue(nft.isLPMember(lp2));
    }

    function test_revokeLPMembership() public {
        vm.prank(admin);
        uint256 tokenId = nft.grantLPMembership(lp1);

        vm.prank(admin);
        nft.revokeLPMembership(tokenId);

        assertFalse(nft.isLPMember(lp1));
    }

    function test_revert_nonAdminMint() public {
        vm.prank(nonAdmin);
        vm.expectRevert(LPMembershipNFT.NotAdmin.selector);
        nft.grantLPMembership(lp1);
    }

    function test_revert_nonAdminRevoke() public {
        vm.prank(admin);
        uint256 tokenId = nft.grantLPMembership(lp1);

        vm.prank(nonAdmin);
        vm.expectRevert(LPMembershipNFT.NotAdmin.selector);
        nft.revokeLPMembership(tokenId);
    }

    function test_revert_mintToZero() public {
        vm.prank(admin);
        vm.expectRevert(LPMembershipNFT.ZeroAddress.selector);
        nft.grantLPMembership(address(0));
    }

    function test_transferAdmin() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        nft.transferAdmin(newAdmin);
        assertEq(nft.admin(), newAdmin);

        vm.prank(admin);
        vm.expectRevert(LPMembershipNFT.NotAdmin.selector);
        nft.grantLPMembership(lp1);

        vm.prank(newAdmin);
        uint256 tokenId = nft.grantLPMembership(lp1);
        assertEq(tokenId, 1);
    }

    function test_revert_transferBlocked() public {
        vm.prank(admin);
        nft.grantLPMembership(lp1);

        vm.prank(lp1);
        vm.expectRevert(LPMembershipNFT.TransferRestricted.selector);
        nft.transferFrom(lp1, lp2, 1);
    }

    function test_burnStillWorks() public {
        vm.prank(admin);
        uint256 tokenId = nft.grantLPMembership(lp1);

        vm.prank(admin);
        nft.revokeLPMembership(tokenId);

        assertFalse(nft.isLPMember(lp1));
    }

    function test_mintEmitsTransferEvent() public {
        vm.expectEmit(true, true, true, false);
        emit Transfer(address(0), lp1, 1);

        vm.prank(admin);
        nft.grantLPMembership(lp1);
    }
}
