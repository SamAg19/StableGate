// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-hooks-public/base/BaseHook.sol";
import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";
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
///         Extends AbstractCallback for Reactive Network callback authorization via rvmIdOnly.
contract PermissionedCSMMHook is BaseHook, AbstractCallback, IStableGate {
    using CurrencyLibrary for Currency;
    using SafeCast for int256;

    // ─── Errors ──────────────────────────────────────────────────────────────

    error NotOwner();
    error SwapperNotAllowlisted(address swapper);
    error AddZeroAddress();
    error AlreadyAllowlisted(address account);
    error NotAllowlisted(address account);
    error MissingSwapperHookData();
    error ZeroFees();
    error ZeroAddress();
    error InvalidSplitBps();
    error LPNotWhitelisted(address lp);
    error LPAlreadyWhitelisted(address lp);
    error LPNotInWhitelist(address lp);

    // ─── Events ──────────────────────────────────────────────────────────────

    event AddressAllowlisted(address indexed account, uint256 timestamp);
    event AddressRemovedFromAllowlist(address indexed account, uint256 timestamp);
    event SwapExecuted(address indexed swapper, PoolId indexed poolId, bool zeroForOne, int256 amountSpecified);
    event InstitutionStateCleared(address indexed institution);
    event FeesWithdrawn(address indexed recipient, address indexed currency, uint256 amount);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event LpFeeSplitUpdated(uint256 oldSplitBps, uint256 newSplitBps);
    event FeesDistributed(address indexed currency, uint256 lpAmount, uint256 operatorAmount);
    event LPWhitelistUpdated(address indexed lp, bool added);

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

    // ─── Fee Split ──────────────────────────────────────────────────────────

    /// @notice Recipient of operator's share of swap fees.
    address public feeRecipient;

    /// @notice Accrued operator fee share per currency, withdrawable via withdrawFees().
    mapping(address => uint256) public accruedFees;

    /// @notice LP share of swap fees in bps (out of 10000). Default 50%.
    uint256 public lpFeeSplitBps = 5000;

    uint256 public constant MAX_LP_SPLIT_BPS = 10000;

    // ─── State ───────────────────────────────────────────────────────────────

    address public owner;

    mapping(address => bool) public allowlist;
    uint256 public allowlistCount;

    /// @notice Tier per institution address. Default value (Bronze) applies if not explicitly set.
    mapping(address => Tier) public institutionTier;

    /// @notice Expiry timestamp per institution. 0 = no expiry.
    mapping(address => uint256) public institutionExpiry;

    // ─── LP Whitelist State ────────────────────────────────────────────────────

    mapping(address => bool) public lpWhitelist;
    uint256 public lpWhitelistCount;

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

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @notice Unichain Sepolia callback proxy address (Reactive Network constant).
    address public constant CALLBACK_PROXY = 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4;

    constructor(
        IPoolManager _poolManager,
        address _owner,
        address _feeRecipient
    ) BaseHook(_poolManager) AbstractCallback(CALLBACK_PROXY) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_feeRecipient == address(0)) revert ZeroAddress();
        owner = _owner;
        feeRecipient = _feeRecipient;
        // Override rvm_id set by AbstractCallback (which uses msg.sender).
        // When deployed via CREATE2 factory, msg.sender is the factory not the deployer.
        // The RSC sends the deployer's address as rvm_id in callbacks, so it must match.
        rvm_id = _owner;
    }

    /// @dev Override receive() to resolve conflict between AbstractPayer and any other parent.
    receive() external payable override {}

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

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) internal view override returns (bytes4) {
        address lp = hookData.length > 0 ? abi.decode(hookData, (address)) : sender;
        if (!lpWhitelist[lp]) revert LPNotWhitelisted(lp);
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

        // 5. Fee split: LP share via donate(), operator share accrued for withdrawal
        uint256 lpAmount;
        if (feeAmount > 0) {
            lpAmount = (feeAmount * lpFeeSplitBps) / 10000;
            uint256 operatorAmount = feeAmount - lpAmount;

            if (operatorAmount > 0) {
                accruedFees[Currency.unwrap(outputCurrency)] += operatorAmount;
            }

            // Return LP share to pool via donate() — distributes proportionally to in-range LPs.
            // donate() creates a debit on the hook which the subsequent settle() covers.
            if (lpAmount > 0) {
                poolManager.donate(
                    key,
                    outputCurrency == key.currency0 ? lpAmount : 0,
                    outputCurrency == key.currency1 ? lpAmount : 0,
                    ""
                );
            }

            emit FeesDistributed(Currency.unwrap(outputCurrency), lpAmount, operatorAmount);
        }

        // Push net output + LP donation from hook to PoolManager.
        // outputAmount settles the swap; lpAmount settles the donate() debit.
        poolManager.sync(outputCurrency);
        outputCurrency.transfer(address(poolManager), outputAmount + lpAmount);
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

    // ─── Allowlist Management (owner-only direct calls) ─────────────────────

    function addToAllowlist(address account) external onlyOwner {
        _addToAllowlist(account);
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

    // ─── Reactive Network Callback Functions (rvmIdOnly) ─────────────────────

    /// @notice Called by Reactive Network callback proxy after a mint RSC event.
    function addToAllowlistReactive(address _rvm_id, address account) external rvmIdOnly(_rvm_id) {
        _addToAllowlist(account);
    }

    /// @notice Remove from allowlist + clear state. Called by RSC on burn/transfer.
    function removeFromAllowlistReactive(address _rvm_id, address account) external rvmIdOnly(_rvm_id) {
        _removeFromAllowlist(account);
    }

    /// @notice Set institution tier. Called by RSC on TierUpdated event.
    function setInstitutionTier(address _rvm_id, address institution, Tier tier) external rvmIdOnly(_rvm_id) {
        institutionTier[institution] = tier;
        emit TierUpdated(institution, tier);
    }

    /// @notice Set institution expiry. Called by RSC on ExpirySet event.
    function setInstitutionExpiry(address _rvm_id, address institution, uint256 expiry) external rvmIdOnly(_rvm_id) {
        institutionExpiry[institution] = expiry;
    }

    /// @notice Add to LP whitelist. Called by RSC on LP NFT mint.
    function addToLPWhitelist(address _rvm_id, address lp) external rvmIdOnly(_rvm_id) {
        if (lp == address(0)) revert ZeroAddress();
        if (lpWhitelist[lp]) revert LPAlreadyWhitelisted(lp);
        lpWhitelist[lp] = true;
        lpWhitelistCount++;
        emit LPWhitelistUpdated(lp, true);
    }

    /// @notice Remove from LP whitelist. Called by RSC on LP NFT burn/transfer.
    function removeFromLPWhitelist(address _rvm_id, address lp) external rvmIdOnly(_rvm_id) {
        if (!lpWhitelist[lp]) revert LPNotInWhitelist(lp);
        lpWhitelist[lp] = false;
        lpWhitelistCount--;
        emit LPWhitelistUpdated(lp, false);
    }

    function isLPWhitelisted(address lp) external view returns (bool) {
        return lpWhitelist[lp];
    }

    // ─── Internal Allowlist Helpers ──────────────────────────────────────────

    function _addToAllowlist(address account) internal {
        if (account == address(0)) revert AddZeroAddress();
        if (allowlist[account]) revert AlreadyAllowlisted(account);
        allowlist[account] = true;
        allowlistCount++;
        emit AddressAllowlisted(account, block.timestamp);
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

    // ─── Fee Management ────────────────────────────────────────────────────

    function withdrawFees(address currency) external onlyOwner {
        uint256 amount = accruedFees[currency];
        if (amount == 0) revert ZeroFees();
        accruedFees[currency] = 0;
        Currency.wrap(currency).transfer(feeRecipient, amount);
        emit FeesWithdrawn(feeRecipient, currency, amount);
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        emit FeeRecipientUpdated(feeRecipient, recipient);
        feeRecipient = recipient;
    }

    function setLpFeeSplitBps(uint256 splitBps) external onlyOwner {
        if (splitBps > MAX_LP_SPLIT_BPS) revert InvalidSplitBps();
        emit LpFeeSplitUpdated(lpFeeSplitBps, splitBps);
        lpFeeSplitBps = splitBps;
    }

    // ─── Admin Functions ──────────────────────────────────────────────────────

    function setBlocksPerDay(uint256 blocks) external onlyOwner {
        blocksPerDay = blocks;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert AddZeroAddress();
        owner = newOwner;
    }
}
