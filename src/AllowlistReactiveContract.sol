// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";

/// @title AllowlistReactiveContract
/// @notice Reactive Smart Contract deployed on Reactive Lasna (Chain ID: 5318007).
///
/// Monitors events on Base Sepolia (Chain ID: 84532):
///   1. MembershipNFT Transfer events → auto-allowlist (mint), auto-revoke (burn/transfer)
///   2. TierUpdated events → forward tier metadata to hook via setInstitutionTier callback
///   3. ExpirySet events → forward expiry to hook via setInstitutionExpiry callback
///   4. LPMembershipNFT Transfer events → LP whitelist management
///
/// Callbacks target PermissionedCSMMHook on Unichain Sepolia (Chain ID: 1301).
/// react() branches on topic_0 and log._contract to determine which callback to emit.
contract AllowlistReactiveContract is AbstractReactive {
    // ─── Constants ───────────────────────────────────────────────────────────

    /// @notice Base Sepolia chain ID — where MembershipNFT is deployed (event source).
    uint256 public constant BASE_CHAIN_ID = 84532;

    /// @notice Unichain Sepolia chain ID — where PermissionedCSMMHook is deployed (callback target).
    uint256 public constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;

    /// @notice Reactive Lasna chain ID.
    uint256 public constant REACTIVE_CHAIN_ID = 5318007;

    /// @notice keccak256("Transfer(address,address,uint256)") — standard ERC721 Transfer topic.
    uint256 public constant TRANSFER_EVENT_TOPIC =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    /// @notice keccak256("TierUpdated(address,uint8)") — emitted by MembershipNFT on tier changes.
    uint256 public constant TIER_UPDATED_EVENT_TOPIC =
        0x15b3b7a9d17f2a7c5af2eb40b81427fddcf32c98aa6a9b6b5ebe00d42f6daa2b;

    /// @notice keccak256("ExpirySet(address,uint256)") — emitted by MembershipNFT on expiry writes.
    uint256 public constant EXPIRY_SET_EVENT_TOPIC =
        uint256(keccak256("ExpirySet(address,uint256)"));

    /// @notice Gas budget for the cross-chain callback transaction.
    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;

    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice MembershipNFT contract on Base Sepolia to monitor (trading credential).
    address public immutable membershipNFT;

    /// @notice LPMembershipNFT contract on Base Sepolia to monitor (LP credential).
    address public immutable lpMembershipNFT;

    /// @notice PermissionedCSMMHook on Unichain Sepolia — callback target.
    address public immutable hookContract;

    /// @notice Running count of callbacks triggered (useful for testing and monitoring).
    uint256 public callbackCount;

    // ─── Events ───────────────────────────────────────────────────────────────

    event MintDetected(address indexed recipient, uint256 tokenId, uint256 blockNumber);
    event BurnOrTransferDetected(address indexed from, uint256 tokenId, uint256 blockNumber);
    event TierUpdateDetected(address indexed institution, uint8 tier, uint256 blockNumber);
    event ExpirySetDetected(address indexed institution, uint256 expiry, uint256 blockNumber);
    event LPMintDetected(address indexed lp, uint256 tokenId, uint256 blockNumber);
    event LPBurnOrTransferDetected(address indexed lp, uint256 tokenId, uint256 blockNumber);
    event CallbackTriggered(address indexed target, uint256 indexed callbackNumber);

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _membershipNFT    MembershipNFT address on Base Sepolia.
    /// @param _lpMembershipNFT  LPMembershipNFT address on Base Sepolia.
    /// @param _hookContract     PermissionedCSMMHook address on Unichain Sepolia.
    constructor(address _membershipNFT, address _lpMembershipNFT, address _hookContract) payable {
        membershipNFT = _membershipNFT;
        lpMembershipNFT = _lpMembershipNFT;
        hookContract = _hookContract;

        if (!vm) {
            // Subscription 1: All Transfer events on MembershipNFT (mint + burn + transfer).
            service.subscribe(BASE_CHAIN_ID, membershipNFT, TRANSFER_EVENT_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            // Subscription 2: TierUpdated events on MembershipNFT.
            service.subscribe(BASE_CHAIN_ID, membershipNFT, TIER_UPDATED_EVENT_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            // Subscription 3: ExpirySet events on MembershipNFT.
            service.subscribe(BASE_CHAIN_ID, membershipNFT, EXPIRY_SET_EVENT_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            // Subscription 4: Transfer events on LPMembershipNFT (same topic, different contract).
            service.subscribe(BASE_CHAIN_ID, lpMembershipNFT, TRANSFER_EVENT_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
    }

    // ─── Core React Logic ─────────────────────────────────────────────────────

    /// @notice Called by ReactVM when a subscribed event matches.
    /// Branches on topic_0 and log._contract to determine which callback to emit.
    /// All callback payloads include address(0) as the first argument — Reactive Network
    /// replaces this with the RVM ID (deployer address) at delivery time.
    function react(LogRecord calldata log) external override vmOnly {
        if (log.topic_0 == TRANSFER_EVENT_TOPIC) {
            if (log._contract == membershipNFT) {
                _handleMembershipTransfer(log);
            } else if (log._contract == lpMembershipNFT) {
                _handleLPTransfer(log);
            }
        } else if (log.topic_0 == TIER_UPDATED_EVENT_TOPIC) {
            _handleTierUpdated(log);
        } else if (log.topic_0 == EXPIRY_SET_EVENT_TOPIC) {
            _handleExpirySet(log);
        }
    }

    // ─── Internal Handlers ────────────────────────────────────────────────────

    /// @dev Handles Transfer events from MembershipNFT (trading credential).
    function _handleMembershipTransfer(LogRecord calldata log) internal {
        address from = address(uint160(log.topic_1));
        address to = address(uint160(log.topic_2));
        uint256 tokenId = log.topic_3;

        callbackCount++;

        if (from == address(0)) {
            emit MintDetected(to, tokenId, log.block_number);
            emit CallbackTriggered(hookContract, callbackCount);

            bytes memory payload = abi.encodeWithSignature(
                "addToAllowlistReactive(address,address)",
                address(0),
                to
            );
            emit Callback(UNICHAIN_SEPOLIA_CHAIN_ID, hookContract, CALLBACK_GAS_LIMIT, payload);
        } else {
            emit BurnOrTransferDetected(from, tokenId, log.block_number);
            emit CallbackTriggered(hookContract, callbackCount);

            bytes memory payload = abi.encodeWithSignature(
                "removeFromAllowlistReactive(address,address)",
                address(0),
                from
            );
            emit Callback(UNICHAIN_SEPOLIA_CHAIN_ID, hookContract, CALLBACK_GAS_LIMIT, payload);
        }
    }

    /// @dev Handles Transfer events from LPMembershipNFT (LP credential).
    function _handleLPTransfer(LogRecord calldata log) internal {
        address from = address(uint160(log.topic_1));
        address to = address(uint160(log.topic_2));
        uint256 tokenId = log.topic_3;

        callbackCount++;

        if (from == address(0)) {
            emit LPMintDetected(to, tokenId, log.block_number);
            emit CallbackTriggered(hookContract, callbackCount);

            bytes memory payload = abi.encodeWithSignature(
                "addToLPWhitelist(address,address)",
                address(0),
                to
            );
            emit Callback(UNICHAIN_SEPOLIA_CHAIN_ID, hookContract, CALLBACK_GAS_LIMIT, payload);
        } else {
            emit LPBurnOrTransferDetected(from, tokenId, log.block_number);
            emit CallbackTriggered(hookContract, callbackCount);

            bytes memory payload = abi.encodeWithSignature(
                "removeFromLPWhitelist(address,address)",
                address(0),
                from
            );
            emit Callback(UNICHAIN_SEPOLIA_CHAIN_ID, hookContract, CALLBACK_GAS_LIMIT, payload);
        }
    }

    function _handleTierUpdated(LogRecord calldata log) internal {
        address institution = address(uint160(log.topic_1));
        uint8 tier = uint8(log.topic_2);

        callbackCount++;

        emit TierUpdateDetected(institution, tier, log.block_number);
        emit CallbackTriggered(hookContract, callbackCount);

        bytes memory payload = abi.encodeWithSignature(
            "setInstitutionTier(address,address,uint8)",
            address(0),
            institution,
            tier
        );
        emit Callback(UNICHAIN_SEPOLIA_CHAIN_ID, hookContract, CALLBACK_GAS_LIMIT, payload);
    }

    function _handleExpirySet(LogRecord calldata log) internal {
        address institution = address(uint160(log.topic_1));
        uint256 expiry = abi.decode(log.data, (uint256));

        callbackCount++;

        emit ExpirySetDetected(institution, expiry, log.block_number);
        emit CallbackTriggered(hookContract, callbackCount);

        bytes memory payload = abi.encodeWithSignature(
            "setInstitutionExpiry(address,address,uint256)",
            address(0),
            institution,
            expiry
        );
        emit Callback(UNICHAIN_SEPOLIA_CHAIN_ID, hookContract, CALLBACK_GAS_LIMIT, payload);
    }

    // ─── Admin (RNK only) ─────────────────────────────────────────────────────

    /// @notice Pause monitoring by unsubscribing from all Base events.
    function pause() external rnOnly {
        service.unsubscribe(BASE_CHAIN_ID, membershipNFT, TRANSFER_EVENT_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        service.unsubscribe(BASE_CHAIN_ID, membershipNFT, TIER_UPDATED_EVENT_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        service.unsubscribe(BASE_CHAIN_ID, membershipNFT, EXPIRY_SET_EVENT_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        service.unsubscribe(BASE_CHAIN_ID, lpMembershipNFT, TRANSFER_EVENT_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @notice Resume monitoring by re-subscribing to all Base events.
    function resume() external rnOnly {
        service.subscribe(BASE_CHAIN_ID, membershipNFT, TRANSFER_EVENT_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        service.subscribe(BASE_CHAIN_ID, membershipNFT, TIER_UPDATED_EVENT_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        service.subscribe(BASE_CHAIN_ID, membershipNFT, EXPIRY_SET_EVENT_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        service.subscribe(BASE_CHAIN_ID, lpMembershipNFT, TRANSFER_EVENT_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }
}
