// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";

/// @title AllowlistReactiveContract
/// @notice Reactive Smart Contract deployed on Reactive Lasna (Chain ID: 5318007).
///
/// Monitors MembershipNFT Transfer events on Unichain Sepolia (Chain ID: 1301).
/// When a mint is detected (from == address(0)), emits a Callback that triggers
/// PermissionedCSMMHook.addToAllowlistReactive(rvmId, recipient) on Unichain Sepolia
/// via the Reactive Network Callback Proxy.
///
/// Dual execution model:
///   - On Reactive Network (RNK): constructor subscribes to events, admin functions work
///   - In ReactVM: react() executes when matching events arrive, emits Callback
///
/// The Reactive Network overwrites the FIRST argument of every callback payload with the
/// deployer's RVM ID. Since addToAllowlist(address) only takes one argument, we use a
/// two-argument variant `addToAllowlistReactive(address rvmId, address account)` on the
/// hook, where `address(0)` is the placeholder that gets overwritten with the RVM ID.
contract AllowlistReactiveContract is AbstractReactive {
    // ─── Constants ───────────────────────────────────────────────────────────

    /// @notice Unichain Sepolia chain ID — source of MembershipNFT events and hook callback target.
    uint256 public constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;

    /// @notice keccak256("Transfer(address,address,uint256)") — standard ERC721 Transfer topic.
    uint256 public constant TRANSFER_EVENT_TOPIC =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    /// @notice topic_1 filter value for mint events: from == address(0) → 32-byte zero.
    uint256 public constant ZERO_TOPIC = 0;

    /// @notice Gas budget for the cross-chain callback transaction.
    uint64 public constant CALLBACK_GAS_LIMIT = 200_000;

    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice MembershipNFT contract on Unichain Sepolia to monitor.
    address public immutable membershipNFT;

    /// @notice PermissionedCSMMHook on Unichain Sepolia — callback target.
    address public immutable hookContract;

    /// @notice Running count of callbacks triggered (useful for testing and monitoring).
    uint256 public callbackCount;

    // ─── Events ───────────────────────────────────────────────────────────────

    event MintDetected(address indexed recipient, uint256 tokenId, uint256 blockNumber);
    event CallbackTriggered(address indexed recipient, uint256 indexed callbackNumber);

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _membershipNFT  MembershipNFT address on Unichain Sepolia.
    /// @param _hookContract   PermissionedCSMMHook address on Unichain Sepolia.
    ///
    /// The constructor runs in both environments (RNK and ReactVM).
    /// The `if (!vm)` guard ensures subscribe() is only called on RNK
    /// where the system contract exists. In ReactVM there is no system contract.
    constructor(address _membershipNFT, address _hookContract) payable {
        membershipNFT = _membershipNFT;
        hookContract = _hookContract;

        if (!vm) {
            // Subscribe to Transfer events on MembershipNFT where from == address(0)
            // (i.e., mint events only — not transfers between existing holders).
            //
            // topic_0 = Transfer(address,address,uint256) event signature
            // topic_1 = address(0) = mints only (the `from` field)
            // topic_2 = REACTIVE_IGNORE = any recipient address
            // topic_3 = REACTIVE_IGNORE = any tokenId
            SERVICE_ADDR.subscribe(
                UNICHAIN_SEPOLIA_CHAIN_ID,
                membershipNFT,
                TRANSFER_EVENT_TOPIC,
                ZERO_TOPIC,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    // ─── Core React Logic ─────────────────────────────────────────────────────

    /// @notice Called by ReactVM when a subscribed event matches.
    ///
    /// Log field mapping for ERC721 Transfer(address indexed from, address indexed to, uint256 indexed tokenId):
    ///   log.topic_0 = keccak256("Transfer(address,address,uint256)")  [event signature]
    ///   log.topic_1 = from address (padded to 32 bytes)               [== address(0) for mints]
    ///   log.topic_2 = to address (padded to 32 bytes)                 [recipient]
    ///   log.topic_3 = tokenId (uint256)
    ///
    /// @param log  The full log record delivered by Reactive Network.
    function react(LogRecord calldata log) external override vmOnly {
        // Extract recipient from topic_2 (cast uint256 → uint160 → address strips padding)
        address recipient = address(uint160(log.topic_2));
        uint256 tokenId = log.topic_3;

        callbackCount++;

        emit MintDetected(recipient, tokenId, log.block_number);
        emit CallbackTriggered(recipient, callbackCount);

        // Build callback payload for PermissionedCSMMHook.addToAllowlistReactive(address,address).
        //
        // Reactive Network OVERWRITES the first 32 bytes of the payload with the deployer's
        // RVM ID (address). We pass address(0) as a placeholder for the first argument,
        // and the actual recipient as the second argument — which is left untouched.
        bytes memory payload = abi.encodeWithSignature(
            "addToAllowlistReactive(address,address)",
            address(0), // placeholder — overwritten by Reactive Network with RVM ID at delivery
            recipient   // actual institution address to allowlist
        );

        emit Callback(UNICHAIN_SEPOLIA_CHAIN_ID, hookContract, CALLBACK_GAS_LIMIT, payload);
    }

    // ─── Admin (RNK only) ─────────────────────────────────────────────────────

    /// @notice Pause monitoring by unsubscribing from MembershipNFT events.
    function pause() external rnOnly {
        SERVICE_ADDR.unsubscribe(
            UNICHAIN_SEPOLIA_CHAIN_ID,
            membershipNFT,
            TRANSFER_EVENT_TOPIC,
            ZERO_TOPIC,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @notice Resume monitoring by re-subscribing to MembershipNFT events.
    function resume() external rnOnly {
        SERVICE_ADDR.subscribe(
            UNICHAIN_SEPOLIA_CHAIN_ID,
            membershipNFT,
            TRANSFER_EVENT_TOPIC,
            ZERO_TOPIC,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }
}
