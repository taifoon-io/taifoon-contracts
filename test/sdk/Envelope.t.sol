// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TaifoonEnvelope} from "../../src/lib/TaifoonEnvelope.sol";

/// The envelope vectors coord-core and the TS SDK pass (test/fixtures/vectors/digests.json, derived from
/// taifoon-io/coord lang/vectors/envelopes.json): the genome digest and the payload digest hash the same on chain.
contract EnvelopeVectorsTest is Test {
    function test_vectors_hash_like_coord_core() public view {
        string memory json = vm.readFile("test/fixtures/vectors/digests.json");
        uint256 n = vm.parseJsonUint(json, ".n");
        assertGe(n, 40);
        for (uint256 i = 0; i < n; i++) {
            string memory k = string.concat(".cases[", vm.toString(i), "]");
            bytes memory g = bytes(vm.parseJsonString(json, string.concat(k, ".genome_canonical")));
            bytes32 gd = vm.parseJsonBytes32(json, string.concat(k, ".genome_digest"));
            assertEq(TaifoonEnvelope.digestOf(g), gd, "genome digest");
            bytes memory p = bytes(vm.parseJsonString(json, string.concat(k, ".payload")));
            bytes32 pd = vm.parseJsonBytes32(json, string.concat(k, ".payload_digest"));
            TaifoonEnvelope.requireDigest(p, pd);
        }
    }

    function test_requireDigest_reverts_on_mismatch() public {
        vm.expectRevert();
        this.callRequire(bytes("x"), bytes32(0));
    }

    function callRequire(bytes calldata b, bytes32 d) external pure { TaifoonEnvelope.requireDigest(b, d); }
}
