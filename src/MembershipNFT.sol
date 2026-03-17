// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IStableGate} from "./interfaces/IStableGate.sol";

contract MembershipNFT is ERC721, IStableGate {
    error NotAdmin();
    error ZeroAddress();
    error NotMember(address account);
    error TransferRestricted();

    event MembershipGranted(address indexed institution, uint256 tokenId);
    event MembershipRevoked(address indexed institution, uint256 tokenId);

    address public admin;
    uint256 public nextTokenId = 1;

    /// @notice Default membership validity period in seconds (0 = no expiry by default).
    uint256 public defaultExpiryDuration;

    /// @notice Tier per token ID.
    mapping(uint256 => Tier) public tokenTier;

    /// @notice Expiry timestamp per token ID. 0 = no expiry.
    mapping(uint256 => uint256) public tokenExpiry;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(address _admin) ERC721("StableGate Membership", "SGM") {
        if (_admin == address(0)) revert ZeroAddress();
        admin = _admin;
    }

    // ─── Mint / Revoke ────────────────────────────────────────────────────────

    /// @notice Mint a Bronze membership with default expiry. Backwards-compatible.
    function grantMembership(address to) external onlyAdmin returns (uint256 tokenId) {
        tokenId = _mintMembership(to, Tier.Bronze);
    }

    /// @notice Mint a membership with an explicit tier and default expiry.
    function grantMembershipWithTier(address to, Tier tier) external onlyAdmin returns (uint256 tokenId) {
        tokenId = _mintMembership(to, tier);
    }

    function _mintMembership(address to, Tier tier) internal returns (uint256 tokenId) {
        if (to == address(0)) revert ZeroAddress();
        tokenId = nextTokenId++;
        tokenTier[tokenId] = tier;
        if (defaultExpiryDuration != 0) {
            tokenExpiry[tokenId] = block.timestamp + defaultExpiryDuration;
        }
        _mint(to, tokenId);
        emit MembershipGranted(to, tokenId);
        emit TierUpdated(to, tier);
    }

    function revokeMembership(uint256 tokenId) external onlyAdmin {
        address owner = ownerOf(tokenId);
        _burn(tokenId);
        emit MembershipRevoked(owner, tokenId);
    }

    // ─── Admin Setters ────────────────────────────────────────────────────────

    /// @notice Update the tier for an existing token. Admin only.
    function setTier(uint256 tokenId, Tier tier) external onlyAdmin {
        address owner = ownerOf(tokenId); // reverts if token doesn't exist
        tokenTier[tokenId] = tier;
        emit TierUpdated(owner, tier);
    }

    /// @notice Update the expiry timestamp for an existing token. Admin only.
    function setExpiry(uint256 tokenId, uint256 timestamp) external onlyAdmin {
        ownerOf(tokenId); // reverts if token doesn't exist
        tokenExpiry[tokenId] = timestamp;
    }

    /// @notice Set the default expiry duration applied to new mints. Admin only.
    function setDefaultExpiryDuration(uint256 duration) external onlyAdmin {
        defaultExpiryDuration = duration;
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        admin = newAdmin;
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function isMember(address account) external view returns (bool) {
        return balanceOf(account) > 0;
    }

    /// @notice Returns the tier for the first token held by `institution`. Reverts if not a member.
    function getTier(address institution) external view returns (Tier) {
        if (balanceOf(institution) == 0) revert NotMember(institution);
        // ERC721 doesn't expose token-by-owner index without Enumerable; we track via tokenOfOwner
        // convention: read tokenTier for the token owned by institution.
        // Since we track tokenId sequentially and store tier per tokenId, we need a reverse mapping.
        // Use the institutionToken mapping added below.
        return tokenTier[_institutionToken[institution]];
    }

    /// @notice Returns true if the token has a non-zero expiry that is in the past.
    function isExpired(uint256 tokenId) external view returns (bool) {
        uint256 expiry = tokenExpiry[tokenId];
        return expiry != 0 && block.timestamp > expiry;
    }

    // ─── Transfer Restriction ─────────────────────────────────────────────────

    /// @dev Override ERC721._update to block transfers between non-zero addresses.
    ///      Burns (to == address(0)) and mints (from == address(0)) are always allowed.
    ///      Only the admin can initiate any transfer (via _mint/_burn which go through _update).
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        // Block transfers between two non-zero addresses (i.e., secondary market transfers)
        if (from != address(0) && to != address(0)) revert TransferRestricted();
        // Track institution → tokenId for getTier convenience lookup
        if (from != address(0)) delete _institutionToken[from];
        if (to != address(0)) _institutionToken[to] = tokenId;
        return super._update(to, tokenId, auth);
    }

    // ─── Internal State ───────────────────────────────────────────────────────

    /// @dev Maps institution address → token ID they currently hold.
    mapping(address => uint256) private _institutionToken;
}
