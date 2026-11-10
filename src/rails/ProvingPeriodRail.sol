// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {IValidator} from "../interfaces/IValidator.sol";
import {IRailV2} from "../interfaces/IRail.sol";
import {RailId} from "../lib/RailId.sol";
import {ScriptBuilder} from "../lib/Script.sol";

// A rail with a provingPeriod IValidator and a lockupPeriod
contract ProvingPeriodRail is IRailV2 {
    using ScriptBuilder for bytes;

    address private immutable PAY;
    IValidator private immutable VALIDATOR;
    uint256 private immutable PROVING_PERIOD;

    uint256 private startEpoch; // TODO: check for off-by-one
    // TODO: nothing sets the rate or the lockup yet
    // forge-lint: disable-start(uninitialized-state)
    uint256 private rate;
    uint256 private lockupPeriod;
    // forge-lint: disable-end(uninitialized-state)

    error NotValidator();
    error NotPayments();

    function activate() external {
        require(msg.sender == address(VALIDATOR), NotValidator());
        startEpoch = block.number;
    }

    constructor(IValidator validator) {
        PAY = msg.sender;
        VALIDATOR = validator;
    }

    function settleRail(
        RailId railId,
        uint256 prevSettledEpoch,
        uint256 settledUpTo,
        uint256 prevBalance,
        uint256 addsBalance
    ) external returns (bytes memory script) {
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
        // the settling rail is the script's authorization, so neither op names it
        script = ScriptBuilder.newScript();
        if (refund != 0) {
            script = script.unlock(uint128(refund));
        }
        if (payout != 0) {
            script = script.disburse(uint128(payout));
        }
        script = script.build();
    }
}
