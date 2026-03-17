// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AllowlistReactiveContract} from "../src/AllowlistReactiveContract.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

contract AllowlistReactiveContractTest is Test {
    AllowlistReactiveContract rsc;

    address constant MEMBERSHIP_NFT = address(0x1111);
    address constant HOOK_CONTRACT = address(0x2222);
    address constant INSTITUTION = address(0xBEEF);
    uint256 constant TOKEN_ID = 1;

    function setUp() public {
        // On local Anvil/Forge chain, 0x...fffFfF has no code → vm flag = true (ReactVM mode).
        // Constructor skips subscribe() which is correct — no system contract to call.
        rsc = new AllowlistReactiveContract(MEMBERSHIP_NFT, HOOK_CONTRACT);
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
        emit AllowlistReactiveContract.CallbackTriggered(INSTITUTION, 1);

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

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _buildMintLog(address recipient, uint256 tokenId)
        internal
        pure
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chain_id: 1301,
            _contract: MEMBERSHIP_NFT,
            topic_0: 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef,
            topic_1: 0, // from == address(0) → mint
            topic_2: uint256(uint160(recipient)), // to == recipient
            topic_3: tokenId,
            data: "",
            block_number: 100,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }
}
