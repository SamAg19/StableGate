// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title LPMembershipNFT
/// @notice Non-transferable ERC721 credential on Base granting liquidity provision rights
///         on the Unichain PermissionedCSMMHook pool. Binary access — no tiers or expiry.
contract LPMembershipNFT is ERC721 {
    error NotAdmin();
    error ZeroAddress();
    error TransferRestricted();

    event LPMembershipGranted(address indexed to, uint256 tokenId);
    event LPMembershipRevoked(address indexed from, uint256 tokenId);

    address public admin;
    uint256 public nextTokenId = 1;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(address _admin) ERC721("StableGate LP Membership", "SGLP") {
        if (_admin == address(0)) revert ZeroAddress();
        admin = _admin;
    }

    // ─── Mint / Revoke ────────────────────────────────────────────────────────

    function grantLPMembership(address to) external onlyAdmin returns (uint256 tokenId) {
        if (to == address(0)) revert ZeroAddress();
        tokenId = nextTokenId++;
        _mint(to, tokenId);
        emit LPMembershipGranted(to, tokenId);
    }

    function revokeLPMembership(uint256 tokenId) external onlyAdmin {
        address holder = ownerOf(tokenId);
        _burn(tokenId);
        emit LPMembershipRevoked(holder, tokenId);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function isLPMember(address account) external view returns (bool) {
        return balanceOf(account) > 0;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        admin = newAdmin;
    }

    // ─── Transfer Restriction ─────────────────────────────────────────────────

    /// @dev Block transfers between non-zero addresses. Mints and burns are allowed.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert TransferRestricted();
        return super._update(to, tokenId, auth);
    }
}
