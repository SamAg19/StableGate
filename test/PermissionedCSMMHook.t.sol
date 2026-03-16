// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {HookMiner} from "v4-hooks-public/utils/HookMiner.sol";

import {PermissionedCSMMHook} from "../src/PermissionedCSMMHook.sol";

contract PermissionedCSMMHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PermissionedCSMMHook hook;
    PoolKey poolKey;

    // The test contract itself is the deployer, so it starts as owner.
    // We transfer ownership to `owner` in setUp.
    address owner = makeAddr("owner");
    address institution1 = makeAddr("institution1");
    address institution2 = makeAddr("institution2");
    address unauthorized = makeAddr("unauthorized");
    address reactiveProxy = makeAddr("reactiveProxy");

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Mine a CREATE2 salt that produces an address with the correct permission flags
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            FLAGS,
            type(PermissionedCSMMHook).creationCode,
            abi.encode(address(manager), reactiveProxy)
        );

        hook = new PermissionedCSMMHook{salt: salt}(manager, reactiveProxy);
        assertEq(address(hook), hookAddr);

        // Transfer ownership to the designated owner address
        hook.transferOwnership(owner);

        // Init pool with the hook attached
        (poolKey,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);

        // Seed liquidity so swaps have tokens to trade against
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0}),
            ZERO_BYTES
        );
    }

    // ─── Step 5: Allowlist management ────────────────────────────────────────

    function test_ownerCanAddToAllowlist() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);
        assertTrue(hook.isAllowlisted(institution1));
        assertEq(hook.allowlistCount(), 1);
    }

    function test_reactiveProxyCanAddToAllowlist() public {
        vm.prank(reactiveProxy);
        hook.addToAllowlist(institution1);
        assertTrue(hook.isAllowlisted(institution1));
    }

    function test_revert_unauthorizedCannotAdd() public {
        vm.prank(unauthorized);
        vm.expectRevert(PermissionedCSMMHook.NotOwnerOrReactive.selector);
        hook.addToAllowlist(institution1);
    }

    function test_revert_cannotAddZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(PermissionedCSMMHook.AddZeroAddress.selector);
        hook.addToAllowlist(address(0));
    }

    function test_revert_cannotAddDuplicate() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PermissionedCSMMHook.AlreadyAllowlisted.selector, institution1));
        hook.addToAllowlist(institution1);
    }

    function test_ownerCanRemove() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);

        vm.prank(owner);
        hook.removeFromAllowlist(institution1);
        assertFalse(hook.isAllowlisted(institution1));
        assertEq(hook.allowlistCount(), 0);
    }

    function test_revert_nonOwnerCannotRemove() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);

        vm.prank(unauthorized);
        vm.expectRevert(PermissionedCSMMHook.NotOwner.selector);
        hook.removeFromAllowlist(institution1);
    }

    function test_batchAdd() public {
        address[] memory accounts = new address[](2);
        accounts[0] = institution1;
        accounts[1] = institution2;

        vm.prank(owner);
        hook.batchAddToAllowlist(accounts);

        assertTrue(hook.isAllowlisted(institution1));
        assertTrue(hook.isAllowlisted(institution2));
        assertEq(hook.allowlistCount(), 2);
    }

    function test_updateReactiveProxy() public {
        address newProxy = makeAddr("newProxy");

        vm.prank(owner);
        hook.setReactiveCallbackProxy(newProxy);
        assertEq(hook.reactiveCallbackProxy(), newProxy);

        // Old proxy should now be rejected
        vm.prank(reactiveProxy);
        vm.expectRevert(PermissionedCSMMHook.NotOwnerOrReactive.selector);
        hook.addToAllowlist(institution1);

        // New proxy is accepted
        vm.prank(newProxy);
        hook.addToAllowlist(institution1);
        assertTrue(hook.isAllowlisted(institution1));
    }

    function test_transferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        hook.transferOwnership(newOwner);
        assertEq(hook.owner(), newOwner);

        // Old owner is blocked
        vm.prank(owner);
        vm.expectRevert(PermissionedCSMMHook.NotOwner.selector);
        hook.removeFromAllowlist(institution1);

        // New owner can manage
        vm.prank(newOwner);
        hook.addToAllowlist(institution1);
        assertTrue(hook.isAllowlisted(institution1));
    }

    // ─── Step 6: Swap permissioning ──────────────────────────────────────────

    function test_revert_swapNotAllowlisted() public {
        bytes memory hookData = abi.encode(unauthorized);

        // PoolManager wraps hook errors in WrappedError(target, selector, reason, details).
        // Construct the exact expected bytes.
        bytes memory innerError = abi.encodeWithSelector(PermissionedCSMMHook.SwapperNotAllowlisted.selector, unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                innerError,
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
        swap(poolKey, true, -1e15, hookData);
    }

    function test_allowlistedCanSwap() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);

        uint256 bal0Before = currency0.balanceOf(address(this));

        bytes memory hookData = abi.encode(institution1);
        swap(poolKey, true, -1e15, hookData);

        // token0 was spent
        assertLt(currency0.balanceOf(address(this)), bal0Before);
    }

    function test_swapReverseDirection() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);

        uint256 bal1Before = currency1.balanceOf(address(this));

        bytes memory hookData = abi.encode(institution1);
        swap(poolKey, false, -1e15, hookData);

        // token1 was spent
        assertLt(currency1.balanceOf(address(this)), bal1Before);
    }
}
