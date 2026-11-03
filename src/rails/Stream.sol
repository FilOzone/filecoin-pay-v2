// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {IRailV2} from "../interfaces/IRail.sol";
import {TRANSFERALL} from "../lib/FilecoinPayOps.sol";

// unconditionally forwards all balance to recipient
contract Stream is IRailV2 {
    bytes20 private immutable RECIPIENT;

    constructor(address recipient) {
        RECIPIENT = bytes20(recipient);
    }

    function settleRail(
        uint256,
        /*prevSettledEpoch*/
        uint256,
        /*settledUpTo*/
        uint256,
        /*prevBalance*/
        uint256 /*addsBalance*/
    )
        external
        view
        returns (
            bytes memory /*script*/
        )
    {
        bytes20 recipient = RECIPIENT;
        assembly ("memory-safe") {
            mstore(0, 32)
            mstore(32, 21)
            mstore8(64, TRANSFERALL)
            mstore(65, recipient)
            return(0, 85)
        }
    }
}
