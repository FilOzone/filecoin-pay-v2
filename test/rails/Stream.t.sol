// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {TRANSFERALL} from "../../src/lib/FilecoinPayOps.sol";
import {Stream} from "../../src/rails/Stream.sol";

contract StreamTest is Test {
    address private constant RECIPIENT = 0x111122223333444455556666777788889999aAaa;
    Stream private stream;

    function setUp() public {
        stream = new Stream(RECIPIENT);
    }

    function testTransfersAll() public view {
        bytes memory script = stream.settleRail(1234, 5678, 10 ** 18, 5 * 10 ** 18);
        assertEq(script, abi.encodePacked(uint8(TRANSFERALL), RECIPIENT));
    }
}
