// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AllowlistReactiveContract} from "../src/AllowlistReactiveContract.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {IStableGate} from "../src/interfaces/IStableGate.sol";

contract AllowlistReactiveContractTest is Test {
    AllowlistReactiveContract rsc;

    address constant MEMBERSHIP_NFT = address(0x1111);
    address constant LP_MEMBERSHIP_NFT = address(0x3333);
    address constant HOOK_CONTRACT = address(0x2222);
    address constant INSTITUTION = address(0xBEEF);
    address constant LP_ADDRESS = address(0xCAFE);
    uint256 constant TOKEN_ID = 1;

    function setUp() public {
        // On local Anvil/Forge chain, 0x...fffFfF has no code → vm flag = true (ReactVM mode).
        // Constructor skips subscribe() which is correct — no system contract to call.
        rsc = new AllowlistReactiveContract(MEMBERSHIP_NFT, LP_MEMBERSHIP_NFT, HOOK_CONTRACT);
    }

    function test_constructorSetsState() public view {
        assertEq(rsc.membershipNFT(), MEMBERSHIP_NFT);
        assertEq(rsc.hookContract(), HOOK_CONTRACT);
        assertEq(rsc.callbackCount(), 0);
    }

    function test_reactEmitsCallback() public {
        IReactive.LogRecord memory log = _buildMintLog(INSTITUTION, TOKEN_ID);

        vm.expectEmit(true, false, false, true);
        emit AllowlistReactiveContract.MintDetected(INSTITUTION, TOKEN_ID, 100);

        vm.expectEmit(true, true, false, false);
        emit AllowlistReactiveContract.CallbackTriggered(HOOK_CONTRACT, 1);

        rsc.react(log);
    }

    function test_reactIncrementsCallbackCount() public {
        rsc.react(_buildMintLog(INSTITUTION, TOKEN_ID));
        assertEq(rsc.callbackCount(), 1);

        rsc.react(_buildMintLog(address(0xCAFE), 2));
        assertEq(rsc.callbackCount(), 2);
    }

    function test_reactCallbackPayloadEncoding() public {
        IReactive.LogRecord memory log = _buildMintLog(INSTITUTION, TOKEN_ID);

        vm.recordLogs();
        rsc.react(log);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find the Callback event emitted by the RSC
        // event Callback(uint256 indexed chain_id, address indexed _contract, uint64 indexed gas_limit, bytes payload)
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Callback(uint256,address,uint64,bytes)")) {
                found = true;

                // topics[1] = chain_id (uint256)
                uint256 chainId = uint256(logs[i].topics[1]);
                assertEq(chainId, rsc.UNICHAIN_SEPOLIA_CHAIN_ID(), "chain_id");

                // topics[2] = hook contract address
                address target = address(uint160(uint256(logs[i].topics[2])));
                assertEq(target, HOOK_CONTRACT, "target");

                // topics[3] = gas limit (uint64)
                uint64 gasLimit = uint64(uint256(logs[i].topics[3]));
                assertEq(gasLimit, rsc.CALLBACK_GAS_LIMIT(), "gas_limit");

                // data = ABI-encoded bytes (the payload)
                bytes memory payload = abi.decode(logs[i].data, (bytes));
                bytes memory expected = abi.encodeWithSignature(
                    "addToAllowlistReactive(address,address)",
                    address(0), // placeholder overwritten by Reactive Network with RVM ID
                    INSTITUTION
                );
                assertEq(payload, expected, "payload encoding");
            }
        }
        assertTrue(found, "Callback event not emitted");
    }

    function test_reactMultipleMints() public {
        address[3] memory institutions = [address(0xA1), address(0xA2), address(0xA3)];

        for (uint256 i = 0; i < 3; i++) {
            rsc.react(_buildMintLog(institutions[i], i + 1));
        }

        assertEq(rsc.callbackCount(), 3);
    }

    // ─── Step 24: Auto-Revocation & Tier Forwarding Tests ─────────────────────

    function test_burnTriggersRevocation() public {
        address holder = address(0xBEEF);
        IReactive.LogRecord memory log = _buildBurnLog(holder, TOKEN_ID);

        vm.recordLogs();
        rsc.react(log);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find Callback event and verify removeFromAllowlistReactive payload
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Callback(uint256,address,uint64,bytes)")) {
                found = true;
                bytes memory payload = abi.decode(logs[i].data, (bytes));
                bytes memory expected = abi.encodeWithSignature(
                    "removeFromAllowlistReactive(address,address)",
                    address(0),
                    holder
                );
                assertEq(payload, expected, "burn revocation payload");
            }
        }
        assertTrue(found, "Callback event not emitted for burn");
    }

    function test_transferTriggersRevocation() public {
        address holder = address(0xBEEF);
        address newHolder = address(0xCAFE);
        IReactive.LogRecord memory log = _buildTransferLog(holder, newHolder, TOKEN_ID);

        vm.recordLogs();
        rsc.react(log);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Verify old holder is revoked
        bool revokeFound;
        bool grantFound;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Callback(uint256,address,uint64,bytes)")) {
                bytes memory payload = abi.decode(logs[i].data, (bytes));
                bytes4 selector = bytes4(payload);
                if (selector == bytes4(keccak256("removeFromAllowlistReactive(address,address)"))) {
                    revokeFound = true;
                    // payload should target `holder` (from), not `newHolder`
                    (, address targetAddr) = abi.decode(
                        _stripSelector(payload),
                        (address, address)
                    );
                    assertEq(targetAddr, holder, "revocation targets original holder");
                }
                if (selector == bytes4(keccak256("addToAllowlistReactive(address,address)"))) {
                    grantFound = true;
                }
            }
        }
        assertTrue(revokeFound, "revocation callback not emitted");
        assertFalse(grantFound, "new holder must NOT get addToAllowlist callback");
    }

    function test_mintStillTriggersMint() public {
        IReactive.LogRecord memory log = _buildMintLog(INSTITUTION, TOKEN_ID);

        vm.recordLogs();
        rsc.react(log);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Callback(uint256,address,uint64,bytes)")) {
                bytes memory payload = abi.decode(logs[i].data, (bytes));
                bytes4 selector = bytes4(payload);
                if (selector == bytes4(keccak256("addToAllowlistReactive(address,address)"))) {
                    found = true;
                }
            }
        }
        assertTrue(found, "addToAllowlist callback not emitted for mint");
    }

    function test_tierUpdatedForwardedOnMint() public {
        // Simulate a TierUpdated(institution, Gold) LogRecord from Base
        IReactive.LogRecord memory log = _buildTierUpdatedLog(INSTITUTION, uint8(IStableGate.Tier.Gold));

        vm.recordLogs();
        rsc.react(log);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Callback(uint256,address,uint64,bytes)")) {
                bytes memory payload = abi.decode(logs[i].data, (bytes));
                bytes4 selector = bytes4(payload);
                if (selector == bytes4(keccak256("setInstitutionTier(address,uint8)"))) {
                    found = true;
                    // Decode and verify tier value
                    (address inst, uint8 tier) = abi.decode(_stripSelector(payload), (address, uint8));
                    assertEq(inst, INSTITUTION, "institution matches");
                    assertEq(tier, uint8(IStableGate.Tier.Gold), "Gold tier forwarded");
                }
            }
        }
        assertTrue(found, "setInstitutionTier callback not emitted");
    }

    function test_callbackCountIncrements() public {
        rsc.react(_buildMintLog(address(0xA1), 1));
        rsc.react(_buildBurnLog(address(0xA2), 2));
        rsc.react(_buildTierUpdatedLog(address(0xA3), uint8(IStableGate.Tier.Silver)));
        assertEq(rsc.callbackCount(), 3);
    }

    function test_payloadEncodingRemoveFromAllowlist() public {
        IReactive.LogRecord memory log = _buildBurnLog(INSTITUTION, TOKEN_ID);

        vm.recordLogs();
        rsc.react(log);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Callback(uint256,address,uint64,bytes)")) {
                bytes memory payload = abi.decode(logs[i].data, (bytes));
                bytes4 selector = bytes4(payload);
                assertEq(
                    selector,
                    bytes4(keccak256("removeFromAllowlistReactive(address,address)")),
                    "selector matches removeFromAllowlistReactive(address,address)"
                );
            }
        }
    }

    function test_payloadEncodingSetTier() public {
        IReactive.LogRecord memory log = _buildTierUpdatedLog(INSTITUTION, uint8(IStableGate.Tier.Silver));

        vm.recordLogs();
        rsc.react(log);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Callback(uint256,address,uint64,bytes)")) {
                bytes memory payload = abi.decode(logs[i].data, (bytes));
                bytes4 selector = bytes4(payload);
                assertEq(
                    selector,
                    bytes4(keccak256("setInstitutionTier(address,uint8)")),
                    "selector matches setInstitutionTier(address,uint8)"
                );
            }
        }
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _buildMintLog(address recipient, uint256 tokenId)
        internal
        pure
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chain_id: 84532,
            _contract: MEMBERSHIP_NFT,
            topic_0: 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef,
            topic_1: 0, // from == address(0) → mint
            topic_2: uint256(uint160(recipient)),
            topic_3: tokenId,
            data: "",
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function _buildBurnLog(address holder, uint256 tokenId)
        internal
        pure
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chain_id: 84532,
            _contract: MEMBERSHIP_NFT,
            topic_0: 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef,
            topic_1: uint256(uint160(holder)), // from == holder
            topic_2: 0,                        // to == address(0) → burn
            topic_3: tokenId,
            data: "",
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function _buildTransferLog(address from, address to, uint256 tokenId)
        internal
        pure
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chain_id: 84532,
            _contract: MEMBERSHIP_NFT,
            topic_0: 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef,
            topic_1: uint256(uint160(from)),
            topic_2: uint256(uint160(to)),
            topic_3: tokenId,
            data: "",
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function _buildTierUpdatedLog(address institution, uint8 tier)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chain_id: 84532,
            _contract: MEMBERSHIP_NFT,
            topic_0: rsc.TIER_UPDATED_EVENT_TOPIC(),
            topic_1: uint256(uint160(institution)), // indexed institution
            topic_2: uint256(tier),                 // indexed tier value
            topic_3: 0,
            data: "",
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function _buildExpirySetLog(address institution, uint256 expiry)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chain_id: 84532,
            _contract: MEMBERSHIP_NFT,
            topic_0: rsc.EXPIRY_SET_EVENT_TOPIC(),
            topic_1: uint256(uint160(institution)), // indexed institution
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(expiry), // non-indexed uint256
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    /// @dev Strip the 4-byte selector from a payload and return the remaining bytes.
    function _stripSelector(bytes memory payload) internal pure returns (bytes memory) {
        bytes memory result = new bytes(payload.length - 4);
        for (uint256 i = 4; i < payload.length; i++) {
            result[i - 4] = payload[i];
        }
        return result;
    }

    // ─── ExpirySet Forwarding Tests ─────────────────────────────────────────

    function test_expirySetForwardedToHook() public {
        uint256 expiry = block.timestamp + 365 days;
        IReactive.LogRecord memory log = _buildExpirySetLog(INSTITUTION, expiry);

        vm.recordLogs();
        rsc.react(log);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Callback(uint256,address,uint64,bytes)")) {
                bytes memory payload = abi.decode(logs[i].data, (bytes));
                bytes4 selector = bytes4(payload);
                if (selector == bytes4(keccak256("setInstitutionExpiry(address,uint256)"))) {
                    found = true;
                }
            }
        }
        assertTrue(found, "setInstitutionExpiry callback not emitted");
    }

    function test_expiryPayloadEncoding() public {
        uint256 expiry = block.timestamp + 90 days;
        IReactive.LogRecord memory log = _buildExpirySetLog(INSTITUTION, expiry);

        vm.recordLogs();
        rsc.react(log);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Callback(uint256,address,uint64,bytes)")) {
                bytes memory payload = abi.decode(logs[i].data, (bytes));
                bytes4 selector = bytes4(payload);
                assertEq(
                    selector,
                    bytes4(keccak256("setInstitutionExpiry(address,uint256)")),
                    "selector matches"
                );
                (address inst, uint256 exp) = abi.decode(_stripSelector(payload), (address, uint256));
                assertEq(inst, INSTITUTION, "institution matches");
                assertEq(exp, expiry, "expiry matches");
            }
        }
    }

    function test_allThreeEventsOnMint() public {
        // Simulate the three events that fire on a mint with tier + expiry:
        // 1. Transfer(0 → institution) → addToAllowlistReactive
        // 2. TierUpdated(institution, Gold) → setInstitutionTier
        // 3. ExpirySet(institution, expiry) → setInstitutionExpiry

        uint256 expiry = block.timestamp + 365 days;

        vm.recordLogs();
        rsc.react(_buildMintLog(INSTITUTION, TOKEN_ID));
        rsc.react(_buildTierUpdatedLog(INSTITUTION, uint8(IStableGate.Tier.Gold)));
        rsc.react(_buildExpirySetLog(INSTITUTION, expiry));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(rsc.callbackCount(), 3, "three callbacks emitted");

        bool addFound;
        bool tierFound;
        bool expiryFound;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Callback(uint256,address,uint64,bytes)")) {
                bytes memory payload = abi.decode(logs[i].data, (bytes));
                bytes4 selector = bytes4(payload);
                if (selector == bytes4(keccak256("addToAllowlistReactive(address,address)"))) addFound = true;
                if (selector == bytes4(keccak256("setInstitutionTier(address,uint8)"))) tierFound = true;
                if (selector == bytes4(keccak256("setInstitutionExpiry(address,uint256)"))) expiryFound = true;
            }
        }
        assertTrue(addFound, "addToAllowlist callback");
        assertTrue(tierFound, "setInstitutionTier callback");
        assertTrue(expiryFound, "setInstitutionExpiry callback");
    }
}
