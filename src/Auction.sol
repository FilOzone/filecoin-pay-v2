// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {BURN_ADDRESS} from "fvm-solidity/FVMActors.sol";
import {exp2} from "prb-math/Common.sol";

import {IFilecoinPayV2} from "./interfaces/IFilecoinPayV2.sol";
import {IWFIL} from "./interfaces/IWFIL.sol";
import {TRANSFER, WITHDRAW, WITHDRAW_TO} from "./lib/Permissions.sol";
import {newScript} from "./lib/Script.sol";

uint40 constant NEVER = type(uint40).max;
uint128 constant INITIAL_PRICE = 1 ether;
uint256 constant HALVING_INTERVAL = 60 * 24 * 7; // 3.5 days of epochs

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
        // TODO(perf); compare to PAYMENTS.withdraw
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

    event Auctioned(address indexed token, uint128 bite, uint128 required, uint128 paid);
    error Insufficient(uint128 required);

    function accept(address token, uint128 bite, uint128 price) external {
        DutchAuction memory auction = auctionOf[token];
        uint128 required;
        if (auction.begin == 0) {
            required = INITIAL_PRICE;
            auction.price = uint216((uint256(INITIAL_PRICE) << 66) / uint256(bite));
        } else {
            uint256 available = PAYMENTS.balanceOf(address(this), uint256(uint160(token)));
            uint256 elapsed;
            unchecked {
                elapsed = ((block.number - uint256(auction.begin)) << 64) / HALVING_INTERVAL;
            }
            required = uint128(((uint256(auction.price) * 10 ** 18) * uint256(bite) / exp2(elapsed)) >> 64);

            auction.price = uint216(
                ((uint256(required) << 64) / uint256(bite) * ((1 << 64) + ((3 << 64) * uint256(bite) / available)))
                    >> 64
            );
        }
        require(price >= required, Insufficient(required));
        auction.begin = uint40(block.number);
        auctionOf[token] = auction;
        emit Auctioned(token, bite, required, price);

        PAYMENTS.executeScript(
            TRANSFER,
            newScript()
                .transferFrom(address(this), price, msg.sender)
                .setToken(token)
                .transfer(msg.sender, bite)
                .build()
        );
    }
}
