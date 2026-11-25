// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {BURN_ADDRESS} from "fvm-solidity/FVMActors.sol";
import {UNIT, exp2, mulDiv} from "prb-math/Common.sol";

import {IFilecoinPayV2} from "./interfaces/IFilecoinPayV2.sol";
import {IWFIL} from "./interfaces/IWFIL.sol";
import {TRANSFER, WITHDRAW_TO} from "./lib/Permissions.sol";
import {newScript} from "./lib/Script.sol";

uint40 constant NEVER = type(uint40).max;
uint256 constant HALVING_INTERVAL = 60 * 24 * 7; // 3.5 days of epochs
uint256 constant SCALE_HALF_LIFE = 1024; // ~8.5h at 30s epochs
uint256 constant SCALE_STALE = SCALE_HALF_LIFE * 64; // leaves 2^-64 of the memory; exp2 leaves its domain past 191

int256 constant LOG_ONE = int256(1) << 32; // one doubling in Q32.32
int256 constant LOG_BIAS = int256(64) << 32; // exp2 takes unsigned, so -LOG_BIAS is also the price floor
int256 constant LOG_MAX = int256(126) << 32; // stored ceiling; +1 doubling stays inside exp2's domain
int256 constant INITIAL_LOG_PRICE = 0; // 1 attoFIL per token unit, then discovered by decay
uint256 constant LN2 = 693147180559945309; // ln2 * UNIT, so dividing by it also undoes exp2 scaling

contract Auction {
    IFilecoinPayV2 private immutable PAYMENTS;
    IWFIL private immutable WFIL;
    uint256 private constant NATIVE_TOKEN = 0;

    struct DutchAuction {
        int64 logPrice; // Q32.32 log2(attoFIL per token unit)
        uint128 scale; // quantity whose purchase doubles the price
        uint40 lastEpoch;
    }

    /// @dev the token address is the slot, shifted to the top because the storage trie branches
    /// from the high bits; indexing low buries every token under one more node. No state variable
    /// may be declared: solc would place it on slot 0, which is the native token's own entry
    function _auctionOf(address token) private pure returns (DutchAuction storage auction) {
        assembly ("memory-safe") {
            auction.slot := shl(96, token)
        }
    }

    function auctionOf(address token) external view returns (int64 logPrice, uint128 scale, uint40 lastEpoch) {
        DutchAuction storage auction = _auctionOf(token);
        return (auction.logPrice, auction.scale, auction.lastEpoch);
    }

    constructor(IWFIL wfil) {
        PAYMENTS = IFilecoinPayV2(msg.sender);
        WFIL = wfil;
        _auctionOf(address(0)).lastEpoch = NEVER;
        _auctionOf(address(wfil)).lastEpoch = NEVER;
    }

    receive() external payable {}

    function unwrap() external {
        PAYMENTS.withdraw(address(WFIL), uint128(PAYMENTS.balanceOf(address(this), uint256(uint160(address(WFIL))))));
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

    event Auctioned(address indexed token, uint128 bite, uint128 valuation, uint128 paid);

    error Insufficient(uint256 valuation);

    /// @return attoFIL per token unit, scaled by UNIT
    function _unitPrice(int256 logPrice) private pure returns (uint256) {
        return exp2(uint256(logPrice + LOG_BIAS) << 32) >> 64;
    }

    /// @dev decays only the excess over `available`, so the scale is never below what a buyer could take
    function _scaleOf(uint256 remembered, uint256 available, uint256 elapsed) private pure returns (uint256) {
        if (remembered <= available || elapsed >= SCALE_STALE) {
            return available;
        }
        return available + (remembered - available) * UNIT / exp2((elapsed << 64) / SCALE_HALF_LIFE);
    }

    function accept(address token, uint128 bite, uint128 price) external {
        DutchAuction storage stored = _auctionOf(token);
        // one slot, so solc folds these into a single SLOAD and they stay off memory
        (int64 lastLogPrice, uint128 lastScale, uint40 lastEpoch) = (stored.logPrice, stored.scale, stored.lastEpoch);
        uint256 available = PAYMENTS.balanceOf(address(this), uint256(uint160(token)));

        int256 logPrice = INITIAL_LOG_PRICE;
        uint256 scale;
        if (lastEpoch == 0) {
            scale = available;
        } else {
            uint256 elapsed = block.number - uint256(lastEpoch); // NEVER underflows, blocking the token
            logPrice = int256(lastLogPrice) - int256((elapsed << 32) / HALVING_INTERVAL);
            if (logPrice < -LOG_BIAS) {
                logPrice = -LOG_BIAS;
            }
            scale = _scaleOf(uint256(lastScale), available, elapsed);
        }

        // a bite that can settle is at most `available` <= `scale`, so one purchase is at most one
        // doubling, which is what holds `logPrice + doublings` inside exp2's domain at LOG_MAX
        int256 doublings = int256((uint256(bite) << 32) / scale);
        // the integral of 2^(logPrice + q/scale) over the bite, so splitting a purchase in two
        // costs what making it at once would
        uint256 valuation = mulDiv(scale, _unitPrice(logPrice + doublings) - _unitPrice(logPrice), LN2);
        require(price > valuation, Insufficient(valuation)); // strict, so every bite costs at least 1

        int256 next = logPrice + doublings;
        if (next > LOG_MAX) {
            next = LOG_MAX;
        }
        stored.logPrice = int64(next);
        stored.scale = uint128(scale);
        stored.lastEpoch = uint40(block.number);
        emit Auctioned(token, bite, uint128(valuation), price);

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
