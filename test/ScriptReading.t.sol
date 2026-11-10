// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {ScriptReading} from "../src/lib/ScriptReading.sol";
import {Test} from "forge-std/Test.sol";

contract ScriptReadingTest is Test {
    using ScriptReading for uint256;
    using ScriptReading for bytes;

    bytes constant DATA =
        hex"0001ff02030405060708090a0b0c0d0e0f1044445555666677777777777777777777777777777778888888888888888888888888888888999999999999999999999aaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbc";

    function _testIter(uint256 curr, uint256 end) internal pure {
        assertEq(end - curr, DATA.length);
        uint256 u256;
        (u256, curr) = curr.nextByte();
        assertEq(u256, 0);
        (u256, curr) = curr.nextByte();
        assertEq(u256, 1);
        (u256, curr) = curr.nextByte();
        assertEq(u256, 255);
        address who;
        (who, curr) = curr.nextAddress();
        assertEq(who, 0x02030405060708090A0B0C0d0E0F104444555566);
        uint128 u128;
        (u128, curr) = curr.nextU128();
        assertEq(u128, 0x66777777777777777777777777777777);
        (u128, curr) = curr.nextU128();
        assertEq(u128, 0x78888888888888888888888888888888);
        uint32 u32;
        (u32, curr) = curr.nextU32();
        assertEq(u32, 0x99999999);
    }

    function testMemoryIter() public pure {
        bytes memory data = DATA;
        (uint256 curr, uint256 end) = data.memoryIter();
        _testIter(curr, end);
    }

    function _calldataHarness(bytes calldata data) external pure {
        (uint256 curr, uint256 end) = data.calldataIter();
        _testIter(curr, end);
    }

    function testCalldataIter() public view {
        this._calldataHarness(DATA);
    }
}
