// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/mocks/MockUSDC.sol";
import "../src/mocks/MockUSDT0.sol";

contract MockTokensTest is Test {
    MockUSDC  usdc;
    MockUSDT0 usdt0;

    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");

    function setUp() public {
        usdc  = new MockUSDC();
        usdt0 = new MockUSDT0();
    }

    // ── Decimals ────────────────────────────────────────────────────────────

    function test_usdcDecimals() public view {
        assertEq(usdc.decimals(), 6);
    }

    function test_usdt0Decimals() public view {
        assertEq(usdt0.decimals(), 6);
    }

    // ── Mint ────────────────────────────────────────────────────────────────

    function test_anyoneCanMintUSDC() public {
        vm.prank(alice);
        usdc.mint(alice, 1_000e6);
        assertEq(usdc.balanceOf(alice), 1_000e6);
    }

    function test_anyoneCanMintUSDT0() public {
        vm.prank(alice);
        usdt0.mint(alice, 1_000e6);
        assertEq(usdt0.balanceOf(alice), 1_000e6);
    }

    function test_mintToAnotherAddress() public {
        vm.prank(alice);
        usdc.mint(bob, 500e6);
        assertEq(usdc.balanceOf(bob), 500e6);
        assertEq(usdc.balanceOf(alice), 0);
    }

    function test_mintIncrementsTotalSupply() public {
        usdc.mint(alice, 1_000e6);
        usdc.mint(bob,   2_000e6);
        assertEq(usdc.totalSupply(), 3_000e6);
    }

    // ── Transfer ────────────────────────────────────────────────────────────

    function test_transferWorks() public {
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.transfer(bob, 400e6);
        assertEq(usdc.balanceOf(alice), 600e6);
        assertEq(usdc.balanceOf(bob),   400e6);
    }

    function test_approveAndTransferFrom() public {
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(bob, 500e6);
        vm.prank(bob);
        usdc.transferFrom(alice, bob, 500e6);
        assertEq(usdc.balanceOf(alice), 500e6);
        assertEq(usdc.balanceOf(bob),   500e6);
    }

    // ── Name and symbol ─────────────────────────────────────────────────────

    function test_usdcNameAndSymbol() public view {
        assertEq(usdc.name(),   "USD Coin (Mock)");
        assertEq(usdc.symbol(), "USDC");
    }

    function test_usdt0NameAndSymbol() public view {
        assertEq(usdt0.name(),   "Tether USD0 (Mock)");
        assertEq(usdt0.symbol(), "USDT0");
    }
}
