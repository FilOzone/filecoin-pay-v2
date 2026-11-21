// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {BURN_ADDRESS} from "fvm-solidity/FVMActors.sol";
import {exp2} from "prb-math/Common.sol";

import {IWFIL} from "./interfaces/IWFIL.sol";
import {Dutch} from "./lib/Dutch.sol";
import {Permissions, TRANSFER, WITHDRAW, WITHDRAW_TO} from "./lib/Permissions.sol";
import {newScript} from "./lib/Script.sol";

uint40 constant NEVER = type(uint40).max;

interface IFilecoinPayV2 {
    function balanceOf(address owner, uint256 token) external view returns (uint256);
    function executeScript(Permissions permissions, bytes memory script) external payable;
}

contract Auction {
    IFilecoinPayV2 private immutable PAYMENTS;
    IWFIL private immutable WFIL;
    uint256 private constant NATIVE_TOKEN = 0;

    struct DutchAuction {
        uint216 price; // Q152.64 TODO consider sqrt pricing
        uint40 begin;
    }

    mapping(address token => DutchAuction) public auctionOf;

    constructor(IWFIL wfil) {
        PAYMENTS = IFilecoinPayV2(msg.sender);
        WFIL = wfil;
        auctionOf[address(0)].begin = NEVER;
        auctionOf[address(wfil)].begin = NEVER;
    }

    receive() external payable {}

    function unwrap() external {
        PAYMENTS.executeScript(
            WITHDRAW,
            newScript()
                .setToken(address(WFIL))
                .withdraw(uint128(PAYMENTS.balanceOf(address(this), uint256(uint160(address(WFIL))))))
                .build()
        );
        WFIL.withdraw(WFIL.balanceOf(address(this)));
    }

    function burn() external {
        uint256 selfBalance = address(this).balance;
        PAYMENTS.executeScript{value: selfBalance}(
            WITHDRAW_TO,
            newScript()
                .withdrawTo(uint128(selfBalance + PAYMENTS.balanceOf(address(this), NATIVE_TOKEN)), BURN_ADDRESS)
                .build()
        );
    }

    uint256 private constant HALVING_INTERVAL = 60 * 24 * 7; // 3.5 days of epochs

    function accept(address token, uint128 bite, uint128 price) external {
        uint256 available = PAYMENTS.balanceOf(address(this), uint256(uint160(token)));
        //require(bite < available)
        DutchAuction memory auction = auctionOf[token];
        uint256 elapsed;
        unchecked {
            elapsed = ((block.number - uint256(auction.begin)) << 64) / HALVING_INTERVAL;
        }
        //require(elapsed < uEXP2_MAX_INPUT);
        uint128 required = uint128((uint256(auction.price) << 64) * uint256(bite) / exp2(elapsed));
        require(price <= required);

        auction.price =
            uint216((uint256(required) << 64) / uint256(bite) + 55340232221128654848 * uint256(bite) / available);
        auction.begin = uint40(block.number);
        auctionOf[token] = auction;

        PAYMENTS.executeScript(
            TRANSFER,
            newScript()
                .transferFrom(address(this), price, msg.sender)
                .setToken(token)
                .transfer(msg.sender, bite)
                .build()
        );
    }

    uint128 private constant INITIAL_PRICE = 1 ether;

    function firstAccept(address token, uint128 bite) external {
        DutchAuction memory auction = auctionOf[token];
        require(auction.begin == 0);

        auction.begin = uint40(block.number);
        auction.price = uint216((uint256(INITIAL_PRICE) << 64) / uint256(bite));
        uint256 available = PAYMENTS.balanceOf(address(this), uint256(uint160(token)));

        PAYMENTS.executeScript(
            TRANSFER,
            newScript()
                .transferFrom(address(this), INITIAL_PRICE, msg.sender)
                .setToken(token)
                .transfer(msg.sender, bite)
                .build()
        );
    }
}
