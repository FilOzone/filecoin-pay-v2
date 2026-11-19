// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {stdError} from "forge-std/StdError.sol";
import {Test} from "forge-std/Test.sol";
import {IERC6909} from "forge-std/interfaces/IERC6909.sol";

import {FilecoinPayV2} from "../src/FilecoinPayV2.sol";
import {CREATE_RAIL} from "../src/lib/Permissions.sol";
import {newScript} from "../src/lib/Script.sol";
import {FLAG_CALLBACK, RailId, RailIdLibrary} from "../src/lib/RailId.sol";
import {Checkpoint, UserLibrary} from "../src/lib/User.sol";

contract CallbacksTest is Test {
    using RailIdLibrary for FilecoinPayV2;
    using UserLibrary for FilecoinPayV2;

    uint256 private constant NATIVE_TOKEN = 0;

    event SettleRailParams(
        RailId railId, uint256 prevSettledEpoch, uint256 settledUpTo, uint256 prevBalance, uint256 addsBalance
    );

    bytes internal mockScript;
    /// @dev a script that settles the rail again re-enters this callback: hand such a one over once
    bool internal oneShot;

    function settleRail(
        RailId railId,
        uint256 prevSettledEpoch,
        uint256 settledUpTo,
        uint256 prevBalance,
        uint256 addsBalance
    ) external returns (bytes memory script) {
        emit SettleRailParams(railId, prevSettledEpoch, settledUpTo, prevBalance, addsBalance);
        script = mockScript;
        if (oneShot) {
            mockScript = "";
        }
    }

    function expectSettleRail(
        RailId railId,
        uint256 prevSettledEpoch,
        uint256 settledUpTo,
        uint256 prevBalance,
        uint256 addsBalance
    ) internal {
        vm.expectEmit(address(payments));
        emit FilecoinPayV2.RailSettled(railId, settledUpTo, addsBalance);
        vm.expectEmit(address(this));
        emit SettleRailParams(railId, prevSettledEpoch, settledUpTo, prevBalance, addsBalance);
    }

    function expectRateSet(RailId railId, uint88 rate) internal {
        vm.expectEmit(address(payments));
        emit FilecoinPayV2.RailRateSet(railId, rate);
    }

    function expectNoSettleRail() internal {
        vm.expectEmit(false, false, false, false, address(this), 0);
        emit SettleRailParams(RailId.wrap(0), 0, 0, 0, 0);
    }

    function expectNativeTransfer(address from, address to, uint256 amount) internal {
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(this), from, to, NATIVE_TOKEN, amount);
    }

    FilecoinPayV2 internal payments;

    function setUp() public {
        payments = new FilecoinPayV2();
    }

    function testRateOps() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint64 nonce = FLAG_CALLBACK;

        vm.prank(alice);
        vm.expectEmit(address(payments));
        emit FilecoinPayV2.Authorized(alice, address(this), CREATE_RAIL);
        payments.authorize(address(this), CREATE_RAIL);

        uint256 createdAt = vm.getBlockNumber();
        RailId railId = payments.createRail(alice, bob, nonce, NATIVE_TOKEN);

        vm.deal(alice, 1000);
        vm.prank(alice);
        payments.deposit{value: 1000}();

        // the settling rail is the script's authorization, so neither op names it
        vm.roll(createdAt + 1);
        mockScript = newScript().increaseRate(10).build();
        expectSettleRail(railId, createdAt, createdAt + 1, 0, 0);
        expectRateSet(railId, 10);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(payments.getRail(railId).incomingRate, 10);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 1000);

        vm.roll(createdAt + 3);
        mockScript = newScript().decreaseRate(4).build();
        expectSettleRail(railId, createdAt + 1, createdAt + 3, 0, 20);
        expectRateSet(railId, 6);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(payments.getRail(railId).incomingRate, 6);
        assertEq(payments.getRail(railId).available, 20);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 980);

        vm.roll(createdAt + 4);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 974);

        mockScript = newScript().decreaseRate(7).build();
        vm.expectRevert(stdError.arithmeticError);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
    }

    function testSetOps() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint64 nonce = FLAG_CALLBACK;

        vm.prank(alice);
        vm.expectEmit(address(payments));
        emit FilecoinPayV2.Authorized(alice, address(this), CREATE_RAIL);
        payments.authorize(address(this), CREATE_RAIL);

        uint256 createdAt = vm.getBlockNumber();
        RailId railId = payments.createRail(alice, bob, nonce, NATIVE_TOKEN);

        vm.deal(alice, 1000);
        vm.prank(alice);
        payments.deposit{value: 1000}();

        vm.roll(createdAt + 1);
        mockScript = newScript().setRate(10).setAvailable(100).build();
        expectSettleRail(railId, createdAt, createdAt + 1, 0, 0);
        expectRateSet(railId, 10);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(payments.getRail(railId).incomingRate, 10);
        assertEq(payments.getRail(railId).available, 100);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 900);

        // settling adds 2 blocks at 10 to the lockup, which the target replaces rather than adds to
        vm.roll(createdAt + 3);
        mockScript = newScript().setRate(4).setAvailable(50).build();
        expectSettleRail(railId, createdAt + 1, createdAt + 3, 100, 20);
        expectRateSet(railId, 4);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(payments.getRail(railId).incomingRate, 4, "the rate is set, not adjusted");
        assertEq(payments.getRail(railId).available, 50, "the lockup is set, not adjusted");
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 950, "unlocking 70 refunds what the target gave up");

        // the script runs after the settle it belongs to, so the target counts what that settle locked
        vm.roll(createdAt + 4);
        mockScript = newScript().setAvailable(0).build();
        expectSettleRail(railId, createdAt + 3, createdAt + 4, 50, 4);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(payments.getRail(railId).available, 0);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 1000);
    }

    function testCallback() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint64 nonce = FLAG_CALLBACK;

        vm.prank(alice);
        vm.expectEmit(address(payments));
        emit FilecoinPayV2.Authorized(alice, address(this), CREATE_RAIL);
        payments.authorize(address(this), CREATE_RAIL);

        uint256 createdAt = vm.getBlockNumber();
        RailId railId = payments.createRail(alice, bob, nonce, NATIVE_TOKEN);

        vm.roll(createdAt + 1);
        expectSettleRail(railId, createdAt, createdAt + 1, 0, 0);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);

        expectRateSet(railId, 5);
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

        vm.roll(createdAt + 4);
        expectSettleRail(railId, createdAt + 2, createdAt + 4, 5, 10);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 485);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 0);

        vm.roll(createdAt + 5);
        mockScript = newScript().unlock(5).disburseAll().build();
        expectSettleRail(railId, createdAt + 4, createdAt + 5, 15, 5);
        expectNativeTransfer(alice, bob, 15);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 485);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 15);

        vm.roll(createdAt + 6);
        mockScript = newScript().disburse(2).build();
        expectSettleRail(railId, createdAt + 5, createdAt + 6, 0, 5);
        expectNativeTransfer(alice, bob, 2);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 17);
        assertEq(payments.getRail(railId).available, 3);
    }

    /// @dev the callback funds the payer and settles the rail again, so the returned epoch falls behind
    function testTerminateAfterCallbackSettlesAgain() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint64 nonce = FLAG_CALLBACK;

        vm.prank(alice);
        payments.authorize(address(this), CREATE_RAIL);

        uint256 createdAt = vm.getBlockNumber();
        RailId railId = payments.createRail(alice, bob, nonce, NATIVE_TOKEN);

        vm.deal(alice, 100);
        vm.prank(alice);
        payments.deposit{value: 100}();
        payments.modifyRate(alice, bob, nonce, NATIVE_TOKEN, 10);

        // the operator holds what the script hands the payer
        vm.deal(address(this), 100);
        payments.deposit{value: 100}();

        // 20 blocks at 10 outruns the 100 deposited, so the rail settles to createdAt + 10
        vm.roll(createdAt + 20);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 0);

        oneShot = true;
        mockScript = newScript().transfer(alice, 100).setRate(10).build();
        payments.terminateRail(address(this), alice, bob, nonce, NATIVE_TOKEN);

        Checkpoint memory scratch = payments.latest(alice, NATIVE_TOKEN);
        assertEq(scratch.modifiedEpoch, createdAt + 20, "the epoch the callback settled to");
        assertEq(scratch.drainRate, 0, "the terminated rate is gone");
        assertEq(payments.getRail(railId).settledUpTo, 0, "the rail is gone");

        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 0, "the callback left no debt");
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 200, "so the whole lockup came back");
        assertEq(address(payments).balance, 200, "no attoFIL was minted");
    }

    /// @dev the callback's rate change on another rail charges the payer past this rail's settle point
    function testTerminateAfterCallbackRollsThePayerForward() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint64 nonce = FLAG_CALLBACK;
        uint64 other = 1;

        vm.prank(alice);
        payments.authorize(address(this), CREATE_RAIL);

        uint256 createdAt = vm.getBlockNumber();
        RailId railId = payments.createRail(alice, bob, nonce, NATIVE_TOKEN);
        payments.createRail(alice, bob, other, NATIVE_TOKEN);

        vm.deal(alice, 100);
        vm.prank(alice);
        payments.deposit{value: 100}();
        payments.modifyRate(alice, bob, nonce, NATIVE_TOKEN, 10);
        payments.modifyRate(alice, bob, other, NATIVE_TOKEN, 5);

        vm.deal(address(this), 200);
        payments.deposit{value: 200}();

        // 100 at 15 a block runs out at createdAt + 6, where this rail stops settling
        vm.roll(createdAt + 20);
        mockScript = newScript().transfer(alice, 200).setRail(alice, bob, other).setRate(5).build();
        payments.terminateRail(address(this), alice, bob, nonce, NATIVE_TOKEN);

        Checkpoint memory scratch = payments.latest(alice, NATIVE_TOKEN);
        assertEq(scratch.modifiedEpoch, createdAt + 20, "the epoch the other rail's rate stamped");
        assertEq(scratch.drainRate, 5, "only the other rail still drains");
        assertEq(payments.getRail(railId).settledUpTo, 0, "the rail is gone");

        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 0, "the rails drained what the script gave");
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 160, "the other rail's 100 and this lockup's 60");
    }
}
