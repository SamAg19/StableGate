// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "v4-hooks-public/utils/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PermissionedCSMMHook} from "../src/PermissionedCSMMHook.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockUSDT0} from "../src/mocks/MockUSDT0.sol";

/// @notice Deploy MockUSDC, MockUSDT0, PermissionedCSMMHook to Unichain Sepolia.
///         Initializes the USDC/USDT0 pool with the hook attached.
///         Liquidity is added by institutions after they receive LP credentials via Reactive Network.
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
    IPoolManager constant POOL_MANAGER = IPoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    /// @dev 7200 blocks ≈ 24 hours on Unichain (~0.5 s block time).
    uint256 constant BLOCKS_PER_DAY = 7200;

    /// @dev sqrtPriceX96 for price 1:1 (both tokens are 6 decimals)
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    /// @dev Mint amounts
    uint256 constant OPERATOR_MINT    = 500_000e6;
    uint256 constant INSTITUTION_MINT = 100_000e6;
    uint256 constant LP_MINT          = 500_000e6; // LP institution needs more for seeding pool

    function run() external {
        address deployer          = vm.envAddress("DEPLOYER_ADDRESS");
        address institutionBronze = vm.envAddress("INSTITUTION_BRONZE");
        address institutionSilver = vm.envAddress("INSTITUTION_SILVER");
        address institutionGold   = vm.envAddress("INSTITUTION_GOLD");
        address institutionLP     = vm.envAddress("INSTITUTION_LP");

        // ── Step 1: Mine hook salt before broadcast ─────────────────────────
        // When using forge script --broadcast, CREATE2 goes through the
        // deterministic deployer at 0x4e59b44847b379578588920cA78FbF26c0B4956C.
        // HookMiner must use that address (not the EOA deployer) as the origin.
        address create2Factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        (address hookAddr, bytes32 salt) = HookMiner.find(
            create2Factory,
            FLAGS,
            type(PermissionedCSMMHook).creationCode,
            abi.encode(address(POOL_MANAGER), deployer, deployer)
        );

        vm.startBroadcast();

        // ── Step 2: Deploy mock tokens and mint ─────────────────────────────
        MockUSDC  mockUSDC  = new MockUSDC();
        MockUSDT0 mockUSDT0 = new MockUSDT0();

        // Mint to operator
        mockUSDC.mint(deployer,      OPERATOR_MINT);
        mockUSDT0.mint(deployer,     OPERATOR_MINT);

        // Mint to each institution — for demo swaps and LP
        mockUSDC.mint(institutionBronze,  INSTITUTION_MINT);
        mockUSDT0.mint(institutionBronze, INSTITUTION_MINT);
        mockUSDC.mint(institutionSilver,  INSTITUTION_MINT);
        mockUSDT0.mint(institutionSilver, INSTITUTION_MINT);
        mockUSDC.mint(institutionGold,    INSTITUTION_MINT);
        mockUSDT0.mint(institutionGold,   INSTITUTION_MINT);

        // Mint to LP institution — extra allocation for seeding pool liquidity
        mockUSDC.mint(institutionLP,      LP_MINT);
        mockUSDT0.mint(institutionLP,     LP_MINT);

        // ── Step 3: Deploy hook ─────────────────────────────────────────────
        PermissionedCSMMHook hook = new PermissionedCSMMHook{salt: salt}(
            POOL_MANAGER,
            deployer, // owner
            deployer  // feeRecipient defaults to deployer
        );
        require(address(hook) == hookAddr, "hook address mismatch");
        hook.setBlocksPerDay(BLOCKS_PER_DAY);

        // ── Step 4: Sort tokens and initialize pool ─────────────────────────
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

        // ── Step 5: Seed hook reserves ──────────────────────────────────────
        // CSMM pays output tokens directly from the hook's balance.
        // Without reserves, swaps revert with ERC20InsufficientBalance.
        // Mint directly to hook since MockUSDC/MockUSDT0 have public mint.
        uint256 hookReserve = 200_000e6;
        mockUSDC.mint(address(hook),  hookReserve);
        mockUSDT0.mint(address(hook), hookReserve);

        // ── Step 6: Fund hook on callback proxy ─────────────────────────────
        // The Unichain callback proxy charges the hook for gas on every callback.
        // If the hook has no reserves, the proxy blacklists it and blocks all
        // future callbacks. Deposit ETH via depositTo(hook) to pre-fund reserves.
        address callbackProxy = hook.CALLBACK_PROXY();
        (bool deposited,) = callbackProxy.call{value: 0.005 ether}(
            abi.encodeWithSignature("depositTo(address)", address(hook))
        );
        require(deposited, "Failed to fund hook on callback proxy");

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
        console2.log("  LP inst USDC:          ", IERC20(address(mockUSDC)).balanceOf(institutionLP));
        console2.log("");
        console2.log("Hook:");
        console2.log("  PermissionedCSMMHook:  ", address(hook));
        console2.log("  PoolManager:           ", address(POOL_MANAGER));
        console2.log("  CallbackProxy:         ", hook.CALLBACK_PROXY());
        console2.log("  Owner (deployer):      ", deployer);
        console2.log("  blocksPerDay:          ", hook.blocksPerDay());
        console2.log("  Callback proxy funded:  0.005 ETH deposited for hook gas reserves");
        console2.log("");
        console2.log("Pool:");
        console2.log("  currency0:             ", token0);
        console2.log("  currency1:             ", token1);
        console2.log("  fee:                    100 (0.01%)");
        console2.log("  tickSpacing:            1");
        console2.log("  Hook reserves:          seeded by LP institution post-deploy");
        console2.log("");
        console2.log("Set in .env:");
        console2.log("  USDC_ADDRESS=",   address(mockUSDC));
        console2.log("  USDT0_ADDRESS=",  address(mockUSDT0));
        console2.log("  HOOK_CONTRACT=",  address(hook));
    }
}
