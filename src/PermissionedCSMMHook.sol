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
import {IStableGate} from "./interfaces/IStableGate.sol";

/// @title PermissionedCSMMHook
/// @notice Uniswap v4 hook implementing a Constant Sum Market Maker (1:1 pricing) with
///         KYC-gated allowlist access, tier-based dynamic fees, membership expiry enforcement,
///         and per-institution daily swap volume limits.
contract PermissionedCSMMHook is BaseHook, IStableGate {
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
    /// @notice Emitted when all institution-specific state is wiped on revocation.
    event InstitutionStateCleared(address indexed institution);

    // ─── Fee Constants ────────────────────────────────────────────────────────

    /// @notice Fee in parts-per-million for Gold tier (0 bps = zero-fee trading).
    uint24 public constant FEE_GOLD = 0;

    /// @notice Fee in parts-per-million for Silver tier (1 bps = 100 ppm).
    uint24 public constant FEE_SILVER = 100;

    /// @notice Fee in parts-per-million for Bronze tier (3 bps = 300 ppm).
    uint24 public constant FEE_BRONZE = 300;

    uint24 private constant FEE_DENOMINATOR = 1_000_000;

    // ─── Tier-Derived Daily Limits ────────────────────────────────────────────

    /// @notice Gold institutions have no daily cap (unlimited trading).
    uint256 public constant DAILY_LIMIT_GOLD = 0;

    /// @notice Silver institutions may swap up to 5,000,000 USDC (6-decimal) per day.
    uint256 public constant DAILY_LIMIT_SILVER = 5_000_000e6;

    /// @notice Bronze institutions may swap up to 1,000,000 USDC (6-decimal) per day.
    uint256 public constant DAILY_LIMIT_BRONZE = 1_000_000e6;

    // ─── State ───────────────────────────────────────────────────────────────

    address public owner;
    /// @notice The Reactive Network callback proxy — can call allowlist functions on behalf of the RSC.
    address public reactiveCallbackProxy;

    mapping(address => bool) public allowlist;
    uint256 public allowlistCount;

    /// @notice Tier per institution address. Default value (Bronze) applies if not explicitly set.
    mapping(address => Tier) public institutionTier;

    /// @notice Expiry timestamp per institution. 0 = no expiry.
    mapping(address => uint256) public institutionExpiry;

    // ─── Daily Volume Limit State ─────────────────────────────────────────────

    /// @notice Cumulative input volume swapped in the current block window, per institution.
    mapping(address => uint256) public dailyVolume;

    /// @notice Block number of the last volume reset, per institution.
    mapping(address => uint256) public lastResetBlock;

    /// @notice Number of blocks that constitute one "day". Default: 7200 (~24 h on Unichain).
    uint256 public blocksPerDay = 7200;

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

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev Decodes the swapper address from hookData.
    function _decodeSwapper(bytes calldata hookData) internal pure returns (address swapper) {
        if (hookData.length >= 32) {
            swapper = abi.decode(hookData, (address));
        } else if (hookData.length == 20) {
            assembly ("memory-safe") {
                swapper := shr(96, calldataload(hookData.offset))
            }
        } else {
            revert MissingSwapperHookData();
        }
    }

    /// @dev Checks allowlist, expiry, daily volume cap, then executes CSMM (1:1) pricing
    ///      with a tier-based fee deducted from the output amount.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address swapper = _decodeSwapper(hookData);

        // 1. Allowlist check
        if (!allowlist[swapper]) revert SwapperNotAllowlisted(swapper);

        // 2. Expiry check
        uint256 expiry = institutionExpiry[swapper];
        if (expiry != 0 && block.timestamp > expiry) revert MembershipExpired(swapper);

        // 3. Daily volume cap
        uint256 absAmount = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        _checkAndUpdateVolume(swapper, absAmount);

        // 4. Determine tier fee and compute net output
        uint24 fee = _tierFee(institutionTier[swapper]);
        uint256 feeAmount = (absAmount * fee) / FEE_DENOMINATOR;
        uint256 outputAmount = absAmount - feeAmount;

        (Currency inputCurrency, Currency outputCurrency) = params.zeroForOne
            ? (key.currency0, key.currency1)
            : (key.currency1, key.currency0);

        // Pull full input from PoolManager into the hook
        poolManager.take(inputCurrency, address(this), absAmount);

        // Push net output from hook to PoolManager (fee stays in hook as revenue)
        poolManager.sync(outputCurrency);
        outputCurrency.transfer(address(poolManager), outputAmount);
        poolManager.settle();

        emit SwapExecuted(swapper, key.toId(), params.zeroForOne, params.amountSpecified);

        // NoOp: tell PoolManager the hook fully handled the swap.
        // deltaSpecified  = +absAmount  → hook absorbed the full input from PM
        // deltaUnspecified = -outputAmount → hook deposited outputAmount of output into PM
        // (negative = hook owes PM, which PM forwards to the swapper)
        return (
            IHooks.beforeSwap.selector,
            toBeforeSwapDelta(int128(-params.amountSpecified), -int128(int256(outputAmount))),
            0
        );
    }

    // ─── Internal Helpers ─────────────────────────────────────────────────────

    function _dailyLimitForTier(Tier tier) internal pure returns (uint256) {
        if (tier == Tier.Gold) return DAILY_LIMIT_GOLD;
        if (tier == Tier.Silver) return DAILY_LIMIT_SILVER;
        return DAILY_LIMIT_BRONZE;
    }

    function _tierFee(Tier tier) internal pure returns (uint24) {
        if (tier == Tier.Gold) return FEE_GOLD;
        if (tier == Tier.Silver) return FEE_SILVER;
        return FEE_BRONZE;
    }

    function _checkAndUpdateVolume(address swapper, uint256 absAmount) internal {
        // Reset window if enough blocks have passed
        if (block.number > lastResetBlock[swapper] + blocksPerDay) {
            dailyVolume[swapper] = 0;
            lastResetBlock[swapper] = block.number;
            emit DailyVolumeReset(swapper, block.number);
        }

        uint256 effective = _dailyLimitForTier(institutionTier[swapper]);
        if (effective > 0 && dailyVolume[swapper] + absAmount > effective) {
            revert DailyLimitExceeded(swapper, effective, absAmount);
        }

        dailyVolume[swapper] += absAmount;
    }

    // ─── Allowlist Management ─────────────────────────────────────────────────

    function addToAllowlist(address account) external onlyOwner {
        _addToAllowlist(account);
    }

    /// @notice Called by the Reactive Network Callback Proxy after a mint RSC event.
    function addToAllowlistReactive(address rvmId, address account) external {
        if (msg.sender != reactiveCallbackProxy) revert NotOwnerOrReactive();
        (rvmId);
        _addToAllowlist(account);
    }

    function _addToAllowlist(address account) internal {
        if (account == address(0)) revert AddZeroAddress();
        if (allowlist[account]) revert AlreadyAllowlisted(account);
        allowlist[account] = true;
        allowlistCount++;
        emit AddressAllowlisted(account, block.timestamp);
    }

    /// @notice Remove an address from the allowlist. Owner only.
    function removeFromAllowlist(address account) external onlyOwner {
        _removeFromAllowlist(account);
    }

    /// @notice Remove an address from the allowlist. Callable by the reactive proxy (for auto-revocation).
    function removeFromAllowlistReactive(address rvmId, address account) external {
        if (msg.sender != reactiveCallbackProxy) revert NotOwnerOrReactive();
        (rvmId);
        _removeFromAllowlist(account);
    }

    /// @dev Atomically removes from allowlist and clears all institution-specific state.
    function _removeFromAllowlist(address account) internal {
        if (!allowlist[account]) revert NotAllowlisted(account);
        allowlist[account] = false;
        allowlistCount--;
        emit AddressRemovedFromAllowlist(account, block.timestamp);

        // Reset all per-institution state so re-onboarding always starts from a clean slate.
        institutionTier[account]   = Tier.Bronze;
        institutionExpiry[account] = 0;
        dailyVolume[account]       = 0;
        lastResetBlock[account]    = 0;
        emit InstitutionStateCleared(account);
    }

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

    // ─── Tier & Expiry Management ─────────────────────────────────────────────

    /// @notice Set the tier for an institution. Callable by owner or reactive proxy.
    function setInstitutionTier(address institution, Tier tier) external onlyOwnerOrReactive {
        institutionTier[institution] = tier;
        emit TierUpdated(institution, tier);
    }

    /// @notice Set the expiry for an institution. Callable by owner or reactive proxy.
    function setInstitutionExpiry(address institution, uint256 expiry) external onlyOwnerOrReactive {
        institutionExpiry[institution] = expiry;
    }

    // ─── Daily Limit Management ───────────────────────────────────────────────

    function setBlocksPerDay(uint256 blocks) external onlyOwner {
        blocksPerDay = blocks;
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
