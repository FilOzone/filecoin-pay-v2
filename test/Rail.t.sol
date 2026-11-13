// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {stdError} from "forge-std/StdError.sol";
import {Test} from "forge-std/Test.sol";
import {IERC6909} from "forge-std/interfaces/IERC6909.sol";

import {ALL, CREATE_RAIL} from "../src/lib/Permissions.sol";
import {RailId, RailIdLibrary, StreamState} from "../src/lib/RailId.sol";
import {ScriptBuilder} from "../src/lib/Script.sol";
import {FilecoinPayV2} from "../src/FilecoinPayV2.sol";

contract RailTest is Test {
    using RailIdLibrary for address;
    using RailIdLibrary for FilecoinPayV2;
    using ScriptBuilder for bytes;

    FilecoinPayV2 internal payments;

    uint256 constant NATIVE_TOKEN = 0;

    function setUp() public {
        payments = new FilecoinPayV2();
    }

    function testCreate() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint32 nonce = 0;

        vm.expectRevert(abi.encodeWithSelector(FilecoinPayV2.Unauthorized.selector, alice, address(this)));
        payments.createRail(alice, bob, nonce, NATIVE_TOKEN);

        vm.prank(alice);
        vm.expectEmit(address(payments));
        emit IERC6909.OperatorSet(alice, address(this), false);
        payments.authorize(address(this), CREATE_RAIL);

        // operator(20) from(20) token(20) recipient(20) nonce(4)
        RailId expectedRailId = RailId.wrap(
            uint256(keccak256(abi.encodePacked(address(this), alice, address(uint160(NATIVE_TOKEN)), bob, nonce)))
        );
        assertEq(
            RailId.unwrap(expectedRailId),
            0x19dcc429a1c4e6bbb13cdf766b15979eb4541ab36709de42a8976b2db548e013,
            "rail id preimage layout changed"
        );
        vm.expectEmit(address(payments));
        emit FilecoinPayV2.RailCreated(alice, bob, address(this), NATIVE_TOKEN, expectedRailId, nonce);
        RailId rail = payments.createRail(alice, bob, nonce, NATIVE_TOKEN);
        assertEq(RailId.unwrap(rail), RailId.unwrap(expectedRailId));

        StreamState memory state = payments.getRail(rail);
        assertEq(state.incomingRate, 0);
        assertEq(state.settledUpTo, vm.getBlockNumber());
        assertEq(state.available, 0);

        vm.expectRevert(FilecoinPayV2.Exists.selector);
        payments.createRail(alice, bob, nonce, NATIVE_TOKEN);

        uint256 invalidToken = (1 << 160) | uint256(uint160(makeAddr("erc20")));
        vm.expectRevert(FilecoinPayV2.InvalidToken.selector);
        payments.createRail(alice, bob, nonce, invalidToken);
    }

    function testRate() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint32 nonce = 0;

        vm.expectRevert(FilecoinPayV2.RailNotCreated.selector);
        payments.modifyRate(alice, bob, nonce, NATIVE_TOKEN, 50);

        vm.prank(alice);
        vm.expectEmit(address(payments));
        emit IERC6909.OperatorSet(alice, address(this), false);
        payments.authorize(address(this), CREATE_RAIL);

        uint40 createdAt = uint40(vm.getBlockNumber());
        RailId rail = payments.createRail(alice, bob, nonce, NATIVE_TOKEN);

        StreamState memory state = payments.getRail(rail);
        assertEq(state.incomingRate, 0);
        assertEq(state.settledUpTo, createdAt);
        assertEq(state.available, 0);

        vm.roll(createdAt + 1);
        uint40 fiftyAt = uint40(vm.getBlockNumber());
        payments.modifyRate(alice, bob, nonce, NATIVE_TOKEN, 50);

        state = payments.getRail(rail);
        assertEq(state.incomingRate, 50);
        assertEq(state.settledUpTo, fiftyAt);
        assertEq(state.available, 0);

        vm.roll(fiftyAt + 1);
        uint256 settledUpTo = payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(settledUpTo, fiftyAt);

        state = payments.getRail(rail);
        assertEq(state.incomingRate, 50);
        assertEq(state.settledUpTo, fiftyAt);
        assertEq(state.available, 0);

        vm.deal(alice, 500);
        vm.prank(alice);
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(alice, address(0), alice, NATIVE_TOKEN, 500);
        payments.deposit{value: 500}();
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 450);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 0);

        state = payments.getRail(rail);
        assertEq(state.incomingRate, 50);
        assertEq(state.settledUpTo, fiftyAt);
        assertEq(state.available, 0);

        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(this), alice, bob, NATIVE_TOKEN, 50);
        settledUpTo = payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(settledUpTo, fiftyAt + 1);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 450);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 50);

        state = payments.getRail(rail);
        assertEq(state.incomingRate, 50);
        assertEq(state.settledUpTo, fiftyAt + 1);
        assertEq(state.available, 0);

        vm.roll(fiftyAt + 10);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 0);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 50);

        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(this), alice, bob, NATIVE_TOKEN, 450);
        payments.modifyRate(alice, bob, nonce, NATIVE_TOKEN, 0);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 0);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 500);

        state = payments.getRail(rail);
        assertEq(state.incomingRate, 0);
        assertEq(state.settledUpTo, fiftyAt + 10);
        assertEq(state.available, 0);
    }

    function testCreateRailScript() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint32 nonce = 7;

        vm.deal(alice, 500);
        vm.prank(alice);
        payments.deposit{value: 500}();

        bytes memory script = ScriptBuilder.newScript().createRail(alice, bob, nonce).increaseRate(5).lock(100).build();

        vm.expectRevert(abi.encodeWithSelector(FilecoinPayV2.Unauthorized.selector, alice, address(this)));
        payments.executeScript(script);

        vm.prank(alice);
        payments.authorize(address(this), CREATE_RAIL);

        vm.expectRevert(abi.encodeWithSelector(FilecoinPayV2.Unauthorized.selector, alice, address(this)));
        payments.executeScript(ALL & ~CREATE_RAIL, script);

        RailId expectedRailId = RailIdLibrary.getRailId(address(this).deriveRail(alice, bob, NATIVE_TOKEN, nonce));
        vm.expectEmit(address(payments));
        emit FilecoinPayV2.RailCreated(alice, bob, address(this), NATIVE_TOKEN, expectedRailId, nonce);
        payments.executeScript(script);

        StreamState memory state = payments.getRail(expectedRailId);
        assertEq(state.incomingRate, 5, "the rail ops after it address the rail it created");
        assertEq(state.available, 100);
        assertEq(state.settledUpTo, vm.getBlockNumber());
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 400);

        vm.expectRevert(FilecoinPayV2.Exists.selector);
        payments.executeScript(script);
    }

    function testSetRailScript() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint32 nonce = 3;

        vm.prank(alice);
        payments.authorize(address(this), CREATE_RAIL);
        RailId rail = payments.createRail(alice, bob, nonce, NATIVE_TOKEN);

        vm.deal(alice, 500);
        vm.prank(alice);
        payments.deposit{value: 500}();

        // the operator picks up a rail it created in an earlier transaction
        bytes memory script = ScriptBuilder.newScript().setRail(alice, bob, nonce).lock(100).setRate(5).build();
        payments.executeScript(script);

        StreamState memory state = payments.getRail(rail);
        assertEq(state.available, 100, "the rail ops after it address the rail it named");
        assertEq(state.incomingRate, 5);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 400);

        // deriving from the caller keeps SETRAIL off rails it does not operate
        bytes memory foreign = ScriptBuilder.newScript().setRail(alice, bob, nonce + 1).lock(100).build();
        vm.expectRevert(FilecoinPayV2.RailNotCreated.selector);
        payments.executeScript(foreign);
    }

    function testTransferAllWithDrain() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");

        uint32 nonce = 0;

        vm.prank(alice);
        payments.authorize(address(this), CREATE_RAIL);
        payments.createRail(alice, bob, nonce, NATIVE_TOKEN);

        vm.deal(alice, 500);
        vm.prank(alice);
        payments.deposit{value: 500}();

        uint256 fiftyAt = vm.getBlockNumber();
        payments.modifyRate(alice, bob, nonce, NATIVE_TOKEN, 50);

        vm.roll(fiftyAt + 2);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 400);

        bytes memory script = ScriptBuilder.newScript().transferAll(carol).build();
        vm.prank(alice);
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(alice, alice, carol, NATIVE_TOKEN, 400);
        payments.executeScript(script);

        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 0);
        assertEq(payments.balanceOf(carol, NATIVE_TOKEN), 400, "the sweep leaves what the rail accrued");

        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(this), alice, bob, NATIVE_TOKEN, 100);
        assertEq(payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN), fiftyAt + 2);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 100);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 0);
    }

    function testRateTwiceInOneBlock() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint32 nonce = 0;

        vm.prank(alice);
        payments.authorize(address(this), CREATE_RAIL);
        RailId rail = payments.createRail(alice, bob, nonce, NATIVE_TOKEN);

        vm.deal(alice, 500);
        vm.prank(alice);
        payments.deposit{value: 500}();

        uint256 fiftyAt = vm.getBlockNumber();
        payments.modifyRate(alice, bob, nonce, NATIVE_TOKEN, 50);
        payments.modifyRate(alice, bob, nonce, NATIVE_TOKEN, 70);

        assertEq(payments.getRail(rail).incomingRate, 70);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 500);

        vm.roll(fiftyAt + 1);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 430, "the payer drains at the rate set last");
    }

    function testSettleRailNotCreated() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint32 nonce = 0;

        vm.expectRevert(FilecoinPayV2.RailNotCreated.selector);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);

        // the dispatcher starts on auth.token 0, the native token
        bytes memory script = ScriptBuilder.newScript().settleRail(alice, bob, nonce, address(this)).build();
        vm.expectRevert(FilecoinPayV2.RailNotCreated.selector);
        payments.executeScript(script);
    }

    function testLock() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint32 nonce = 0;

        vm.expectRevert(FilecoinPayV2.RailNotCreated.selector);
        payments.lock(alice, bob, nonce, NATIVE_TOKEN, 50);

        vm.expectRevert(FilecoinPayV2.RailNotCreated.selector);
        payments.unlock(alice, bob, nonce, NATIVE_TOKEN, 50);

        vm.prank(alice);
        vm.expectEmit(address(payments));
        emit IERC6909.OperatorSet(alice, address(this), false);
        payments.authorize(address(this), CREATE_RAIL);

        uint40 createdAt = uint40(vm.getBlockNumber());
        RailId rail = payments.createRail(alice, bob, nonce, NATIVE_TOKEN);

        StreamState memory state = payments.getRail(rail);
        assertEq(state.incomingRate, 0);
        assertEq(state.settledUpTo, createdAt);
        assertEq(state.available, 0);

        vm.expectRevert(FilecoinPayV2.InsufficientBalance.selector);
        payments.lock(alice, bob, nonce, NATIVE_TOKEN, 50);

        vm.deal(alice, 500);
        vm.prank(alice);
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(alice, address(0), alice, NATIVE_TOKEN, 500);
        payments.deposit{value: 500}();
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 500);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 0);

        payments.lock(alice, bob, nonce, NATIVE_TOKEN, 50);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 450);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 0);

        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(this), alice, bob, NATIVE_TOKEN, 25);
        payments.disburse(alice, bob, nonce, NATIVE_TOKEN, 25);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 450);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 25);

        vm.expectRevert(stdError.arithmeticError);
        payments.unlock(alice, bob, nonce, NATIVE_TOKEN, 50);

        payments.unlock(alice, bob, nonce, NATIVE_TOKEN, 25);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 475);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 25);
    }

    function testDebt() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint32 nonce = 0;

        vm.deal(alice, 500);
        vm.prank(alice);
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(alice, address(0), alice, NATIVE_TOKEN, 100);
        payments.deposit{value: 100}();
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 100);

        vm.prank(alice);
        vm.expectEmit(address(payments));
        emit IERC6909.OperatorSet(alice, address(this), false);
        payments.authorize(address(this), CREATE_RAIL);

        RailId expectedRailId = RailIdLibrary.getRailId(address(this).deriveRail(alice, bob, NATIVE_TOKEN, nonce));
        emit FilecoinPayV2.RailCreated(alice, bob, address(this), NATIVE_TOKEN, expectedRailId, nonce);
        RailId railId = payments.createRail(alice, bob, nonce, NATIVE_TOKEN);
        assertEq(RailId.unwrap(railId), RailId.unwrap(expectedRailId));

        uint256 fiftyAt = vm.getBlockNumber();
        payments.modifyRate(alice, bob, nonce, NATIVE_TOKEN, 40);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 100);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 0);

        payments.lock(alice, bob, nonce, NATIVE_TOKEN, 30);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 70);

        vm.roll(fiftyAt + 1);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 30);

        vm.roll(fiftyAt + 2);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 0);

        vm.expectRevert(FilecoinPayV2.Behind.selector);
        payments.modifyRate(alice, bob, nonce, NATIVE_TOKEN, 5);

        vm.expectRevert(FilecoinPayV2.InsufficientBalance.selector);
        payments.lock(alice, bob, nonce, NATIVE_TOKEN, 5);

        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(this), alice, bob, NATIVE_TOKEN, 5);
        payments.disburse(alice, bob, nonce, NATIVE_TOKEN, 5);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 5);

        payments.unlock(alice, bob, nonce, NATIVE_TOKEN, 20);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 10);

        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(this), alice, bob, NATIVE_TOKEN, 80);
        payments.modifyRate(alice, bob, nonce, NATIVE_TOKEN, 5);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 10);

        vm.roll(fiftyAt + 3);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 5);

        vm.roll(fiftyAt + 4);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 0);

        vm.roll(fiftyAt + 5);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 0);

        // settling covers two of the three blocks, and the lockup covers the third exactly
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(this), alice, bob, NATIVE_TOKEN, 10);
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(this), alice, bob, NATIVE_TOKEN, 5);
        payments.terminateRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 0, "the lockup went to the debt, not back");
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 100, "every deposited attoFIL reached bob");
    }

    function testTerminateSplitsLockupBetweenDebtAndRefund() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint32 nonce = 0;

        vm.prank(alice);
        payments.authorize(address(this), CREATE_RAIL);
        RailId rail = payments.createRail(alice, bob, nonce, NATIVE_TOKEN);

        vm.deal(alice, 300);
        vm.prank(alice);
        payments.deposit{value: 300}();

        uint256 start = vm.getBlockNumber();
        payments.modifyRate(alice, bob, nonce, NATIVE_TOKEN, 50);
        payments.lock(alice, bob, nonce, NATIVE_TOKEN, 150);

        // 150 funds three blocks, so the fourth is one block of debt against a lockup of 150
        vm.roll(start + 4);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 0);

        payments.terminateRail(address(this), alice, bob, nonce, NATIVE_TOKEN);

        assertEq(payments.getRail(rail).settledUpTo, 0, "the rail is gone");
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 200, "three blocks settled and one came out of the lockup");
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 100, "the lockup the debt did not need");
    }

    function testTerminateForgivesDebtBeyondLockup() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint32 nonce = 0;

        vm.prank(alice);
        payments.authorize(address(this), CREATE_RAIL);
        payments.createRail(alice, bob, nonce, NATIVE_TOKEN);

        vm.deal(alice, 300);
        vm.prank(alice);
        payments.deposit{value: 300}();

        uint256 start = vm.getBlockNumber();
        payments.modifyRate(alice, bob, nonce, NATIVE_TOKEN, 50);
        payments.lock(alice, bob, nonce, NATIVE_TOKEN, 20);

        // 280 funds five whole blocks, leaving three owed against a lockup of 20
        vm.roll(start + 8);
        payments.terminateRail(address(this), alice, bob, nonce, NATIVE_TOKEN);

        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 270, "250 settled plus the whole lockup");
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 30, "what no whole block could settle stays with the payer");
    }

    function testTerminateRailScript() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint32 nonce = 5;

        vm.prank(alice);
        payments.authorize(address(this), CREATE_RAIL);
        RailId rail = payments.createRail(alice, bob, nonce, NATIVE_TOKEN);

        vm.deal(alice, 500);
        vm.prank(alice);
        payments.deposit{value: 500}();

        uint256 start = vm.getBlockNumber();
        payments.modifyRate(alice, bob, nonce, NATIVE_TOKEN, 50);
        payments.lock(alice, bob, nonce, NATIVE_TOKEN, 100);

        vm.roll(start + 2);
        bytes memory script = ScriptBuilder.newScript().setRail(alice, bob, nonce).terminateRail().build();

        vm.expectRevert(abi.encodeWithSelector(FilecoinPayV2.Unauthorized.selector, address(this), address(this)));
        payments.executeScript(ALL & ~CREATE_RAIL, script);

        payments.executeScript(script);

        assertEq(payments.getRail(rail).settledUpTo, 0, "the operator ended the rail its own identity derives");
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 100, "two blocks at 50");
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 400, "the lockup owed nothing");
    }

    function testTerminateRailByScript() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");

        uint32 nonce = 9;

        vm.prank(alice);
        payments.authorize(address(this), CREATE_RAIL);
        RailId rail = payments.createRail(alice, bob, nonce, NATIVE_TOKEN);

        vm.deal(alice, 500);
        vm.prank(alice);
        payments.deposit{value: 500}();

        uint256 start = vm.getBlockNumber();
        payments.modifyRate(alice, bob, nonce, NATIVE_TOKEN, 50);

        bytes memory script =
            ScriptBuilder.newScript().setRail(alice, bob, nonce).terminateRailBy(address(this)).build();

        // the op derives the rail from the payer the script authenticated as, which carol is not
        vm.prank(carol);
        vm.expectRevert(FilecoinPayV2.RailNotCreated.selector);
        payments.executeScript(script);

        vm.roll(start + 2);
        vm.prank(alice);
        payments.executeScript(script);

        assertEq(payments.getRail(rail).settledUpTo, 0, "the payer ended it without the operator");
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 100);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 400);
    }
}
