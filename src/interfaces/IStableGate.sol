// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IStableGate
/// @notice Shared types, errors, and events used across all StableGate contracts.
interface IStableGate {
    // ─── Tier Enum ───────────────────────────────────────────────────────────

    /// @notice Membership tier. Bronze is the default tier assigned on basic mint.
    enum Tier {
        Bronze,
        Silver,
        Gold
    }

    // ─── Custom Errors ───────────────────────────────────────────────────────

    /// @notice Reverts when a swap is attempted with an expired membership.
    error MembershipExpired(address institution);

    /// @notice Reverts when an institution's daily swap volume cap would be exceeded.
    error DailyLimitExceeded(address institution, uint256 limit, uint256 attempted);

    /// @notice Reverts when an invalid tier value is provided.
    error InvalidTier();

    // ─── Events ──────────────────────────────────────────────────────────────

    /// @notice Emitted when an institution's membership tier is updated.
    /// tier is indexed so the Reactive RSC can read it from topic_2 without decoding data.
    event TierUpdated(address indexed institution, Tier indexed tier);

    /// @notice Emitted when a membership token expires on-chain.
    event MembershipExpiredEvent(address indexed institution, uint256 tokenId);

    /// @notice Emitted when an institution's daily swap volume counter is reset.
    event DailyVolumeReset(address indexed institution, uint256 blockNumber);
}
