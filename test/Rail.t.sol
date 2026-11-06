// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {CREATE_RAIL} from "../src/lib/Permissions.sol";
import {RailId} from "../src/lib/RailId.sol";
import {FilecoinPayV2} from "../src/FilecoinPayV2.sol";

contract RailTest is Test {

    FilecoinPayV2 internal payments;

    function setUp() public {
        payments = new FilecoinPayV2();
    }

    function testCreate() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint192 flags = uint192(uint160(bob));
        uint256 token = 0;

        vm.expectRevert(abi.encodeWithSelector(FilecoinPayV2.Unauthorized.selector, alice, address(this)));
        payments.createRail(alice, flags, token);

        vm.prank(alice);
        payments.authorize(address(this), CREATE_RAIL);

        RailId expectedRailId = RailId.wrap(0x71f98ae27130217ac46aa80b026ccf3a3d9cbe889e8acf0646ec9efa76ce5622);
        vm.expectEmit(address(payments));
        emit FilecoinPayV2.RailCreated(alice, address(this), token, expectedRailId, flags);
        RailId rail = payments.createRail(alice, flags, token);
        assertEq(RailId.unwrap(rail), RailId.unwrap(expectedRailId));

        vm.expectRevert(FilecoinPayV2.Exists.selector);
        payments.createRail(alice, flags, token);
    }
}
