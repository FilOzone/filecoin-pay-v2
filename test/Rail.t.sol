// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {CREATE_RAIL} from "../src/lib/Permissions.sol";
import {RailId, RailIdLibrary, StreamState} from "../src/lib/RailId.sol";
import {FilecoinPayV2} from "../src/FilecoinPayV2.sol";

contract RailTest is Test {
    using RailIdLibrary for FilecoinPayV2;

    FilecoinPayV2 internal payments;

    function setUp() public {
        payments = new FilecoinPayV2();
    }

    function testCreate() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint32 nonce = 0;
        uint256 token = 0;

        vm.expectRevert(abi.encodeWithSelector(FilecoinPayV2.Unauthorized.selector, alice, address(this)));
        payments.createRail(alice, bob, nonce, token);

        vm.prank(alice);
        payments.authorize(address(this), CREATE_RAIL);

        // operator(20) from(20) token(20) recipient(20) nonce(4)
        RailId expectedRailId = RailId.wrap(
            uint256(keccak256(abi.encodePacked(address(this), alice, address(uint160(token)), bob, nonce)))
        );
        assertEq(
            RailId.unwrap(expectedRailId),
            0x19dcc429a1c4e6bbb13cdf766b15979eb4541ab36709de42a8976b2db548e013,
            "rail id preimage layout changed"
        );
        vm.expectEmit(address(payments));
        emit FilecoinPayV2.RailCreated(alice, bob, address(this), token, expectedRailId, nonce);
        RailId rail = payments.createRail(alice, bob, nonce, token);
        assertEq(RailId.unwrap(rail), RailId.unwrap(expectedRailId));

        StreamState memory state = payments.getRail(rail);
        assertEq(state.incomingRate, 0);
        assertEq(state.settledUpTo, vm.getBlockNumber());
        assertEq(state.available, 0);

        vm.expectRevert(FilecoinPayV2.Exists.selector);
        payments.createRail(alice, bob, nonce, token);

        uint256 invalidToken = (1 << 160) | uint256(uint160(makeAddr("erc20")));
        vm.expectRevert(FilecoinPayV2.InvalidToken.selector);
        payments.createRail(alice, bob, nonce, invalidToken);
    }
}
