// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {WFIL} from "fevmate/token/WFIL.sol";
import {BURN_ADDRESS} from "fvm-solidity/FVMActors.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC6909} from "forge-std/interfaces/IERC6909.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

import {Auction, HALVING_INTERVAL, INITIAL_PRICE} from "../src/Auction.sol";
import {FilecoinPayV2} from "../src/FilecoinPayV2.sol";
import {TRANSFER} from "../src/lib/Permissions.sol";
import {FilecoinPayTest} from "./FilecoinPayTest.sol";

contract AuctionTest is FilecoinPayTest {
    function depositNative(address from, address to, uint256 amount) internal {
        vm.deal(from, amount);
        vm.prank(from);
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(from, address(0), to, NATIVE_TOKEN, amount);
        payments.depositTo{value: amount}(to);
    }

    function testBurn() public {
        depositNative(alice, address(auction), 5 ether);

        vm.deal(address(auction), 2 ether);

        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(auction), address(0), address(auction), NATIVE_TOKEN, 2 ether);
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(auction), address(auction), address(0), NATIVE_TOKEN, 7 ether);
        auction.burn();

        assertEq(BURN_ADDRESS.balance, 7 ether);
    }

    function mockAndDepositTo(MockERC20 token, address from, address to, uint256 amount) internal {
        token.mint(from, amount);
        erc20DepositTo(IERC20(address(token)), from, to, amount);
    }

    function erc20DepositTo(IERC20 token, address from, address to, uint256 amount) internal {
        vm.expectEmit(address(token));
        emit IERC20.Approval(from, address(payments), amount);
        vm.prank(from);
        token.approve(address(payments), amount);

        uint256 tokenId = uint256(uint160(address(token)));

        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(from, address(0), to, tokenId, amount);
        vm.expectEmit(address(token));
        emit IERC20.Transfer(from, address(payments), amount);
        vm.prank(from);
        payments.depositTo(address(token), to, amount);
    }

    function depositWrapped(address from, address to, uint256 amount) internal {
        vm.deal(from, amount);

        vm.expectEmit(address(wfil));
        emit WFIL.Deposit(from, amount);
        vm.prank(from);
        wfil.deposit{value: amount}();

        erc20DepositTo(IERC20(address(wfil)), from, to, amount);
    }

    function testUnwrap() public {
        depositWrapped(alice, address(auction), 5 ether);

        uint256 wfil_token = uint256(uint160(address(wfil)));

        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(auction), address(auction), address(0), wfil_token, 5 ether);
        vm.expectEmit(address(wfil));
        emit WFIL.Withdrawal(address(auction), 5 ether);
        auction.unwrap();

        assertEq(address(auction).balance, 5 ether);
        assertEq(BURN_ADDRESS.balance, 0);

        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(auction), address(0), address(auction), NATIVE_TOKEN, 5 ether);
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(auction), address(auction), address(0), NATIVE_TOKEN, 5 ether);
        auction.burn();

        assertEq(address(auction).balance, 0);
        assertEq(BURN_ADDRESS.balance, 5 ether);
    }

    function testAcceptNativeOrWrappedReverts() public {
        depositNative(alice, alice, INITIAL_PRICE);
        depositWrapped(alice, address(auction), 1 ether);
        depositNative(alice, address(auction), 1 ether);

        vm.expectRevert(); // TODO: specific error
        auction.accept(address(0), 1 ether, INITIAL_PRICE);
        vm.expectRevert(); // TODO: specific error
        auction.accept(address(wfil), 1 ether, INITIAL_PRICE);
        vm.expectRevert(); // TODO: specific error
        auction.accept(address(0), 1 ether, INITIAL_PRICE);
        vm.expectRevert(); // TODO: specific error
        auction.accept(address(wfil), 1 ether, INITIAL_PRICE);
    }

    function testRateInitialIncreaseDecrease() public {
        depositNative(alice, alice, INITIAL_PRICE);
        mockAndDepositTo(usdfc, alice, address(auction), 16 ether);

        vm.expectEmit(address(payments));
        emit IERC6909.Approval(alice, address(auction), NATIVE_TOKEN, INITIAL_PRICE);
        vm.prank(alice);
        payments.approve(address(auction), NATIVE_TOKEN, INITIAL_PRICE);

        // initial auction settles at .0625
        vm.prank(alice);
        auction.accept(address(usdfc), 16 ether, INITIAL_PRICE);

        uint256 tokenId = uint256(uint160(address(usdfc)));

        assertEq(payments.balanceOf(address(auction), NATIVE_TOKEN), INITIAL_PRICE);
        assertEq(payments.balanceOf(address(auction), tokenId), 0);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 0);
        assertEq(payments.balanceOf(alice, tokenId), 16 ether);

        // start price is .25
        Auction.DutchAuction memory auctionInfo;
        (auctionInfo.price, auctionInfo.begin) = auction.auctionOf(address(usdfc));
        assertEq(uint256(auctionInfo.begin), vm.getBlockNumber());
        assertEq(uint256(auctionInfo.price), 1 << 62);

        mockAndDepositTo(usdfc, alice, address(auction), 160 ether);
        depositNative(alice, alice, 20 ether);

        vm.expectEmit(address(payments));
        emit FilecoinPayV2.Authorized(alice, address(auction), TRANSFER);
        vm.expectEmit(address(payments));
        emit IERC6909.OperatorSet(alice, address(auction), true);
        vm.prank(alice);
        payments.setOperator(address(auction), true);

        vm.expectRevert(abi.encodeWithSelector(Auction.Insufficient.selector, 20 ether));
        vm.prank(alice);
        auction.accept(address(usdfc), 80 ether, 20 ether - 1);

        vm.expectEmit(address(auction));
        emit Auction.Auctioned(address(usdfc), 80 ether, 20 ether, 20 ether);
        vm.prank(alice);
        auction.accept(address(usdfc), 80 ether, 20 ether);

        assertEq(payments.balanceOf(alice, tokenId), 96 ether);
        assertEq(payments.balanceOf(address(auction), tokenId), 80 ether);

        // start price is .625
        (auctionInfo.price, auctionInfo.begin) = auction.auctionOf(address(usdfc));
        assertEq(uint256(auctionInfo.begin), vm.getBlockNumber());
        assertEq(uint256(auctionInfo.price), 5 << 61);

        mockAndDepositTo(usdfc, alice, address(auction), 20 ether);
        assertEq(payments.balanceOf(address(auction), tokenId), 100 ether);

        depositNative(alice, alice, 50 ether);

        vm.expectRevert(abi.encodeWithSelector(Auction.Insufficient.selector, 62.5 ether));
        vm.prank(alice);
        auction.accept(address(usdfc), 100 ether, 50 ether);

        vm.roll(vm.getBlockNumber() + HALVING_INTERVAL);

        vm.expectEmit(address(auction));
        emit Auction.Auctioned(address(usdfc), 100 ether, 31.25 ether, 50 ether);
        vm.prank(alice);
        auction.accept(address(usdfc), 100 ether, 50 ether);

        // start price is 1.25
        (auctionInfo.price, auctionInfo.begin) = auction.auctionOf(address(usdfc));
        assertEq(uint256(auctionInfo.begin), vm.getBlockNumber());
        assertEq(uint256(auctionInfo.price), 5 << 62);
    }
}
