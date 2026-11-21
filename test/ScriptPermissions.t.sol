// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;


import {
    ALL,
    AUTHORIZE,
    CREATE_RAIL,
    DEPOSIT,
    DEPOSIT_TO,
    Permissions,
    TRANSFER,
    WITHDRAW,
    WITHDRAW_TO
} from "../src/lib/Permissions.sol";
import {RailId} from "../src/lib/RailId.sol";
import {ScriptBuilder, newScript} from "../src/lib/Script.sol";
import {UserLibrary} from "../src/lib/User.sol";
import {FilecoinPayV2} from "../src/FilecoinPayV2.sol";

import {FilecoinPayTest} from "./FilecoinPayTest.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev the dispatcher reads what an op requires out of one packed table, so every entry needs a case
contract ScriptPermissionsTest is FilecoinPayTest {
    using UserLibrary for FilecoinPayV2;

    address private constant ALICE = 0xA11cea11CEA11CEA11cEa11CeA11ceA11CEA11Ce;
    address private constant BOB = 0xb0bB0bB0Bb0Bb0bB0Bb0bb0bb0bB0BB0Bb0BB0Bb;
    address private constant CAROL = 0xCA401ca401Ca401CA401CA401cA401CA401ca401;

    function setUp() public override {
        super.setUp();

        token.mint(ALICE, 1000);
        token.mint(BOB, 1000);
        vm.startPrank(ALICE);
        token.approve(address(payments), type(uint256).max);
        payments.deposit(address(token), 500);
        vm.stopPrank();
        vm.startPrank(BOB);
        token.approve(address(payments), type(uint256).max);
        payments.deposit(address(token), 500);
        payments.approve(ALICE, tokenId, 100);
        vm.stopPrank();
    }

    function _script() internal view returns (ScriptBuilder) {
        return newScript().setToken(address(token));
    }

    function _rejects(Permissions scope, bytes memory script) internal {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(FilecoinPayV2.Unauthorized.selector, ALICE, ALICE));
        payments.executeScript(scope, script);
    }

    function _allows(Permissions scope, bytes memory script) internal {
        vm.prank(ALICE);
        payments.executeScript(scope, script);
    }

    function testAuthorize() public {
        bytes memory script = newScript().authorize(CAROL, ALL).build();
        _rejects(ALL & ~AUTHORIZE, script);
        vm.expectEmit(address(payments));
        emit FilecoinPayV2.Authorized(ALICE, CAROL, AUTHORIZE);
        _allows(AUTHORIZE, script);
        // the scope carried nothing but AUTHORIZE, so that is all CAROL may pass on
        assertFalse(payments.isOperator(ALICE, CAROL));
        assertEq(Permissions.unwrap(payments.permissions(ALICE, CAROL)), Permissions.unwrap(AUTHORIZE));
    }

    function testTerminateRail() public {
        vm.prank(BOB);
        vm.expectEmit(address(payments));
        emit FilecoinPayV2.Authorized(BOB, ALICE, CREATE_RAIL);
        payments.authorize(ALICE, CREATE_RAIL);
        vm.prank(ALICE);
        RailId rail = payments.createRail(BOB, CAROL, 0, tokenId);

        bytes memory script = _script().setRail(BOB, CAROL, 0).terminateRail().build();
        _rejects(ALL & ~CREATE_RAIL, script);
        vm.expectEmit(address(payments));
        emit FilecoinPayV2.RailTerminated(rail, ALICE);
        _allows(CREATE_RAIL, script);
    }

    function testTerminateRailBy() public {
        vm.prank(ALICE);
        vm.expectEmit(address(payments));
        emit FilecoinPayV2.Authorized(ALICE, BOB, CREATE_RAIL);
        payments.authorize(BOB, CREATE_RAIL);
        vm.prank(BOB);
        RailId rail = payments.createRail(ALICE, CAROL, 0, tokenId);

        bytes memory script = _script().setRail(ALICE, CAROL, 0).terminateRailBy(BOB).build();
        _rejects(ALL & ~CREATE_RAIL, script);
        vm.expectEmit(address(payments));
        emit FilecoinPayV2.RailTerminated(rail, ALICE);
        _allows(CREATE_RAIL, script);
    }

    function testDeposit() public {
        bytes memory script = _script().deposit(100).build();
        _rejects(ALL & ~DEPOSIT, script);
        _allows(DEPOSIT, script);
        assertEq(payments.balanceOf(ALICE, tokenId), 600);
    }

    function testDepositTo() public {
        bytes memory script = _script().depositTo(100, BOB).build();
        // paying someone else takes both halves of DEPOSIT_TO
        _rejects(DEPOSIT, script);
        _rejects(TRANSFER, script);
        _allows(DEPOSIT_TO, script);
        assertEq(payments.balanceOf(BOB, tokenId), 600);
    }

    function testWithdraw() public {
        bytes memory script = _script().withdraw(100).build();
        _rejects(ALL & ~WITHDRAW, script);
        _allows(WITHDRAW, script);
        assertEq(token.balanceOf(ALICE), 600);
    }

    function testWithdrawTo() public {
        bytes memory script = _script().withdrawTo(100, BOB).build();
        _rejects(WITHDRAW, script);
        _rejects(TRANSFER, script);
        _allows(WITHDRAW_TO, script);
        assertEq(token.balanceOf(BOB), 600);
    }

    function testTransfer() public {
        bytes memory script = _script().transfer(BOB, 100).build();
        _rejects(ALL & ~TRANSFER, script);
        _allows(TRANSFER, script);
        assertEq(payments.balanceOf(BOB, tokenId), 600);
    }

    function testTransferFrom() public {
        bytes memory script = _script().transferFrom(CAROL, 100, BOB).build();
        _rejects(ALL & ~TRANSFER, script);
        _allows(TRANSFER, script);
        assertEq(payments.balanceOf(CAROL, tokenId), 100);
        assertEq(payments.allowance(BOB, ALICE, tokenId), 0);
    }

    function testTransferAll() public {
        bytes memory script = _script().transferAll(BOB).build();
        _rejects(ALL & ~TRANSFER, script);
        _allows(TRANSFER, script);
        assertEq(payments.balanceOf(ALICE, tokenId), 0);
        assertEq(payments.balanceOf(BOB, tokenId), 1000);
    }
}
