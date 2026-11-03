// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {ScriptReading} from "../src/lib/Script.sol";
import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";

contract ScriptTest is Test {
    using ScriptReading for uint256;
    using ScriptReading for bytes;

    bytes constant DATA =
        hex"0001ff02030405060708090a0b0c0d0e0f1044445555666677777777777777777777777777777778888888888888888888888888888888999999999999999999999aaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbc";

    function _testIter(uint256 curr, uint256 end) internal view {
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
        (u256, curr) = curr.nextU256();
        assertEq(u256, 0x6677777777777777777777777777777778888888888888888888888888888888);
        bytes32 b32;
        (b32, curr) = curr.nextBytes32();
        assertEq(b32, 0x999999999999999999999aaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbc);
    }

    function testMemoryIter() public {
        bytes memory data = DATA;
        (uint256 curr, uint256 end) = data.memoryIter();
        _testIter(curr, end);
    }

    function _calldataHarness(bytes calldata data) external {
        (uint256 curr, uint256 end) = data.calldataIter();
        _testIter(curr, end);
    }

    function testCalldataIter() public {
        this._calldataHarness(DATA);
    }

    function testNextRailInfo() public view {
        bytes32 initcodeHash = keccak256("initcode");
        address from = address(0x1111111111111111111111111111111111111111);
        address token = address(0x2222222222222222222222222222222222222222);
        address operator = address(0x3333333333333333333333333333333333333333);
        bytes4 extra = 0x44556677;
        bytes memory script = abi.encodePacked(initcodeHash, from, token, operator, extra, uint8(0xff));
        (uint256 curr, uint256 end) = script.memoryIter();
        (address rail, address f, address t, address o, uint256 next) = curr.nextRailInfo();
        assertEq(
            rail,
            LibClone.predictDeterministicAddress(
                initcodeHash, keccak256(abi.encodePacked(from, token, operator, extra)), address(this)
            )
        );
        assertEq(f, from);
        assertEq(t, token);
        assertEq(o, operator);
        assertEq(next, curr + 96);
        assertEq(end - next, 1);
    }
}
