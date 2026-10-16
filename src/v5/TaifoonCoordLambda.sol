// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITransitionLambda} from "./TaifoonProtocolVerifier.sol";

/// @title TaifoonCoordLambda — the lambda of the coordination layer's own protocol, `taifoon_coord`
/// @notice One sale of the coordination layer walks twelve hops (offer_in → classify → listed → hired → delivered →
///         graded → settled → legs → accrued → split → paid → recorded) and every hop ends ok · held · refunded ·
///         failed · missing (the coord layer's packages/resale/core/sale-run.mjs, _ONE_SALE_RUN_v1_). In the superroot a
///         sale is one order of the protocol `taifoon_coord` (order key = the sale key) whose states are named
///         `<hop>:<outcome>`; this contract is the rule the verifier applies to every move of that order:
///           - a state must be one of the 60 words of the vocabulary;
///           - the first move of a sale may start at any hop (paths start at different hops: a wall sale at offer_in,
///             a kept wall at listed, a usage sale at classify, a bridge fill at hired);
///           - the same hop may move only as the writer's OUTCOME_MOVES allow (ok → refunded; held → ok | refunded |
///             failed; failed → ok | held | refunded; missing → any; refunded → nothing);
///           - a different hop is always a move of the path (the order of hops on a path is the writer's PATH_STEPS and
///             is attested in the payload, not re-derived here).
///         Kinds are not restricted: a coord step is attested (1) by the vault; a chain-side step the lanes observe
///         (0) is the same word; a grade produced from a decision (2) is the same word.
contract TaifoonCoordLambda is ITransitionLambda {
    bytes32 public constant PROTOCOL_ID = keccak256("taifoon_coord");

    string[12] public HOPS = ["offer_in", "classify", "listed", "hired", "delivered", "graded", "settled", "legs", "accrued", "split", "paid", "recorded"];
    string[5] public OUTCOMES = ["ok", "held", "refunded", "failed", "missing"];

    /// keccak("<hop>:<outcome>") → 0x80 | hop << 3 | outcome  (0 = not a word)
    mapping(bytes32 => uint8) public codeOf;

    uint8 private constant OK = 0;
    uint8 private constant HELD = 1;
    uint8 private constant REFUNDED = 2;
    uint8 private constant FAILED = 3;
    uint8 private constant MISSING = 4;

    constructor() {
        unchecked {
            for (uint8 h = 0; h < 12; ++h) {
                for (uint8 o = 0; o < 5; ++o) {
                    codeOf[keccak256(abi.encodePacked(HOPS[h], ":", OUTCOMES[o]))] = uint8(0x80) | (h << 3) | o;
                }
            }
        }
    }

    /// The state name of a hop and an outcome, as the producer hashes it (`name_hash("settled:ok")`).
    function stateOf(string calldata hop, string calldata outcome) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(hop, ":", outcome));
    }

    function isValidMove(bytes32 protocolId, bytes32 fromState, bytes32 toState, uint8) external view returns (bool) {
        if (protocolId != PROTOCOL_ID) return false;
        uint8 t = codeOf[toState];
        if (t == 0) return false;
        if (fromState == bytes32(0)) return true;
        uint8 f = codeOf[fromState];
        if (f == 0) return false;
        uint8 fh = (f >> 3) & 0x0f;
        uint8 th = (t >> 3) & 0x0f;
        if (fh != th) return true;
        uint8 fo = f & 0x07;
        uint8 to = t & 0x07;
        if (fo == OK) return to == REFUNDED;
        if (fo == HELD) return to == OK || to == REFUNDED || to == FAILED;
        if (fo == FAILED) return to == OK || to == HELD || to == REFUNDED;
        if (fo == MISSING) return to != MISSING;
        return false; // refunded: terminal
    }
}
