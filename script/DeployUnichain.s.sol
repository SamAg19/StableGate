// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "v4-hooks-public/utils/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PermissionedCSMMHook} from "../src/PermissionedCSMMHook.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockUSDT0} from "../src/mocks/MockUSDT0.sol";

/// @notice Deploy MockUSDC, MockUSDT0, PermissionedCSMMHook to Unichain Sepolia.
///         Initializes the USDC/USDT0 pool with the hook attached and seeds it with liquidity.
///
/// Usage:
///   source .env
///   forge script script/DeployUnichain.s.sol \
///     --rpc-url $UNICHAIN_SEPOLIA_RPC \
///     --broadcast \
///     --private-key $DEPLOYER_PRIVATE_KEY \
///     -vvv
contract DeployUnichain is Script {
    // Unichain Sepolia PoolManager address
    IPoolManager constant POOL_MANAGER = IPoolManager(0xC81462Fec8B23319F288047f8A03A57682a35C1A);

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    /// @dev 7200 blocks ≈ 24 hours on Unichain (~0.5 s block time).
    uint256 constant BLOCKS_PER_DAY = 7200;

    /// @dev sqrtPriceX96 for price 1:1 (both tokens are 6 decimals)
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    /// @dev Seed amounts for the pool
    uint256 constant OPERATOR_MINT    = 500_000e6;
    uint256 constant INSTITUTION_MINT = 100_000e6;
    uint256 constant SEED_LIQUIDITY   = 200_000e6; // liquidity delta for initial LP position
    uint256 constant HOOK_RESERVE     = 200_000e6; // tokens seeded directly into hook

    function run() external {
        address deployer          = vm.envAddress("DEPLOYER_ADDRESS");
        address institutionBronze = vm.envAddress("INSTITUTION_BRONZE");
        address institutionSilver = vm.envAddress("INSTITUTION_SILVER");
        address institutionGold   = vm.envAddress("INSTITUTION_GOLD");

        // ── Step 1: Mine hook salt before broadcast ─────────────────────────
        (address hookAddr, bytes32 salt) = HookMiner.find(
            deployer,
            FLAGS,
            type(PermissionedCSMMHook).creationCode,
            abi.encode(address(POOL_MANAGER), deployer)
        );

        vm.startBroadcast();

        // ── Step 2: Deploy mock tokens and mint ─────────────────────────────
        MockUSDC  mockUSDC  = new MockUSDC();
        MockUSDT0 mockUSDT0 = new MockUSDT0();

        // Mint to operator — for seeding pool liquidity and hook reserves
        mockUSDC.mint(deployer,      OPERATOR_MINT);
        mockUSDT0.mint(deployer,     OPERATOR_MINT);

        // Mint to each institution — for demo swaps and LP
        mockUSDC.mint(institutionBronze,  INSTITUTION_MINT);
        mockUSDT0.mint(institutionBronze, INSTITUTION_MINT);
        mockUSDC.mint(institutionSilver,  INSTITUTION_MINT);
        mockUSDT0.mint(institutionSilver, INSTITUTION_MINT);
        mockUSDC.mint(institutionGold,    INSTITUTION_MINT);
        mockUSDT0.mint(institutionGold,   INSTITUTION_MINT);

        // ── Step 3: Deploy hook ─────────────────────────────────────────────
        PermissionedCSMMHook hook = new PermissionedCSMMHook{salt: salt}(
            POOL_MANAGER,
            deployer // feeRecipient defaults to deployer
        );
        require(address(hook) == hookAddr, "hook address mismatch");
        hook.setBlocksPerDay(BLOCKS_PER_DAY);

        // ── Step 4: Whitelist deployer as LP (needed to seed liquidity) ─────
        hook.addToLPWhitelist(deployer, deployer);

        // ── Step 5: Deploy liquidity router helper ──────────────────────────
        // PoolModifyLiquidityTest is a v4-core test utility that wraps the
        // unlock → modifyLiquidity pattern. Deployed on-chain for testnet seeding.
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(POOL_MANAGER);

        // Also whitelist the liquidity router so beforeAddLiquidity passes
        // when hookData is empty (sender fallback path)
        hook.addToLPWhitelist(deployer, address(liquidityRouter));

        // ── Step 6: Sort tokens and initialize pool ─────────────────────────
        (address token0, address token1) = address(mockUSDC) < address(mockUSDT0)
            ? (address(mockUSDC), address(mockUSDT0))
            : (address(mockUSDT0), address(mockUSDC));

        PoolKey memory poolKey = PoolKey({
            currency0:   Currency.wrap(token0),
            currency1:   Currency.wrap(token1),
            fee:         100,   // 0.01% — stablecoin-optimised
            tickSpacing: 1,     // tightest valid spacing
            hooks:       IHooks(address(hook))
        });

        POOL_MANAGER.initialize(poolKey, SQRT_PRICE_1_1);

        // ── Step 7: Approve router and seed full-range liquidity ────────────
        IERC20(token0).approve(address(liquidityRouter), type(uint256).max);
        IERC20(token1).approve(address(liquidityRouter), type(uint256).max);

        // Add full-range liquidity. For 6-decimal tokens at full range,
        // liquidityDelta ≈ raw token units deposited per side.
        liquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower:      -887272,
                tickUpper:       887272,
                liquidityDelta:  int256(SEED_LIQUIDITY),
                salt:            0
            }),
            "" // empty hookData — sender (liquidityRouter) is LP-whitelisted
        );

        // ── Step 8: Seed hook reserves ──────────────────────────────────────
        // CSMM pays output tokens directly from the hook's balance.
        IERC20(token0).transfer(address(hook),  HOOK_RESERVE);
        IERC20(token1).transfer(address(hook),  HOOK_RESERVE);

        vm.stopBroadcast();

        // ── Logging ─────────────────────────────────────────────────────────
        console2.log("=== Unichain Sepolia Deployment ===");
        console2.log("");
        console2.log("Mock tokens:");
        console2.log("  MockUSDC:              ", address(mockUSDC));
        console2.log("  MockUSDT0:             ", address(mockUSDT0));
        console2.log("  Operator USDC balance: ", IERC20(address(mockUSDC)).balanceOf(deployer));
        console2.log("  Bronze inst USDC:      ", IERC20(address(mockUSDC)).balanceOf(institutionBronze));
        console2.log("  Silver inst USDC:      ", IERC20(address(mockUSDC)).balanceOf(institutionSilver));
        console2.log("  Gold inst USDC:        ", IERC20(address(mockUSDC)).balanceOf(institutionGold));
        console2.log("");
        console2.log("Hook:");
        console2.log("  PermissionedCSMMHook:  ", address(hook));
        console2.log("  PoolManager:           ", address(POOL_MANAGER));
        console2.log("  CallbackProxy:         ", hook.CALLBACK_PROXY());
        console2.log("  Owner (deployer):      ", deployer);
        console2.log("  blocksPerDay:          ", hook.blocksPerDay());
        console2.log("");
        console2.log("Pool:");
        console2.log("  currency0:             ", token0);
        console2.log("  currency1:             ", token1);
        console2.log("  fee:                    100 (0.01%)");
        console2.log("  tickSpacing:            1");
        console2.log("  Seed liquidity:        ", SEED_LIQUIDITY);
        console2.log("  Hook USDC reserve:     ", IERC20(token0).balanceOf(address(hook)));
        console2.log("  Hook USDT0 reserve:    ", IERC20(token1).balanceOf(address(hook)));
        console2.log("");
        console2.log("Liquidity router (testnet helper):");
        console2.log("  PoolModifyLiquidityTest:", address(liquidityRouter));
        console2.log("");
        console2.log("Set in .env:");
        console2.log("  USDC_ADDRESS=",   address(mockUSDC));
        console2.log("  USDT0_ADDRESS=",  address(mockUSDT0));
        console2.log("  HOOK_CONTRACT=",  address(hook));
    }
}
