// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-hooks-public/utils/HookMiner.sol";
import {PermissionedCSMMHook} from "../src/PermissionedCSMMHook.sol";
import {IStableGate} from "../src/interfaces/IStableGate.sol";

/// @notice Deploy PermissionedCSMMHook to Unichain Sepolia via CREATE2.
///         The hook address must encode the required permission flags in its lower bits.
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

    // Reactive Network Callback Proxy on Unichain Sepolia
    address constant REACTIVE_CALLBACK_PROXY = 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4;

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    /// @dev 7200 blocks ≈ 24 hours on Unichain (~0.5 s block time).
    uint256 constant BLOCKS_PER_DAY = 7200;

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        // Mine a CREATE2 salt that produces an address with the correct flag bits
        (address hookAddr, bytes32 salt) = HookMiner.find(
            deployer,
            FLAGS,
            type(PermissionedCSMMHook).creationCode,
            abi.encode(address(POOL_MANAGER), deployer)
        );

        vm.startBroadcast();

        PermissionedCSMMHook hook = new PermissionedCSMMHook{salt: salt}(
            POOL_MANAGER,
            deployer // feeRecipient defaults to deployer
        );
        require(address(hook) == hookAddr, "hook address mismatch");

        // Post-deploy configuration: block window for daily volume reset
        hook.setBlocksPerDay(BLOCKS_PER_DAY);

        vm.stopBroadcast();

        console2.log("=== Unichain Sepolia Deployment ===");
        console2.log("PermissionedCSMMHook:", address(hook));
        console2.log("PoolManager:         ", address(POOL_MANAGER));
        console2.log("ReactiveProxy:       ", REACTIVE_CALLBACK_PROXY);
        console2.log("Owner (deployer):    ", deployer);
        console2.log("");
        console2.log("Fee schedule:");
        console2.log("  Gold   tier: 0 bps  (FEE_GOLD   =", hook.FEE_GOLD(), ")");
        console2.log("  Silver tier: 1 bps  (FEE_SILVER =", hook.FEE_SILVER(), ")");
        console2.log("  Bronze tier: 3 bps  (FEE_BRONZE =", hook.FEE_BRONZE(), ")");
        console2.log("");
        console2.log("Daily volume config (tier-derived):");
        console2.log("  Gold  cap: 0 (unlimited)");
        console2.log("  Silver cap:", hook.DAILY_LIMIT_SILVER(), "USDC (6-dec)");
        console2.log("  Bronze cap:", hook.DAILY_LIMIT_BRONZE(), "USDC (6-dec)");
        console2.log("  blocksPerDay:", hook.blocksPerDay());
        console2.log("");
        console2.log("Set in .env:");
        console2.log("  HOOK_CONTRACT=", address(hook));
    }
}
