// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-hooks-public/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
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
    error MissingSwapperHookData();

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

    /// @dev Decodes the swapper address from hookData.
    ///      Supports two encodings:
    ///      - abi.encode(addr)        → 32 bytes, address in low 20 bytes
    ///      - abi.encodePacked(addr)  → 20 bytes, address in high 20 bytes of the loaded word
    function _decodeSwapper(bytes calldata hookData) internal pure returns (address swapper) {
        if (hookData.length >= 32) {
            swapper = abi.decode(hookData, (address));
        } else if (hookData.length == 20) {
            assembly ("memory-safe") {
                // Load 32 bytes from the calldata pointer; the address occupies the first 20 bytes.
                // Shift right by 96 bits (12 bytes) to move it into address position.
                swapper := shr(96, calldataload(hookData.offset))
            }
        } else {
            revert MissingSwapperHookData();
        }
    }

    /// @dev Checks allowlist then executes CSMM (1:1) pricing via the NoOp pattern.
    ///
    ///      Token flow:
    ///        1. Hook takes `amount` of inputCurrency from PoolManager (input was deposited by swapper).
    ///        2. Hook settles `amount` of outputCurrency into PoolManager (PoolManager forwards to swapper).
    ///        3. Returns `toBeforeSwapDelta(-amountSpecified, amountSpecified)` to NoOp the AMM curve.
    ///
    ///      The hook must hold a reserve of both tokens (seeded via direct ERC20 transfer to this address).
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address swapper = _decodeSwapper(hookData);
        if (!allowlist[swapper]) revert SwapperNotAllowlisted(swapper);

        (Currency inputCurrency, Currency outputCurrency) = params.zeroForOne
            ? (key.currency0, key.currency1)
            : (key.currency1, key.currency0);

        uint256 amount = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        // Pull input tokens from PoolManager into the hook
        poolManager.take(inputCurrency, address(this), amount);

        // Push output tokens from the hook to PoolManager (sync → transfer → settle)
        poolManager.sync(outputCurrency);
        outputCurrency.transfer(address(poolManager), amount);
        poolManager.settle();

        emit SwapExecuted(swapper, key.toId(), params.zeroForOne, params.amountSpecified);

        // Tell PoolManager the hook fully handled the swap at 1:1 — bypass the AMM curve
        return (
            IHooks.beforeSwap.selector,
            toBeforeSwapDelta(int128(-params.amountSpecified), int128(params.amountSpecified)),
            0
        );
    }

    // ─── Allowlist Management ─────────────────────────────────────────────────

    /// @notice Manually add an address to the allowlist. Owner only.
    ///         For Reactive Network callbacks, use addToAllowlistReactive() instead.
    function addToAllowlist(address account) external onlyOwner {
        _addToAllowlist(account);
    }

    /// @notice Called by the Reactive Network Callback Proxy after an RSC emits a Callback.
    ///         Reactive Network automatically overwrites the first argument of every callback
    ///         payload with the deployer's RVM ID address. This two-argument variant accepts
    ///         that injected value as `rvmId` (ignored here — msg.sender check is sufficient)
    ///         and the actual institution address as `account`.
    /// @param  rvmId    Injected by Reactive Network — the RSC deployer's address (unused).
    /// @param  account  The institution address to allowlist.
    function addToAllowlistReactive(address rvmId, address account) external {
        if (msg.sender != reactiveCallbackProxy) revert NotOwnerOrReactive();
        // rvmId can be used for additional verification (e.g., require(rvmId == authorizedRsc))
        // but is intentionally not checked here — msg.sender against the proxy is sufficient.
        (rvmId); // silence unused-variable warning
        _addToAllowlist(account);
    }

    /// @dev Shared logic for adding an account to the allowlist.
    function _addToAllowlist(address account) internal {
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
