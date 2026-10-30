pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {StdConstants} from "forge-std/StdConstants.sol";
import {IValidator} from "../../src/interfaces/IValidator.sol";

library MockValidator {
    Vm internal constant VM = Vm(StdConstants.VM);

    function mock(function (
        uint256,
        uint256,
        uint256,
        uint256,
        uint256
    ) external returns (IValidator.ValidationResult memory) f, uint256 railId, uint256 proposedAmount, uint256 fromEpoch, uint256 toEpoch, uint256 rate, IValidator.ValidationResult memory result) internal {
        VM.mockCall(
            f.address,
            abi.encodeWithSelector(f.selector, railId, proposedAmount, fromEpoch, toEpoch, rate),
            abi.encode(result)
        );
    }
}
