// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-hooks-public/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title PermissionedCSMMHook
/// @notice Uniswap v4 hook implementing a Constant Sum Market Maker (1:1 pricing) with
///         KYC-gated allowlist access. The allowlist can be managed by the owner or by
///         the Reactive Network callback proxy (triggered by MembershipNFT mint events).
contract PermissionedCSMMHook is BaseHook {
    using CurrencyLibrary for Currency;
    using SafeCast for int256;

    // ─── Errors ──────────────────────────────────────────────────────────────

    error NotOwnerOrReactive();
    error NotOwner();
    error SwapperNotAllowlisted(address swapper);
    error AddZeroAddress();
    error AlreadyAllowlisted(address account);
    error NotAllowlisted(address account);

    // ─── Events ──────────────────────────────────────────────────────────────

    event AddressAllowlisted(address indexed account, uint256 timestamp);
    event AddressRemovedFromAllowlist(address indexed account, uint256 timestamp);
    event SwapExecuted(address indexed swapper, PoolId indexed poolId, bool zeroForOne, int256 amountSpecified);

    // ─── State ───────────────────────────────────────────────────────────────

    address public owner;
    /// @notice The Reactive Network callback proxy — can call addToAllowlist on behalf of the RSC
    address public reactiveCallbackProxy;

    mapping(address => bool) public allowlist;
    uint256 public allowlistCount;

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOwnerOrReactive() {
        if (msg.sender != owner && msg.sender != reactiveCallbackProxy) revert NotOwnerOrReactive();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(IPoolManager _poolManager, address _reactiveCallbackProxy) BaseHook(_poolManager) {
        owner = msg.sender;
        reactiveCallbackProxy = _reactiveCallbackProxy;
    }

    // ─── Hook Permissions ─────────────────────────────────────────────────────
    // All final flags are set now so the hook address stays valid when CSMM is
    // added in Step 7.  beforeSwapReturnDelta is needed for the NoOp pattern.

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── Hook Callbacks ───────────────────────────────────────────────────────

    /// @dev Allows all liquidity additions — no restrictions imposed for now.
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev Checks allowlist and delegates pricing to the AMM (CSMM added in Step 7).
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Decode swapper address from hookData; fall back to tx.origin for testing
        address swapper = hookData.length >= 32 ? abi.decode(hookData, (address)) : tx.origin;

        if (!allowlist[swapper]) revert SwapperNotAllowlisted(swapper);

        // Pass-through: return ZERO_DELTA so the AMM handles pricing normally
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ─── Allowlist Management ─────────────────────────────────────────────────

    /// @notice Add an address to the allowlist. Called by owner or Reactive callback proxy.
    function addToAllowlist(address account) external onlyOwnerOrReactive {
        if (account == address(0)) revert AddZeroAddress();
        if (allowlist[account]) revert AlreadyAllowlisted(account);

        allowlist[account] = true;
        allowlistCount++;
        emit AddressAllowlisted(account, block.timestamp);
    }

    /// @notice Remove an address from the allowlist.
    function removeFromAllowlist(address account) external onlyOwner {
        if (!allowlist[account]) revert NotAllowlisted(account);

        allowlist[account] = false;
        allowlistCount--;
        emit AddressRemovedFromAllowlist(account, block.timestamp);
    }

    /// @notice Batch-add multiple addresses to the allowlist. Skips duplicates.
    function batchAddToAllowlist(address[] calldata accounts) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];
            if (account == address(0)) revert AddZeroAddress();
            if (!allowlist[account]) {
                allowlist[account] = true;
                allowlistCount++;
                emit AddressAllowlisted(account, block.timestamp);
            }
        }
    }

    function isAllowlisted(address account) external view returns (bool) {
        return allowlist[account];
    }

    // ─── Admin Functions ──────────────────────────────────────────────────────

    function setReactiveCallbackProxy(address proxy) external onlyOwner {
        reactiveCallbackProxy = proxy;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert AddZeroAddress();
        owner = newOwner;
    }
}
