// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {IExtsload} from "./interfaces/IExtsload.sol";

contract Extsload is IExtsload {
    function extsload(bytes32 slot) external view returns (bytes32) {
        assembly ("memory-safe") {
            mstore(0, sload(slot))
            return(0, 32)
        }
    }
}

