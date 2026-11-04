// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {IValidator} from "../interfaces/IValidator.sol";
import {IRailV2} from "../interfaces/IRail.sol";
import {RailId} from "../lib/RailId.sol";

// A rail with a provingPeriod IValidator and a lockupPeriod
contract ProvingPeriodRail is IRailV2 {
    bytes20 private immutable RECIPIENT;
    address private immutable PAY;
    IValidator private immutable VALIDATOR;
    uint256 private immutable PROVING_PERIOD;

    uint256 private startEpoch; // TODO: check for off-by-one
    uint256 private rate;
    uint256 private lockupPeriod;

    error NotValidator();
    error NotPayments();

    function activate() external {
        require(msg.sender == address(VALIDATOR), NotValidator());
        startEpoch = block.number;
    }

    constructor(IValidator validator, address recipient) {
        PAY = msg.sender;
        VALIDATOR = validator;
        RECIPIENT = bytes20(recipient);
    }

    function settleRail(RailId railId, uint256 token, uint256 prevSettledEpoch, uint256 settledUpTo, uint256 prevBalance, uint256 addsBalance)
        external returns (bytes memory script)
    {
        require(msg.sender == PAY, NotPayments());
        uint256 refund = 0;
        uint256 payout = 0;
        prevBalance -= rate * lockupPeriod;
        // FIXME: handle whether this is actually the current period
        if (prevBalance != 0) {
            uint256 prevPeriodStart = prevSettledEpoch - (prevSettledEpoch - startEpoch) % PROVING_PERIOD;
            // the previous period has a different rate
            // FIXME: this reads the first proving period twice: here and below
            IValidator.ValidationResult memory result = VALIDATOR.validatePayment(
                uint256(uint160(address(this))), prevBalance, prevPeriodStart, prevSettledEpoch, 0
            );
            if (result.settleUpto < prevSettledEpoch) {
                return "";
            }
            payout = result.modifiedAmount;
            refund = prevBalance - payout;
        }
        if (addsBalance != 0) {
            IValidator.ValidationResult memory result = VALIDATOR.validatePayment(
                uint256(uint160(address(this))), addsBalance, prevSettledEpoch, settledUpTo, 0
            );
            payout += result.modifiedAmount;
            addsBalance = addsBalance * (result.settleUpto - prevSettledEpoch) / (settledUpTo - prevSettledEpoch);
            refund += addsBalance - result.modifiedAmount;
        }
        bytes20 recipient = RECIPIENT;
        assembly ("memory-safe") {
            mstore(0, 32)
            let buffer := 64
            if refund {
                mstore8(64, 13)
                mstore(65, refund)
                buffer := 97
            }
            if payout {
                mstore8(buffer, 10)
                mstore(add(1, buffer), recipient)
                mstore(add(21, buffer), payout)
                buffer := add(53, buffer)
            }
            mstore(32, sub(buffer, 64))
            return(0, buffer)
        }
    }
}
