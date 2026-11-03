pragma solidity ^0.8.37;

import {ScriptIterator, ScriptReading} from "../src/lib/Script.sol";
import {Test} from "forge-std/Test.sol";

contract ScriptTest is Test {
    using ScriptReading for ScriptIterator;
    using ScriptReading for bytes;

    bytes constant DATA = hex"0001ff02030405060708090a0b0c0d0e0f1044445555666677777777777777777777777777777778888888888888888888888888888888999999999999999999999aaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbc";

    function _testIter(ScriptIterator memory iter) internal view {
        assertEq(iter.end - iter.curr, DATA.length);
        uint256 u256 = iter.nextByte();
        assertEq(u256, 0);
        u256 = iter.nextByte();
        assertEq(u256, 1);
        u256 = iter.nextByte();
        assertEq(u256, 255);
        address who = iter.nextAddress();
        assertEq(who, 0x02030405060708090A0B0C0d0E0F104444555566);
        u256 = iter.nextU256();
        assertEq(u256, 0x6677777777777777777777777777777778888888888888888888888888888888);
        bytes32 b32 = iter.nextBytes32();
        assertEq(b32, 0x999999999999999999999aaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbc);
    }

    function testMemoryIter() public {
        bytes memory data = DATA;
        _testIter(data.memoryIter());
    }

    function _calldataHarness(bytes calldata data) external {
        _testIter(data.calldataIter());
    }

    function testCalldataIter() public {
        this._calldataHarness(DATA);
    }
}
