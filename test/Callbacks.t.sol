// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {FilecoinPayV2} from "../src/FilecoinPayV2.sol";
import {CREATE_RAIL} from "../src/lib/Permissions.sol";
import {FLAG_CALLBACK, RailId} from "../src/lib/RailId.sol";

contract CallbacksTest is Test {
    uint256 private constant NATIVE_TOKEN = 0;

    event SettleRailParams(RailId railId, uint256 prevSettledEpoch, uint256 settledUpTo, uint256 prevBalance, uint256 addsBalance);

    bytes internal mockScript;

    function settleRail(
        RailId railId,
        uint256 prevSettledEpoch,
        uint256 settledUpTo,
        uint256 prevBalance,
        uint256 addsBalance
    ) external returns (bytes memory script) {
        emit SettleRailParams(railId, prevSettledEpoch, settledUpTo, prevBalance, addsBalance);
        return mockScript;
    }

    function expectSettleRail(
        RailId railId,
        uint256 prevSettledEpoch,
        uint256 settledUpTo,
        uint256 prevBalance,
        uint256 addsBalance
    ) internal {
        vm.expectEmit(address(this));
        emit SettleRailParams(railId, prevSettledEpoch, settledUpTo, prevBalance, addsBalance);
    }

    function expectNoSettleRail() internal {
        vm.expectEmit(false, false, false, false, address(this), 0);
        emit SettleRailParams(RailId.wrap(0), 0, 0, 0, 0);
    }

    FilecoinPayV2 internal payments;

    function setUp() public {
        payments = new FilecoinPayV2();
    }

    function testCallback() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint32 nonce = FLAG_CALLBACK;

        vm.prank(alice);
        payments.authorize(address(this), CREATE_RAIL);

        uint256 createdAt = vm.getBlockNumber();
        RailId railId = payments.createRail(alice, bob, nonce, NATIVE_TOKEN);

        vm.roll(createdAt + 1);
        expectSettleRail(railId, createdAt, createdAt + 1, 0, 0);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);

        payments.modifyRate(alice, bob, nonce, NATIVE_TOKEN, 5);

        vm.roll(createdAt + 2);
        expectNoSettleRail();
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);

        vm.deal(alice, 500);
        vm.prank(alice);
        payments.deposit{value: 500}();
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 495);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 0);

        expectSettleRail(railId, createdAt + 1, createdAt + 2, 0, 5);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 495);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 0);
    }
}
