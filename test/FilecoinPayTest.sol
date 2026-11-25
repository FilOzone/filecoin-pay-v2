// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {WFIL} from "fevmate/token/WFIL.sol";
import {MockFVMTest} from "fvm-solidity/mocks/MockFVMTest.sol";
import {LibRLP} from "solady/utils/LibRLP.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

import {Auction} from "../src/Auction.sol";
import {FilecoinPayV2} from "../src/FilecoinPayV2.sol";
import {IWFIL} from "../src/interfaces/IWFIL.sol";

contract FilecoinPayTest is MockFVMTest {
    using LibRLP for address;

    FilecoinPayV2 internal payments;
    Auction internal auction;

    MockERC20 internal usdfc;
    WFIL internal wfil;

    MockERC20 internal token;
    uint256 internal tokenId;

    address internal alice;
    address internal bob;

    uint256 internal constant NATIVE_TOKEN = 0;

    function setUp() public virtual override {
        super.setUp();
        wfil = new WFIL(address(this));
        usdfc = new MockERC20();

        payments = new FilecoinPayV2(IWFIL(address(wfil)), address(usdfc));
        auction = Auction(payable(address(payments).computeAddress(1)));

        token = new MockERC20();
        tokenId = uint256(uint160(address(token)));

        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    // never put any test cases in the superclass
}
