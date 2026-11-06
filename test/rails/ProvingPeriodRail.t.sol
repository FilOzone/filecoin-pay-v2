// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {RailId} from "../../src/lib/RailId.sol";
import {IValidator} from "../../src/interfaces/IValidator.sol";
import {TRANSFER, UNLOCK} from "../../src/lib/FilecoinPayOps.sol";
import {ProvingPeriodRail} from "../../src/rails/ProvingPeriodRail.sol";

import {MockValidator} from "../lib/MockValidator.sol";

contract ProvingPeriodRailTest is Test {
    using MockValidator for *;

    IValidator private constant VALIDATOR = IValidator(0xBBbBCCcCdddDeEeefffF00001111222233334444);
    address private constant RECIPIENT = 0x111122223333444455556666777788889999aAaa;
    uint256 private constant ACTIVATION = 1234;
    uint256 private constant PROVING_PERIOD = 2888;

    ProvingPeriodRail private rail;
    RailId private railId;

    function setUp() public {
        rail = new ProvingPeriodRail(VALIDATOR, RECIPIENT);
        railId = RailId.wrap(uint256(uint160(address(rail))));

        vm.roll(ACTIVATION);
        vm.prank(address(VALIDATOR));
        rail.activate();
    }

    function testFirstPeriodOnly() public {
        IValidator.ValidationResult memory result;
        result.modifiedAmount = 100;
        result.settleUpto = ACTIVATION + PROVING_PERIOD;
        vm.roll(result.settleUpto);
        VALIDATOR.validatePayment
            .mock(RailId.unwrap(railId), result.modifiedAmount, ACTIVATION, result.settleUpto, 0, result);

        bytes memory script = rail.settleRail(railId, ACTIVATION, result.settleUpto, 0, result.modifiedAmount);
        assertEq(script, abi.encodePacked(uint8(TRANSFER), RECIPIENT, result.modifiedAmount));
    }
}
