// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MembershipNFT is ERC721 {
    error NotAdmin();
    error ZeroAddress();

    event MembershipGranted(address indexed institution, uint256 tokenId);
    event MembershipRevoked(address indexed institution, uint256 tokenId);

    address public admin;
    uint256 public nextTokenId = 1;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(address _admin) ERC721("StableGate Membership", "SGM") {
        if (_admin == address(0)) revert ZeroAddress();
        admin = _admin;
    }

    function grantMembership(address to) external onlyAdmin returns (uint256 tokenId) {
        if (to == address(0)) revert ZeroAddress();
        tokenId = nextTokenId++;
        _mint(to, tokenId);
        emit MembershipGranted(to, tokenId);
    }

    function revokeMembership(uint256 tokenId) external onlyAdmin {
        address owner = ownerOf(tokenId);
        _burn(tokenId);
        emit MembershipRevoked(owner, tokenId);
    }

    function isMember(address account) external view returns (bool) {
        return balanceOf(account) > 0;
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        admin = newAdmin;
    }
}
