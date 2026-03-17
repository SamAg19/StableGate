// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {HookMiner} from "v4-hooks-public/utils/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

import {PermissionedCSMMHook} from "../src/PermissionedCSMMHook.sol";
import {MembershipNFT} from "../src/MembershipNFT.sol";
import {AllowlistReactiveContract} from "../src/AllowlistReactiveContract.sol";
import {IStableGate} from "../src/interfaces/IStableGate.sol";

/// @title ForkDemoTest
/// @notice Multi-chain integration test / demo. Forks both Base mainnet and Unichain mainnet,
///         runs the full StableGate lifecycle across chains with real USDC and USDT0.
///
///         Chain topology (mirrors production exactly):
///           - Base mainnet fork      → MembershipNFT deployed here (on-chain credential)
///           - Reactive Lasna         → AllowlistReactiveContract deployed here (simulated locally)
///           - Unichain mainnet fork  → PermissionedCSMMHook + USDC/USDT0 pool
///
///         Run: forge test --match-contract ForkDemoTest -vvv
///
/// Flow demonstrated:
///   1. Non-allowlisted swap rejected on Unichain
///   2. Admin mints MembershipNFT on Base fork
///   3. RSC.react() called with the Base Transfer log → emits Callback event
///   4. Reactive Network delivers callback to Unichain (simulated via vm.prank proxy)
///   5. CSMM swap: 10,000 USDC → 10,000 USDT0 (1:1) on Unichain
///   6. Reverse swap: 5,000 USDT0 → 5,000 USDC (1:1)
///   7. Revoke removes access — further swaps blocked
contract ForkDemoTest is Test {
    using PoolIdLibrary for PoolKey;

    // ─── Unichain mainnet addresses ───────────────────────────────────────────

    IPoolManager constant POOL_MANAGER = IPoolManager(0x1F98400000000000000000000000000000000004);
    address constant USDC  = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
    address constant USDT0 = 0x9151434b16b9763660705744891fA906F660EcC5;

    /// @dev Reactive Network Callback Proxy on Unichain — delivers cross-chain callbacks.
    address constant REACTIVE_CALLBACK_PROXY = 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4;

    // keccak256("Transfer(address,address,uint256)") — ERC721 Transfer topic
    uint256 constant TRANSFER_TOPIC =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    // sqrtPriceX96 for price 1:1 (both tokens are 6 decimals)
    uint160 constant SQRT_PRICE_1_1  = 79228162514264337593543950336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    // ─── Test actors ──────────────────────────────────────────────────────────

    address owner       = makeAddr("owner");
    address institution = makeAddr("institution");

    // ─── Fork IDs ─────────────────────────────────────────────────────────────

    uint256 baseForkId;
    uint256 unichainForkId;

    // ─── Deployed contracts ───────────────────────────────────────────────────

    MembershipNFT nft;                              // deployed on Base fork
    AllowlistReactiveContract rsc;                  // deployed locally (simulates Reactive Lasna)
    PermissionedCSMMHook hook;                      // deployed on Unichain fork
    PoolSwapTest swapRouter;                        // deployed on Unichain fork
    PoolModifyLiquidityTest modifyLiquidityRouter;  // deployed on Unichain fork
    PoolKey poolKey;
    Currency currency0;
    Currency currency1;
    bool zeroForOneIsUsdcIn; // true if USDC address < USDT0 address

    // ─── setUp ────────────────────────────────────────────────────────────────

    function setUp() public {
        // Create both mainnet forks upfront (does not yet switch the active fork)
        baseForkId     = vm.createFork("https://mainnet.base.org");
        unichainForkId = vm.createFork("https://mainnet.unichain.org");

        // ── Base fork: deploy MembershipNFT ──────────────────────────────────
        vm.selectFork(baseForkId);
        nft = new MembershipNFT(address(this));
        console2.log("[setup] MembershipNFT deployed on Base fork:", address(nft));

        // ── Unichain fork: deploy hook + pool ─────────────────────────────────
        vm.selectFork(unichainForkId);

        // Deploy test routers pointing to the real Unichain mainnet PoolManager
        swapRouter            = new PoolSwapTest(POOL_MANAGER);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(POOL_MANAGER);

        // Mine a CREATE2 salt that produces an address encoding the correct hook flags
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            FLAGS,
            type(PermissionedCSMMHook).creationCode,
            abi.encode(address(POOL_MANAGER), REACTIVE_CALLBACK_PROXY)
        );
        hook = new PermissionedCSMMHook{salt: salt}(POOL_MANAGER, REACTIVE_CALLBACK_PROXY);
        require(address(hook) == hookAddr, "hook address mismatch");
        hook.transferOwnership(owner);
        console2.log("[setup] PermissionedCSMMHook deployed on Unichain fork:", address(hook));

        // Deploy AllowlistReactiveContract (simulates Reactive Lasna deployment).
        // In the local test env the `vm` flag is true (no system contract code) so the
        // constructor skips subscribe() — exactly as it does on ReactVM.
        // membershipNFT is the Base address; hookContract is the Unichain address.
        rsc = new AllowlistReactiveContract(address(nft), address(hook));
        console2.log("[setup] AllowlistReactiveContract deployed (simulating Reactive Lasna):", address(rsc));

        // Sort USDC / USDT0 by address — lower address is currency0 in v4
        zeroForOneIsUsdcIn = USDC < USDT0;
        (address token0, address token1) = zeroForOneIsUsdcIn ? (USDC, USDT0) : (USDT0, USDC);
        currency0 = Currency.wrap(token0);
        currency1 = Currency.wrap(token1);

        // Fund this test contract with ample tokens via deal()
        deal(USDC,  address(this), 1_000_000_000e6);
        deal(USDT0, address(this), 1_000_000_000e6);

        // Approve routers
        IERC20(USDC).approve(address(swapRouter),             type(uint256).max);
        IERC20(USDT0).approve(address(swapRouter),            type(uint256).max);
        IERC20(USDC).approve(address(modifyLiquidityRouter),  type(uint256).max);
        IERC20(USDT0).approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize the USDC/USDT0 pool with the CSMM hook attached
        poolKey = PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            fee:         100,   // 0.01% — stablecoin-optimised
            tickSpacing: 1,     // tightest valid spacing
            hooks:       IHooks(address(hook))
        });
        POOL_MANAGER.initialize(poolKey, SQRT_PRICE_1_1);

        // Add full-range liquidity so PoolManager holds token balance for CSMM take() calls.
        // CSMM's beforeSwap calls poolManager.take(input, hook, amount) which requires
        // PoolManager to physically hold the tokens at call time.
        //
        // For USDC/USDT0 (6 decimal tokens) at full range, amount ≈ liquidityDelta in raw units.
        // 1e13 raw units = 10,000,000 USDC — 1000x more than our largest test swap (10,000e6 = 1e10).
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower:      -887272,
                tickUpper:       887272,
                liquidityDelta:  1e13,
                salt:            0
            }),
            ""
        );

        // Seed hook reserves — CSMM pays output tokens from its own balance
        IERC20(USDC).transfer(address(hook),  10_000_000e6);
        IERC20(USDT0).transfer(address(hook), 10_000_000e6);

        // Leave Unichain fork active at end of setUp — tests start here
    }

    // ─── Tests ────────────────────────────────────────────────────────────────

    /// @notice Step 1: Non-allowlisted addresses are rejected before any token movement.
    function test_nonAllowlistedSwapReverts() public {
        vm.selectFork(unichainForkId);
        _expectHookRevert(
            abi.encodeWithSelector(PermissionedCSMMHook.SwapperNotAllowlisted.selector, institution)
        );
        _swapUsdcIn(institution, 10_000e6);
        console2.log("[ok] Non-allowlisted swap correctly rejected");
    }

    /// @notice Steps 2-5: Full cross-chain lifecycle.
    ///         Base: mint NFT → RSC.react() emits Callback → proxy delivers to Unichain hook → 1:1 swap.
    function test_fullReactiveFlow() public {
        // Step 2 — Base: admin mints MembershipNFT to institution
        vm.selectFork(baseForkId);
        uint256 tokenId = nft.grantMembership(institution);
        assertEq(tokenId, 1);
        assertTrue(nft.isMember(institution));
        console2.log("[ok] MembershipNFT minted on Base fork, tokenId:", tokenId);

        // Step 3 — RSC: react() processes the Transfer log (simulates ReactVM execution).
        // Build the LogRecord that Reactive Network would deliver to the RSC.
        // This mirrors the ERC721 Transfer(from=address(0), to=institution, tokenId=1).
        vm.selectFork(unichainForkId);

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id:     rsc.BASE_CHAIN_ID(),                  // event originated on Base
            _contract:    address(nft),                          // MembershipNFT on Base
            topic_0:      TRANSFER_TOPIC,
            topic_1:      0,                                     // from == address(0) → mint
            topic_2:      uint256(uint160(institution)),         // to == institution
            topic_3:      tokenId,                               // tokenId
            data:         "",
            block_number: 1,
            op_code:      0,
            block_hash:   0,
            tx_hash:      0,
            log_index:    0
        });

        // Expect RSC to emit MintDetected then CallbackTriggered
        vm.expectEmit(true, false, false, true, address(rsc));
        emit AllowlistReactiveContract.MintDetected(institution, tokenId, 1);

        vm.expectEmit(true, true, false, false, address(rsc));
        emit AllowlistReactiveContract.CallbackTriggered(address(hook), 1);

        rsc.react(log);
        assertEq(rsc.callbackCount(), 1);
        console2.log("[ok] RSC.react() processed Base Transfer log, emitted Callback to Unichain");

        // Step 4 — Simulate Reactive Network delivering the callback to Unichain.
        // In production: Reactive Network detects the Callback event above and sends a
        // transaction from REACTIVE_CALLBACK_PROXY to hook.addToAllowlistReactive().
        vm.prank(REACTIVE_CALLBACK_PROXY);
        hook.addToAllowlistReactive(address(0), institution);
        assertTrue(hook.isAllowlisted(institution));
        console2.log("[ok] Reactive callback delivered: institution allowlisted on Unichain");

        // Set Gold tier so this base-flow test verifies 1:1 ratio (fee-testing is in separate tests)
        vm.prank(owner);
        hook.setInstitutionTier(institution, IStableGate.Tier.Gold);

        // Step 5 — Execute CSMM swap on Unichain — 10,000 USDC → USDT0
        uint256 usdt0Before = IERC20(USDT0).balanceOf(address(this));
        uint256 usdcBefore  = IERC20(USDC).balanceOf(address(this));
        _swapUsdcIn(institution, 10_000e6);

        assertEq(usdcBefore  - IERC20(USDC).balanceOf(address(this)),  10_000e6, "USDC spent");
        assertEq(IERC20(USDT0).balanceOf(address(this)) - usdt0Before, 10_000e6, "USDT0 received");
        console2.log("[ok] CSMM swap: 10,000 USDC -> 10,000 USDT0 (Gold tier, 1:1)");
    }

    /// @notice Step 6: Reverse direction — USDT0 → USDC still 1:1 for Gold tier.
    function test_reverseSwap() public {
        vm.selectFork(unichainForkId);
        vm.prank(REACTIVE_CALLBACK_PROXY);
        hook.addToAllowlistReactive(address(0), institution);
        vm.prank(owner);
        hook.setInstitutionTier(institution, IStableGate.Tier.Gold);

        uint256 usdcBefore  = IERC20(USDC).balanceOf(address(this));
        uint256 usdt0Before = IERC20(USDT0).balanceOf(address(this));
        bool reverseDir = !zeroForOneIsUsdcIn;

        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne:        reverseDir,
                amountSpecified:   -5_000e6,
                sqrtPriceLimitX96: reverseDir ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(institution)
        );

        assertEq(usdt0Before - IERC20(USDT0).balanceOf(address(this)), 5_000e6, "USDT0 spent");
        assertEq(IERC20(USDC).balanceOf(address(this)) - usdcBefore,   5_000e6, "USDC received");
        console2.log("[ok] Reverse CSMM swap: 5,000 USDT0 -> 5,000 USDC (Gold tier, 1:1)");
    }

    /// @notice Step 7: Revoking allowlist membership blocks further swaps.
    function test_revokeBlocksSwap() public {
        vm.selectFork(unichainForkId);

        // Allowlist institution via simulated Reactive callback
        vm.prank(REACTIVE_CALLBACK_PROXY);
        hook.addToAllowlistReactive(address(0), institution);

        // Owner revokes access
        vm.prank(owner);
        hook.removeFromAllowlist(institution);
        assertFalse(hook.isAllowlisted(institution));

        // Attempt swap — should revert with SwapperNotAllowlisted
        _expectHookRevert(
            abi.encodeWithSelector(PermissionedCSMMHook.SwapperNotAllowlisted.selector, institution)
        );
        _swapUsdcIn(institution, 1_000e6);
        console2.log("[ok] Revoked institution correctly blocked");
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /// @dev Set vm.expectRevert for a hook callback failure wrapping `innerError`.
    function _expectHookRevert(bytes memory innerError) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                innerError,
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
    }

    /// @dev Execute a USDC-in swap for `amount` USDC from the given institution.
    function _swapUsdcIn(address inst, uint256 amount) internal {
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne:        zeroForOneIsUsdcIn,
                amountSpecified:   -int256(amount),
                sqrtPriceLimitX96: zeroForOneIsUsdcIn ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(inst)
        );
    }

    // ─── Step 25: Tier 1 Feature Demonstrations ───────────────────────────────

    /// @notice Gold tier member swaps 10,000 USDC → exactly 10,000 USDT0 (zero fee).
    function test_goldTierZeroFeeSwap() public {
        vm.selectFork(unichainForkId);
        vm.prank(REACTIVE_CALLBACK_PROXY);
        hook.addToAllowlistReactive(address(0), institution);
        vm.prank(owner);
        hook.setInstitutionTier(institution, IStableGate.Tier.Gold);

        uint256 usdt0Before = IERC20(USDT0).balanceOf(address(this));
        _swapUsdcIn(institution, 10_000e6);
        assertEq(IERC20(USDT0).balanceOf(address(this)) - usdt0Before, 10_000e6, "Gold: zero fee");
        console2.log("[ok] Gold tier: 10,000 USDC -> 10,000 USDT0 (0 fee)");
    }

    /// @notice Bronze tier (default) member has 3 bps deducted from output.
    function test_bronzeTierFeeDeducted() public {
        vm.selectFork(unichainForkId);
        vm.prank(REACTIVE_CALLBACK_PROXY);
        hook.addToAllowlistReactive(address(0), institution);

        uint256 usdt0Before = IERC20(USDT0).balanceOf(address(this));
        _swapUsdcIn(institution, 10_000e6);
        uint256 received = IERC20(USDT0).balanceOf(address(this)) - usdt0Before;
        // 3 bps fee: 10_000e6 * 300 / 1_000_000 = 3_000_000 = 3e6
        assertEq(received, 10_000e6 - 3e6, "Bronze: 3 bps fee deducted");
        console2.log("[ok] Bronze tier: fee deducted, received:", received);
    }

    /// @notice Expired membership blocks the swap with MembershipExpired revert.
    function test_expiredMembershipBlocksSwap() public {
        vm.selectFork(unichainForkId);
        vm.prank(REACTIVE_CALLBACK_PROXY);
        hook.addToAllowlistReactive(address(0), institution);
        vm.prank(owner);
        hook.setInstitutionExpiry(institution, block.timestamp + 30 days);
        vm.warp(block.timestamp + 30 days + 1);

        _expectHookRevert(abi.encodeWithSelector(IStableGate.MembershipExpired.selector, institution));
        _swapUsdcIn(institution, 10_000e6);
        console2.log("[ok] Expired membership correctly blocked");
    }

    /// @notice Bronze tier daily limit: first 600k passes, second 600k hits the 1M cap.
    function test_dailyLimitEnforced() public {
        vm.selectFork(unichainForkId);
        vm.prank(REACTIVE_CALLBACK_PROXY);
        hook.addToAllowlistReactive(address(0), institution);
        // Bronze is the default tier — DAILY_LIMIT_BRONZE = 1_000_000e6

        _swapUsdcIn(institution, 600_000e6); // succeeds — 600k < 1M cap

        _expectHookRevert(abi.encodeWithSelector(
            IStableGate.DailyLimitExceeded.selector,
            institution,
            hook.DAILY_LIMIT_BRONZE(),
            uint256(600_000e6)
        ));
        _swapUsdcIn(institution, 600_000e6); // reverts — cumulative 1.2M > 1M cap
        console2.log("[ok] Bronze daily limit enforced: second 600k swap blocked at 1M cap");
    }
}
