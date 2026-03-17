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
import {IStableGate} from "../src/interfaces/IStableGate.sol";

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

        // Seed narrow-range liquidity (required for pool state to be valid)
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0}),
            ZERO_BYTES
        );

        // Seed full-range liquidity so PoolManager holds enough tokens for CSMM take() calls.
        // CSMM's beforeSwap calls poolManager.take(input, hook, amount) which is a real ERC20 transfer
        // from PoolManager to the hook — PoolManager must hold the tokens upfront within the unlock.
        // With tickSpacing=60, the widest valid range is -887220 to +887220.
        // 2e22 liquidity at full range deposits ~120e18 tokens of each currency into PoolManager.
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 2e22, salt: 0}),
            ZERO_BYTES
        );

        // Seed hook reserves — CSMM swaps are fulfilled directly from the hook's token balances.
        // Use 100_000e18 so tier fee tests with 10_000e18 swap amounts have plenty of headroom.
        currency0.transfer(address(hook), 100_000e18);
        currency1.transfer(address(hook), 100_000e18);

        // Pre-set institution1 to Gold tier so all existing 1:1 swap assertions continue to pass.
        // New tier tests explicitly set the tier they need (Silver / Bronze / Gold).
        vm.prank(owner);
        hook.setInstitutionTier(institution1, IStableGate.Tier.Gold);
    }

    // ─── Step 5: Allowlist management ────────────────────────────────────────

    function test_ownerCanAddToAllowlist() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);
        assertTrue(hook.isAllowlisted(institution1));
        assertEq(hook.allowlistCount(), 1);
    }

    function test_reactiveProxyCanAddViaReactiveFunction() public {
        // Reactive Network delivers callbacks via addToAllowlistReactive(rvmId, account).
        // The proxy calls the two-arg variant; address(0) is the RVM ID placeholder.
        vm.prank(reactiveProxy);
        hook.addToAllowlistReactive(address(0), institution1);
        assertTrue(hook.isAllowlisted(institution1));
    }

    function test_revert_unauthorizedCannotAdd() public {
        vm.prank(unauthorized);
        vm.expectRevert(PermissionedCSMMHook.NotOwner.selector);
        hook.addToAllowlist(institution1);
    }

    function test_revert_nonProxyCannotCallReactiveFunction() public {
        vm.prank(unauthorized);
        vm.expectRevert(PermissionedCSMMHook.NotOwnerOrReactive.selector);
        hook.addToAllowlistReactive(address(0), institution1);
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

        // Old proxy should now be rejected on the reactive path
        vm.prank(reactiveProxy);
        vm.expectRevert(PermissionedCSMMHook.NotOwnerOrReactive.selector);
        hook.addToAllowlistReactive(address(0), institution1);

        // New proxy is accepted on the reactive path
        vm.prank(newProxy);
        hook.addToAllowlistReactive(address(0), institution1);
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
        uint256 bal1Before = currency1.balanceOf(address(this));

        bytes memory hookData = abi.encode(institution1);
        swap(poolKey, true, -1e15, hookData);

        // CSMM: spent exactly 1e15 token0, received exactly 1e15 token1
        assertEq(bal0Before - currency0.balanceOf(address(this)), 1e15);
        assertEq(currency1.balanceOf(address(this)) - bal1Before, 1e15);
    }

    function test_swapReverseDirection() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);

        uint256 bal0Before = currency0.balanceOf(address(this));
        uint256 bal1Before = currency1.balanceOf(address(this));

        bytes memory hookData = abi.encode(institution1);
        swap(poolKey, false, -1e15, hookData);

        // CSMM: spent exactly 1e15 token1, received exactly 1e15 token0
        assertEq(bal1Before - currency1.balanceOf(address(this)), 1e15);
        assertEq(currency0.balanceOf(address(this)) - bal0Before, 1e15);
    }

    // ─── Step 8: CSMM pricing tests ──────────────────────────────────────────

    function test_csmmExactInputZeroForOne() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);

        uint256 bal0Before = currency0.balanceOf(address(this));
        uint256 bal1Before = currency1.balanceOf(address(this));

        bytes memory hookData = abi.encode(institution1);
        swap(poolKey, true, -1e18, hookData);

        assertEq(bal0Before - currency0.balanceOf(address(this)), 1e18, "spent exactly 1e18 token0");
        assertEq(currency1.balanceOf(address(this)) - bal1Before, 1e18, "received exactly 1e18 token1");
    }

    function test_csmmExactInputOneForZero() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);

        uint256 bal0Before = currency0.balanceOf(address(this));
        uint256 bal1Before = currency1.balanceOf(address(this));

        bytes memory hookData = abi.encode(institution1);
        swap(poolKey, false, -1e18, hookData);

        assertEq(bal1Before - currency1.balanceOf(address(this)), 1e18, "spent exactly 1e18 token1");
        assertEq(currency0.balanceOf(address(this)) - bal0Before, 1e18, "received exactly 1e18 token0");
    }

    function test_csmmOneToOneRatio() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);

        bytes memory hookData = abi.encode(institution1);
        uint256[3] memory amounts = [uint256(0.1e18), uint256(1e18), uint256(10e18)];

        for (uint256 i = 0; i < 3; i++) {
            uint256 bal0Before = currency0.balanceOf(address(this));
            uint256 bal1Before = currency1.balanceOf(address(this));

            swap(poolKey, true, -int256(amounts[i]), hookData);

            assertEq(bal0Before - currency0.balanceOf(address(this)), amounts[i]);
            assertEq(currency1.balanceOf(address(this)) - bal1Before, amounts[i]);
        }
    }

    function test_swapEmitsEvent() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);

        bytes memory hookData = abi.encode(institution1);

        vm.expectEmit(true, true, false, true, address(hook));
        emit SwapExecuted(institution1, poolKey.toId(), true, -1e18);

        swap(poolKey, true, -1e18, hookData);
    }

    // Re-declare SwapExecuted to use with vm.expectEmit
    event SwapExecuted(address indexed swapper, PoolId indexed poolId, bool zeroForOne, int256 amountSpecified);
    event TierUpdated(address indexed institution, IStableGate.Tier tier);

    // ─── Step 20: Tier-Based Fee & Expiry Tests ───────────────────────────────

    function test_goldTierZeroFee() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);
        // institution1 is already set to Gold in setUp

        uint256 amount = 10_000e18;
        uint256 bal0Before = currency0.balanceOf(address(this));
        uint256 bal1Before = currency1.balanceOf(address(this));

        bytes memory hookData = abi.encode(institution1);
        swap(poolKey, true, -int256(amount), hookData);

        // Gold = 0 fee: output == input exactly
        assertEq(bal0Before - currency0.balanceOf(address(this)), amount, "spent exact amount");
        assertEq(currency1.balanceOf(address(this)) - bal1Before, amount, "received exact amount");
    }

    function test_silverTierFee() public {
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Silver);

        // 1 bps = 100 ppm. For 10_000e18: fee = 10_000e18 * 100 / 1_000_000 = 1e18
        uint256 amount = 10_000e18;
        uint256 expectedFee = amount * 100 / 1_000_000;
        uint256 expectedOut = amount - expectedFee;

        uint256 bal0Before = currency0.balanceOf(address(this));
        uint256 bal1Before = currency1.balanceOf(address(this));

        swap(poolKey, true, -int256(amount), abi.encode(institution2));

        assertEq(bal0Before - currency0.balanceOf(address(this)), amount, "spent exact input");
        assertEq(currency1.balanceOf(address(this)) - bal1Before, expectedOut, "silver fee deducted");
    }

    function test_bronzeTierFee() public {
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);

        // 3 bps = 300 ppm. For 10_000e18: fee = 10_000e18 * 300 / 1_000_000 = 3e18
        uint256 amount = 10_000e18;
        uint256 expectedFee = amount * 300 / 1_000_000;
        uint256 expectedOut = amount - expectedFee;

        uint256 bal1Before = currency1.balanceOf(address(this));

        swap(poolKey, true, -int256(amount), abi.encode(institution2));

        assertEq(currency1.balanceOf(address(this)) - bal1Before, expectedOut, "bronze fee deducted");
    }

    function test_revert_expiredMembership() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);
        vm.prank(owner);
        hook.setInstitutionExpiry(institution1, block.timestamp + 30 days);

        vm.warp(block.timestamp + 30 days + 1);

        bytes memory innerError = abi.encodeWithSelector(
            IStableGate.MembershipExpired.selector,
            institution1
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                innerError,
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
        swap(poolKey, true, -1e18, abi.encode(institution1));
    }

    function test_notExpiredBeforeDeadline() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);
        vm.prank(owner);
        hook.setInstitutionExpiry(institution1, block.timestamp + 30 days);

        vm.warp(block.timestamp + 30 days - 1);

        uint256 bal1Before = currency1.balanceOf(address(this));
        swap(poolKey, true, -1e18, abi.encode(institution1));
        // Gold tier: 1:1 swap should succeed
        assertEq(currency1.balanceOf(address(this)) - bal1Before, 1e18);
    }

    function test_setTierByOwner() public {
        vm.prank(owner);
        hook.setInstitutionTier(institution1, IStableGate.Tier.Silver);
        assertEq(uint8(hook.institutionTier(institution1)), uint8(IStableGate.Tier.Silver));
    }

    function test_setTierByProxy() public {
        vm.prank(reactiveProxy);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Gold);
        assertEq(uint8(hook.institutionTier(institution2)), uint8(IStableGate.Tier.Gold));
    }

    function test_revert_setTierUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(PermissionedCSMMHook.NotOwnerOrReactive.selector);
        hook.setInstitutionTier(institution1, IStableGate.Tier.Gold);
    }

    function test_tierUpgradeAffectsFee() public {
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);

        uint256 amount = 10_000e18;
        uint256 bronzeOut = amount - (amount * 300 / 1_000_000);

        uint256 bal1Before = currency1.balanceOf(address(this));
        swap(poolKey, true, -int256(amount), abi.encode(institution2));
        uint256 bronzeReceived = currency1.balanceOf(address(this)) - bal1Before;
        assertEq(bronzeReceived, bronzeOut, "bronze fee applied");

        // Upgrade to Gold
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Gold);

        uint256 bal1Before2 = currency1.balanceOf(address(this));
        swap(poolKey, true, -int256(amount), abi.encode(institution2));
        uint256 goldReceived = currency1.balanceOf(address(this)) - bal1Before2;
        assertEq(goldReceived, amount, "gold zero fee after upgrade");
        assertTrue(goldReceived > bronzeReceived, "gold output > bronze output");
    }

    // ─── Step 22: Daily Volume Limit Tests ────────────────────────────────────

    function test_noCapByDefault() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);

        // No limit set — large swap should succeed
        swap(poolKey, true, -10_000e18, abi.encode(institution1));
    }

    function test_swapUnderLimit() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);
        vm.prank(owner);
        hook.setDailyLimit(institution1, 20_000e18);

        uint256 bal1Before = currency1.balanceOf(address(this));
        swap(poolKey, true, -10_000e18, abi.encode(institution1));
        assertEq(currency1.balanceOf(address(this)) - bal1Before, 10_000e18);
    }

    function test_revert_swapOverLimit() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);
        vm.prank(owner);
        hook.setDailyLimit(institution1, 5_000e18);

        bytes memory innerError = abi.encodeWithSelector(
            IStableGate.DailyLimitExceeded.selector,
            institution1,
            uint256(5_000e18),
            uint256(10_000e18)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                innerError,
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
        swap(poolKey, true, -10_000e18, abi.encode(institution1));
    }

    function test_cumulativeVolumeTracked() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);
        vm.prank(owner);
        hook.setDailyLimit(institution1, 10_000e18);

        // First swap of 6_000e18 succeeds
        swap(poolKey, true, -6_000e18, abi.encode(institution1));

        // Second swap of 6_000e18 would total 12_000e18 > 10_000e18 limit — reverts
        bytes memory innerError = abi.encodeWithSelector(
            IStableGate.DailyLimitExceeded.selector,
            institution1,
            uint256(10_000e18),
            uint256(6_000e18)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                innerError,
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
        swap(poolKey, true, -6_000e18, abi.encode(institution1));
    }

    function test_resetAfterBlockWindow() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);
        vm.prank(owner);
        hook.setDailyLimit(institution1, 10_000e18);

        // First swap fills limit
        swap(poolKey, true, -10_000e18, abi.encode(institution1));

        // Advance past the block window
        vm.roll(block.number + hook.blocksPerDay() + 1);

        // Volume counter resets — previously blocked swap now succeeds
        swap(poolKey, true, -10_000e18, abi.encode(institution1));
    }

    function test_perInstitutionLimit() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Gold);

        vm.prank(owner);
        hook.setDailyLimit(institution1, 5_000e18);  // low cap
        vm.prank(owner);
        hook.setDailyLimit(institution2, 50_000e18); // high cap

        // institution2 can swap large amounts
        swap(poolKey, true, -20_000e18, abi.encode(institution2));

        // institution1 is blocked at its lower cap
        bytes memory innerError = abi.encodeWithSelector(
            IStableGate.DailyLimitExceeded.selector,
            institution1,
            uint256(5_000e18),
            uint256(10_000e18)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                innerError,
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
        swap(poolKey, true, -10_000e18, abi.encode(institution1));
    }

    function test_defaultLimitApplied() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);
        vm.prank(owner);
        hook.setDefaultDailyLimit(8_000e18);

        // Swap under default limit succeeds
        swap(poolKey, true, -8_000e18, abi.encode(institution1));

        // Next swap would exceed it
        bytes memory innerError = abi.encodeWithSelector(
            IStableGate.DailyLimitExceeded.selector,
            institution1,
            uint256(8_000e18),
            uint256(1e18)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                innerError,
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
        swap(poolKey, true, -1e18, abi.encode(institution1));
    }

    function test_specificLimitOverridesDefault() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);
        vm.prank(owner);
        hook.setDefaultDailyLimit(5_000e18);

        // Override with higher institution-specific limit
        vm.prank(owner);
        hook.setDailyLimit(institution1, 20_000e18);

        // Swap beyond default limit but within specific limit — succeeds
        swap(poolKey, true, -15_000e18, abi.encode(institution1));
    }
}
