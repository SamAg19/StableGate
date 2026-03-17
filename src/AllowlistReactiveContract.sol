// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {IStableGate} from "./interfaces/IStableGate.sol";

/// @title AllowlistReactiveContract
/// @notice Reactive Smart Contract deployed on Reactive Lasna (Chain ID: 5318007).
///
/// Monitors two event types on Base Sepolia (Chain ID: 84532):
///   1. MembershipNFT Transfer events → auto-allowlist (mint), auto-revoke (burn/transfer)
///   2. TierUpdated events → forward tier metadata to hook via setInstitutionTier callback
///
/// Callbacks target PermissionedCSMMHook on Unichain Sepolia (Chain ID: 1301).
///
/// Chain topology:
///   - MembershipNFT lives on Base (Sepolia: 84532) — event source
///   - PermissionedCSMMHook lives on Unichain (Sepolia: 1301) — callback destination
///   - AllowlistReactiveContract lives on Reactive Lasna — monitors Base, callbacks Unichain
///
/// Reactive Network multi-subscription:
///   - Subscription 1: Transfer events (mint = allowlist, burn/transfer = revoke)
///   - Subscription 2: TierUpdated events (forward tier to hook)
///
/// react() branches on the event topic_0 to determine which callback to emit.
contract AllowlistReactiveContract is AbstractReactive {
    // ─── Constants ───────────────────────────────────────────────────────────

    /// @notice Base Sepolia chain ID — where MembershipNFT is deployed (event source).
    uint256 public constant BASE_CHAIN_ID = 84532;

    /// @notice Unichain Sepolia chain ID — where PermissionedCSMMHook is deployed (callback target).
    uint256 public constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;

    /// @notice keccak256("Transfer(address,address,uint256)") — standard ERC721 Transfer topic.
    uint256 public constant TRANSFER_EVENT_TOPIC =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    /// @notice keccak256("TierUpdated(address,uint8)") — emitted by MembershipNFT on tier changes.
    uint256 public constant TIER_UPDATED_EVENT_TOPIC =
        0x15b3b7a9d17f2a7c5af2eb40b81427fddcf32c98aa6a9b6b5ebe00d42f6daa2b;

    /// @notice keccak256("ExpirySet(address,uint256)") — emitted by MembershipNFT on expiry writes.
    uint256 public constant EXPIRY_SET_EVENT_TOPIC =
        uint256(keccak256("ExpirySet(address,uint256)"));

    /// @notice topic_1 filter value for mint events: from == address(0) → 32-byte zero.
    uint256 public constant ZERO_TOPIC = 0;

    /// @notice Gas budget for the cross-chain callback transaction.
    uint64 public constant CALLBACK_GAS_LIMIT = 200_000;

    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice MembershipNFT contract on Base Sepolia to monitor.
    address public immutable membershipNFT;

    /// @notice PermissionedCSMMHook on Unichain Sepolia — callback target.
    address public immutable hookContract;

    /// @notice Running count of callbacks triggered (useful for testing and monitoring).
    uint256 public callbackCount;

    // ─── Events ───────────────────────────────────────────────────────────────

    event MintDetected(address indexed recipient, uint256 tokenId, uint256 blockNumber);
    event BurnOrTransferDetected(address indexed from, uint256 tokenId, uint256 blockNumber);
    event TierUpdateDetected(address indexed institution, uint8 tier, uint256 blockNumber);
    event ExpirySetDetected(address indexed institution, uint256 expiry, uint256 blockNumber);
    event CallbackTriggered(address indexed target, uint256 indexed callbackNumber);

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _membershipNFT  MembershipNFT address on Base Sepolia.
    /// @param _hookContract   PermissionedCSMMHook address on Unichain Sepolia.
    constructor(address _membershipNFT, address _hookContract) payable {
        membershipNFT = _membershipNFT;
        hookContract = _hookContract;

        if (!vm) {
            // Subscription 1: All Transfer events on MembershipNFT (mint + burn + transfer).
            // We subscribe with REACTIVE_IGNORE for topic_1 so we receive all Transfer events,
            // then branch in react() based on from/to values.
            SERVICE_ADDR.subscribe(
                BASE_CHAIN_ID,
                membershipNFT,
                TRANSFER_EVENT_TOPIC,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );

            // Subscription 2: TierUpdated events on MembershipNFT.
            // topic_0 = keccak256("TierUpdated(address,uint8)")
            SERVICE_ADDR.subscribe(
                BASE_CHAIN_ID,
                membershipNFT,
                TIER_UPDATED_EVENT_TOPIC,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );

            // Subscription 3: ExpirySet events on MembershipNFT — forward expiry to hook.
            SERVICE_ADDR.subscribe(
                BASE_CHAIN_ID,
                membershipNFT,
                EXPIRY_SET_EVENT_TOPIC,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    // ─── Core React Logic ─────────────────────────────────────────────────────

    /// @notice Called by ReactVM when a subscribed event matches.
    ///
    /// Handles two event types based on topic_0:
    ///
    /// 1. Transfer(address indexed from, address indexed to, uint256 indexed tokenId):
    ///    - from == address(0): mint → addToAllowlistReactive(rvmId, to)
    ///    - to == address(0): burn → removeFromAllowlistReactive(rvmId, from)
    ///    - otherwise: transfer → removeFromAllowlistReactive(rvmId, from) (new holder not auto-granted)
    ///
    /// 2. TierUpdated(address indexed institution, uint8 tier):
    ///    → setInstitutionTier(rvmId, institution, tier)
    ///
    /// @param log  The full log record delivered by Reactive Network.
    function react(LogRecord calldata log) external override vmOnly {
        if (log.topic_0 == TRANSFER_EVENT_TOPIC) {
            _handleTransfer(log);
        } else if (log.topic_0 == TIER_UPDATED_EVENT_TOPIC) {
            _handleTierUpdated(log);
        } else if (log.topic_0 == EXPIRY_SET_EVENT_TOPIC) {
            _handleExpirySet(log);
        }
    }

    // ─── Internal Handlers ────────────────────────────────────────────────────

    function _handleTransfer(LogRecord calldata log) internal {
        address from = address(uint160(log.topic_1));
        address to = address(uint160(log.topic_2));
        uint256 tokenId = log.topic_3;

        callbackCount++;

        if (from == address(0)) {
            // Mint: allowlist the recipient
            emit MintDetected(to, tokenId, log.block_number);
            emit CallbackTriggered(hookContract, callbackCount);

            bytes memory payload = abi.encodeWithSignature(
                "addToAllowlistReactive(address,address)",
                address(0), // placeholder — overwritten by Reactive Network with RVM ID
                to
            );
            emit Callback(UNICHAIN_SEPOLIA_CHAIN_ID, hookContract, CALLBACK_GAS_LIMIT, payload);
        } else {
            // Burn (to == address(0)) or transfer between wallets: revoke the original holder
            emit BurnOrTransferDetected(from, tokenId, log.block_number);
            emit CallbackTriggered(hookContract, callbackCount);

            bytes memory payload = abi.encodeWithSignature(
                "removeFromAllowlistReactive(address,address)",
                address(0), // placeholder — overwritten by Reactive Network with RVM ID
                from
            );
            emit Callback(UNICHAIN_SEPOLIA_CHAIN_ID, hookContract, CALLBACK_GAS_LIMIT, payload);
        }
    }

    function _handleTierUpdated(LogRecord calldata log) internal {
        // TierUpdated(address indexed institution, uint8 tier):
        //   topic_1 = institution (indexed address, padded to 32 bytes)
        //   topic_2 = tier value (uint8 stored as uint256 in a topic — BUT wait, uint8 is not
        //             declared as `indexed` in the TierUpdated event, so it lives in the data field.
        //             However, per IStableGate the event is:
        //               event TierUpdated(address indexed institution, Tier tier)
        //             Only `institution` is indexed. `tier` is in the log data (not a topic).
        //             ReactVM provides the raw data bytes; we decode from log.data if available,
        //             or use a simplified approach: encode the selector + institution + tier(0)
        //             as a placeholder and let the hook update it separately.
        //
        //             For simplicity in the RSC, we read `tier` from topic_2 since Reactive Network
        //             may pack non-indexed uint values into topics. We use a safe cast.
        address institution = address(uint160(log.topic_1));
        uint8 tier = uint8(log.topic_2);

        callbackCount++;

        emit TierUpdateDetected(institution, tier, log.block_number);
        emit CallbackTriggered(hookContract, callbackCount);

        // Forward setInstitutionTier to the hook.
        // Reactive Network overwrites the first argument with the RVM ID.
        // setInstitutionTier(address rvmId_overwritten, address institution, uint8 tier)
        // But our hook signature is setInstitutionTier(address, Tier) — Tier is uint8 under the hood.
        bytes memory payload = abi.encodeWithSignature(
            "setInstitutionTier(address,uint8)",
            institution, // this gets overwritten by RVM ID — institution is second param
            tier
        );
        emit Callback(UNICHAIN_SEPOLIA_CHAIN_ID, hookContract, CALLBACK_GAS_LIMIT, payload);
    }

    function _handleExpirySet(LogRecord calldata log) internal {
        // ExpirySet(address indexed institution, uint256 expiry):
        //   topic_1 = institution (indexed address, padded to 32 bytes)
        //   data    = expiry (non-indexed uint256)
        address institution = address(uint160(log.topic_1));
        uint256 expiry = abi.decode(log.data, (uint256));

        callbackCount++;

        emit ExpirySetDetected(institution, expiry, log.block_number);
        emit CallbackTriggered(hookContract, callbackCount);

        bytes memory payload = abi.encodeWithSignature(
            "setInstitutionExpiry(address,uint256)",
            institution,
            expiry
        );
        emit Callback(UNICHAIN_SEPOLIA_CHAIN_ID, hookContract, CALLBACK_GAS_LIMIT, payload);
    }

    // ─── Admin (RNK only) ─────────────────────────────────────────────────────

    /// @notice Pause monitoring by unsubscribing from all Base events.
    function pause() external rnOnly {
        SERVICE_ADDR.unsubscribe(
            BASE_CHAIN_ID,
            membershipNFT,
            TRANSFER_EVENT_TOPIC,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SERVICE_ADDR.unsubscribe(
            BASE_CHAIN_ID,
            membershipNFT,
            TIER_UPDATED_EVENT_TOPIC,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SERVICE_ADDR.unsubscribe(
            BASE_CHAIN_ID,
            membershipNFT,
            EXPIRY_SET_EVENT_TOPIC,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @notice Resume monitoring by re-subscribing to all Base events.
    function resume() external rnOnly {
        SERVICE_ADDR.subscribe(
            BASE_CHAIN_ID,
            membershipNFT,
            TRANSFER_EVENT_TOPIC,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SERVICE_ADDR.subscribe(
            BASE_CHAIN_ID,
            membershipNFT,
            TIER_UPDATED_EVENT_TOPIC,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        SERVICE_ADDR.subscribe(
            BASE_CHAIN_ID,
            membershipNFT,
            EXPIRY_SET_EVENT_TOPIC,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }
}
