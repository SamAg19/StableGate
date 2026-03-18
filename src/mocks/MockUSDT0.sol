// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock USDT0 for StableGate testnet deployment.
/// @dev Public mint — do NOT deploy to mainnet.
contract MockUSDT0 is ERC20 {
    uint8 private constant DECIMALS = 6;

    constructor() ERC20("Tether USD0 (Mock)", "USDT0") {}

    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    /// @notice Mint any amount to any address. Testnet only.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
