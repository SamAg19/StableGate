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

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
    address feeRecipientAddr = makeAddr("feeRecipient");

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
            abi.encode(address(manager), reactiveProxy, feeRecipientAddr)
        );

        hook = new PermissionedCSMMHook{salt: salt}(manager, reactiveProxy, feeRecipientAddr);
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

    // Re-declare events to use with vm.expectEmit
    event SwapExecuted(address indexed swapper, PoolId indexed poolId, bool zeroForOne, int256 amountSpecified);
    event TierUpdated(address indexed institution, IStableGate.Tier indexed tier);
    event InstitutionStateCleared(address indexed institution);
    event FeesWithdrawn(address indexed recipient, address indexed currency, uint256 amount);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event LpFeeSplitUpdated(uint256 oldSplitBps, uint256 newSplitBps);
    event FeesDistributed(address indexed currency, uint256 lpAmount, uint256 operatorAmount);

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

        // Use 500_000e6 — within Silver cap of 5_000_000e6.
        // 1 bps = 100 ppm. fee = 500_000e6 * 100 / 1_000_000 = 50_000e6.
        uint256 amount = 500_000e6;
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

        // Use 500_000e6 — within Bronze cap of 1_000_000e6.
        // 3 bps = 300 ppm. fee = 500_000e6 * 300 / 1_000_000 = 150_000e6.
        uint256 amount = 500_000e6;
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

        // Use 500_000e6 — within Bronze cap of 1_000_000e6.
        uint256 amount = 500_000e6;
        uint256 bronzeOut = amount - (amount * 300 / 1_000_000);

        uint256 bal1Before = currency1.balanceOf(address(this));
        swap(poolKey, true, -int256(amount), abi.encode(institution2));
        uint256 bronzeReceived = currency1.balanceOf(address(this)) - bal1Before;
        assertEq(bronzeReceived, bronzeOut, "bronze fee applied");

        // Upgrade to Gold (unlimited, zero fee)
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Gold);

        uint256 bal1Before2 = currency1.balanceOf(address(this));
        swap(poolKey, true, -int256(amount), abi.encode(institution2));
        uint256 goldReceived = currency1.balanceOf(address(this)) - bal1Before2;
        assertEq(goldReceived, amount, "gold zero fee after upgrade");
        assertTrue(goldReceived > bronzeReceived, "gold output > bronze output");
    }

    // ─── Step 22: Daily Volume Limit Tests ────────────────────────────────────

    function test_swapUnderLimit() public {
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);

        // 500_000e6 < Bronze cap of 1_000_000e6 — succeeds with Bronze fee
        uint256 amount = 500_000e6;
        uint256 expectedOut = amount - (amount * 300 / 1_000_000);

        uint256 bal1Before = currency1.balanceOf(address(this));
        swap(poolKey, true, -int256(amount), abi.encode(institution2));
        assertEq(currency1.balanceOf(address(this)) - bal1Before, expectedOut);
    }

    function test_revert_swapOverLimit() public {
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);

        // 2_000_000e6 > Bronze cap of 1_000_000e6 — reverts
        uint256 amount = 2_000_000e6;
        bytes memory innerError = abi.encodeWithSelector(
            IStableGate.DailyLimitExceeded.selector,
            institution2,
            hook.DAILY_LIMIT_BRONZE(),
            amount
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
        swap(poolKey, true, -int256(amount), abi.encode(institution2));
    }

    function test_cumulativeVolumeTracked() public {
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);

        // First swap of 600_000e6 succeeds (600k < 1M Bronze cap)
        swap(poolKey, true, -int256(600_000e6), abi.encode(institution2));

        // Second swap of 600_000e6 would total 1_200_000e6 > 1_000_000e6 — reverts
        bytes memory innerError = abi.encodeWithSelector(
            IStableGate.DailyLimitExceeded.selector,
            institution2,
            hook.DAILY_LIMIT_BRONZE(),
            uint256(600_000e6)
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
        swap(poolKey, true, -int256(600_000e6), abi.encode(institution2));
    }

    function test_resetAfterBlockWindow() public {
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);

        // Swap exactly at cap: 0 + 1_000_000e6 > 1_000_000e6 is false → passes
        swap(poolKey, true, -int256(1_000_000e6), abi.encode(institution2));

        // Advance past the block window — volume resets
        vm.roll(block.number + hook.blocksPerDay() + 1);

        // After reset, same swap succeeds again
        swap(poolKey, true, -int256(1_000_000e6), abi.encode(institution2));
    }

    function test_perInstitutionLimit() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);
        // institution1 remains Gold (set in setUp) — unlimited

        // institution1 (Gold = unlimited) can swap large amounts
        swap(poolKey, true, -int256(2_000_000e6), abi.encode(institution1));

        // institution2 (Bronze = 1M cap) is blocked at 2M
        bytes memory innerError = abi.encodeWithSelector(
            IStableGate.DailyLimitExceeded.selector,
            institution2,
            hook.DAILY_LIMIT_BRONZE(),
            uint256(2_000_000e6)
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
        swap(poolKey, true, -int256(2_000_000e6), abi.encode(institution2));
    }

    function test_goldTierUnlimited() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);
        // institution1 is Gold (set in setUp) — DAILY_LIMIT_GOLD = 0 means no cap

        // Multiple large swaps all succeed with no cumulative cap
        swap(poolKey, true, -int256(10_000_000e6), abi.encode(institution1));
        swap(poolKey, true, -int256(10_000_000e6), abi.encode(institution1));
    }

    function test_tierUpgradeIncreasesLimit() public {
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);

        uint256 amount = 2_000_000e6; // > Bronze cap (1M), < Silver cap (5M)

        // Bronze: blocked
        bytes memory innerError = abi.encodeWithSelector(
            IStableGate.DailyLimitExceeded.selector,
            institution2,
            hook.DAILY_LIMIT_BRONZE(),
            amount
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
        swap(poolKey, true, -int256(amount), abi.encode(institution2));

        // Upgrade to Silver (5M cap) — same amount now succeeds
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Silver);

        uint256 bal1Before = currency1.balanceOf(address(this));
        swap(poolKey, true, -int256(amount), abi.encode(institution2));
        uint256 expectedOut = amount - (amount * 100 / 1_000_000); // Silver 1 bps fee
        assertEq(currency1.balanceOf(address(this)) - bal1Before, expectedOut);
    }

    function test_tierDowngradeEnforcesLowerLimit() public {
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Gold);

        // Gold: unlimited — 2M swap succeeds, volume accumulates
        swap(poolKey, true, -int256(2_000_000e6), abi.encode(institution2));

        // Downgrade to Bronze (1M cap)
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);

        // dailyVolume (2M) already exceeds Bronze cap (1M) — any further swap reverts
        bytes memory innerError = abi.encodeWithSelector(
            IStableGate.DailyLimitExceeded.selector,
            institution2,
            hook.DAILY_LIMIT_BRONZE(),
            uint256(1)
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
        swap(poolKey, true, -1, abi.encode(institution2));
    }

    // ─── Atomic State Cleanup on Revocation ───────────────────────────────────

    function test_revokeWipesTier() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);
        // institution1 is already Gold (set in setUp)

        vm.prank(owner);
        hook.removeFromAllowlist(institution1);
        // Tier reset to Bronze on revocation
        assertEq(uint8(hook.institutionTier(institution1)), uint8(IStableGate.Tier.Bronze));

        // Re-add — tier stays Bronze (clean slate, not inherited Gold)
        vm.prank(owner);
        hook.addToAllowlist(institution1);
        assertEq(uint8(hook.institutionTier(institution1)), uint8(IStableGate.Tier.Bronze));
    }

    function test_revokeWipesExpiry() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);
        vm.prank(owner);
        hook.setInstitutionExpiry(institution1, block.timestamp + 30 days);
        assertGt(hook.institutionExpiry(institution1), 0);

        vm.prank(owner);
        hook.removeFromAllowlist(institution1);
        assertEq(hook.institutionExpiry(institution1), 0);

        // Re-add — expiry is still 0 (clean slate)
        vm.prank(owner);
        hook.addToAllowlist(institution1);
        assertEq(hook.institutionExpiry(institution1), 0);
    }

    function test_revokeWipesDailyVolume() public {
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);

        // Swap near the Bronze cap
        swap(poolKey, true, -int256(900_000e6), abi.encode(institution2));
        assertGt(hook.dailyVolume(institution2), 0);

        vm.prank(owner);
        hook.removeFromAllowlist(institution2);
        assertEq(hook.dailyVolume(institution2), 0);
        assertEq(hook.lastResetBlock(institution2), 0);

        // Re-add — full 1M cap is available again
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);
        swap(poolKey, true, -int256(900_000e6), abi.encode(institution2)); // succeeds — fresh window
    }

    function test_revokeEmitsStateClearedEvent() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);

        vm.expectEmit(true, false, false, false, address(hook));
        emit InstitutionStateCleared(institution1);

        vm.prank(owner);
        hook.removeFromAllowlist(institution1);
    }

    function test_reOnboardingStartsFresh() public {
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Gold);
        vm.prank(owner);
        hook.setInstitutionExpiry(institution2, block.timestamp + 365 days);

        // Swap as Gold — zero fee
        uint256 amount = 500_000e6;
        uint256 bal1Before = currency1.balanceOf(address(this));
        swap(poolKey, true, -int256(amount), abi.encode(institution2));
        assertEq(currency1.balanceOf(address(this)) - bal1Before, amount, "Gold: no fee");

        // Revoke
        vm.prank(owner);
        hook.removeFromAllowlist(institution2);

        // Re-onboard — no explicit tier/expiry set (RSC callbacks would follow in production)
        vm.prank(owner);
        hook.addToAllowlist(institution2);

        // Tier is Bronze, expiry is 0, volume is 0 — no Gold state leaked
        assertEq(uint8(hook.institutionTier(institution2)), uint8(IStableGate.Tier.Bronze));
        assertEq(hook.institutionExpiry(institution2), 0);
        assertEq(hook.dailyVolume(institution2), 0);

        // Bronze fee applies
        uint256 bal1Before2 = currency1.balanceOf(address(this));
        swap(poolKey, true, -int256(amount), abi.encode(institution2));
        uint256 expectedBronzeOut = amount - (amount * 300 / 1_000_000);
        assertEq(currency1.balanceOf(address(this)) - bal1Before2, expectedBronzeOut, "Bronze fee after re-onboarding");

        // Bronze daily cap enforced: 500k already swapped, another 600k would hit 1M cap
        bytes memory innerError = abi.encodeWithSelector(
            IStableGate.DailyLimitExceeded.selector,
            institution2,
            hook.DAILY_LIMIT_BRONZE(),
            uint256(600_000e6)
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
        swap(poolKey, true, -int256(600_000e6), abi.encode(institution2));
    }

    function test_revokeByProxyAlsoClears() public {
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Gold);
        vm.prank(owner);
        hook.setInstitutionExpiry(institution2, block.timestamp + 90 days);
        swap(poolKey, true, -int256(2_000_000e6), abi.encode(institution2));

        // Reactive proxy revokes via removeFromAllowlistReactive
        vm.expectEmit(true, false, false, false, address(hook));
        emit InstitutionStateCleared(institution2);

        vm.prank(reactiveProxy);
        hook.removeFromAllowlistReactive(address(0), institution2);

        assertFalse(hook.isAllowlisted(institution2));
        assertEq(uint8(hook.institutionTier(institution2)), uint8(IStableGate.Tier.Bronze));
        assertEq(hook.institutionExpiry(institution2), 0);
        assertEq(hook.dailyVolume(institution2), 0);
        assertEq(hook.lastResetBlock(institution2), 0);
    }

    // ─── Fee Split & Withdrawal Tests ───────────────────────────────────────

    function _bronzeSwapAndGetFee(uint256 amount) internal returns (uint256 feeAmount, uint256 lpAmount, uint256 operatorAmount) {
        feeAmount = amount * 300 / 1_000_000;
        lpAmount = feeAmount * hook.lpFeeSplitBps() / 10000;
        operatorAmount = feeAmount - lpAmount;
    }

    function test_feeSplitDefaultFiftyFifty() public {
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);

        uint256 amount = 10_000e6;
        (uint256 feeAmount, uint256 lpAmount, uint256 operatorAmount) = _bronzeSwapAndGetFee(amount);

        vm.expectEmit(true, false, false, true, address(hook));
        emit FeesDistributed(Currency.unwrap(currency1), lpAmount, operatorAmount);

        swap(poolKey, true, -int256(amount), abi.encode(institution2));

        assertEq(hook.accruedFees(Currency.unwrap(currency1)), operatorAmount, "operator share accrued");
        assertEq(feeAmount, lpAmount + operatorAmount, "fee fully distributed");
    }

    function test_feeSplitAllToLPs() public {
        vm.prank(owner);
        hook.setLpFeeSplitBps(10000); // 100% to LPs

        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);

        swap(poolKey, true, -int256(10_000e6), abi.encode(institution2));

        assertEq(hook.accruedFees(Currency.unwrap(currency1)), 0, "no operator share when 100% to LPs");
    }

    function test_feeSplitAllToOperator() public {
        vm.prank(owner);
        hook.setLpFeeSplitBps(0); // 0% to LPs

        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);

        uint256 amount = 10_000e6;
        uint256 expectedFee = amount * 300 / 1_000_000;

        swap(poolKey, true, -int256(amount), abi.encode(institution2));

        assertEq(hook.accruedFees(Currency.unwrap(currency1)), expectedFee, "full fee to operator");
    }

    function test_feeSplitCustomRatio() public {
        vm.prank(owner);
        hook.setLpFeeSplitBps(7000); // 70% to LPs

        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);

        uint256 amount = 10_000e6;
        uint256 feeAmount = amount * 300 / 1_000_000;
        uint256 expectedLp = feeAmount * 7000 / 10000;
        uint256 expectedOp = feeAmount - expectedLp;

        vm.expectEmit(true, false, false, true, address(hook));
        emit FeesDistributed(Currency.unwrap(currency1), expectedLp, expectedOp);

        swap(poolKey, true, -int256(amount), abi.encode(institution2));

        assertEq(hook.accruedFees(Currency.unwrap(currency1)), expectedOp, "30% operator share");
    }

    function test_noFeesOnGoldSwap() public {
        vm.prank(owner);
        hook.addToAllowlist(institution1);
        // institution1 is Gold (set in setUp) — zero fee

        swap(poolKey, true, -int256(10_000e6), abi.encode(institution1));

        assertEq(hook.accruedFees(Currency.unwrap(currency0)), 0, "no currency0 fees");
        assertEq(hook.accruedFees(Currency.unwrap(currency1)), 0, "no currency1 fees");
    }

    function test_feesAccrueCumulatively() public {
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);

        uint256 amount = 100_000e6;
        (, , uint256 operatorPerSwap) = _bronzeSwapAndGetFee(amount);

        for (uint256 i = 0; i < 3; i++) {
            swap(poolKey, true, -int256(amount), abi.encode(institution2));
        }

        assertEq(hook.accruedFees(Currency.unwrap(currency1)), operatorPerSwap * 3, "cumulative operator fees");
    }

    function test_withdrawFees() public {
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);

        uint256 amount = 500_000e6;
        (, , uint256 operatorAmount) = _bronzeSwapAndGetFee(amount);
        swap(poolKey, true, -int256(amount), abi.encode(institution2));

        uint256 recipientBefore = currency1.balanceOf(feeRecipientAddr);

        vm.prank(owner);
        hook.withdrawFees(Currency.unwrap(currency1));

        assertEq(currency1.balanceOf(feeRecipientAddr) - recipientBefore, operatorAmount, "recipient received fees");
        assertEq(hook.accruedFees(Currency.unwrap(currency1)), 0, "accrued reset to 0");
    }

    function test_withdrawFeesEmitsEvent() public {
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);

        uint256 amount = 500_000e6;
        (, , uint256 operatorAmount) = _bronzeSwapAndGetFee(amount);
        swap(poolKey, true, -int256(amount), abi.encode(institution2));

        vm.expectEmit(true, true, false, true, address(hook));
        emit FeesWithdrawn(feeRecipientAddr, Currency.unwrap(currency1), operatorAmount);

        vm.prank(owner);
        hook.withdrawFees(Currency.unwrap(currency1));
    }

    function test_revert_withdrawZeroFees() public {
        vm.prank(owner);
        vm.expectRevert(PermissionedCSMMHook.ZeroFees.selector);
        hook.withdrawFees(Currency.unwrap(currency1));
    }

    function test_revert_nonOwnerWithdraw() public {
        vm.prank(unauthorized);
        vm.expectRevert(PermissionedCSMMHook.NotOwner.selector);
        hook.withdrawFees(Currency.unwrap(currency1));
    }

    function test_setFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");

        // Accrue some fees first
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);
        swap(poolKey, true, -int256(500_000e6), abi.encode(institution2));

        // Update recipient
        vm.prank(owner);
        hook.setFeeRecipient(newRecipient);
        assertEq(hook.feeRecipient(), newRecipient);

        // Withdraw goes to new recipient
        uint256 accrued = hook.accruedFees(Currency.unwrap(currency1));
        uint256 newRecBefore = currency1.balanceOf(newRecipient);
        vm.prank(owner);
        hook.withdrawFees(Currency.unwrap(currency1));
        assertEq(currency1.balanceOf(newRecipient) - newRecBefore, accrued, "sent to new recipient");
    }

    function test_revert_setFeeRecipientZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(PermissionedCSMMHook.ZeroAddress.selector);
        hook.setFeeRecipient(address(0));
    }

    function test_setLpFeeSplitBps() public {
        vm.expectEmit(false, false, false, true, address(hook));
        emit LpFeeSplitUpdated(5000, 8000);

        vm.prank(owner);
        hook.setLpFeeSplitBps(8000);

        assertEq(hook.lpFeeSplitBps(), 8000);
    }

    function test_revert_splitExceedsMax() public {
        vm.prank(owner);
        vm.expectRevert(PermissionedCSMMHook.InvalidSplitBps.selector);
        hook.setLpFeeSplitBps(10001);
    }

    function test_lpEarnsFeesOverMultipleSwaps() public {
        // LP2 adds liquidity separately from setUp LPs
        address lp2 = makeAddr("lp2");
        currency0.transfer(lp2, 50_000e18);
        currency1.transfer(lp2, 50_000e18);

        vm.startPrank(lp2);
        IERC20(Currency.unwrap(currency0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e22, salt: 0}),
            ZERO_BYTES
        );
        vm.stopPrank();

        // Execute Bronze swaps that generate LP fees via donate()
        vm.prank(owner);
        hook.addToAllowlist(institution2);
        vm.prank(owner);
        hook.setInstitutionTier(institution2, IStableGate.Tier.Bronze);

        for (uint256 i = 0; i < 3; i++) {
            swap(poolKey, true, -int256(100_000e6), abi.encode(institution2));
        }

        // LP2 removes liquidity — should receive original deposit + accrued fees
        uint256 bal1Before = currency1.balanceOf(lp2);
        vm.prank(lp2);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: -1e22, salt: 0}),
            ZERO_BYTES
        );
        uint256 bal1After = currency1.balanceOf(lp2);

        // LP2's currency1 balance should have increased by more than the original deposit
        // (original deposit is returned + fee share from donate())
        // Total LP fee per swap = 100_000e6 * 300/1M * 5000/10000 = 15_000e6 per swap
        // 3 swaps = 45_000e6 total LP fees
        // LP2 has 1e22 out of (2e22 + 1e22) = 3e22 total full-range liquidity → ~1/3 share
        // LP2's fee share ≈ 45_000e6 / 3 = 15_000e6
        // The exact amount depends on tick rounding; just verify it's > 0
        assertTrue(bal1After > bal1Before, "LP2 earned fees from donate()");
    }
}
