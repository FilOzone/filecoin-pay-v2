// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {exp2} from "prb-math/Common.sol";

import {LOG_BIAS, LOG_MAX, LOG_ONE, SCALE_HALF_LIFE, SCALE_STALE} from "../src/Auction.sol";
import {exp2Q32} from "../src/lib/Exp2.sol";

/// @dev `exp2Q32` drops the fraction steps below bit 32, so it is only exact where the callers
/// never set them. These are the gate on that: the dependency is kept to be the reference here.
contract Exp2Test is Test {
    uint256 constant MAX_INTEGER_PART = 191; // one more leaves exp2's domain

    function testMatchesReferenceAcrossTheDomain(uint8 integerPart, uint32 fraction) public pure {
        uint256 x = ((uint256(integerPart) % (MAX_INTEGER_PART + 1)) << 32) | uint256(fraction);
        assertEq(exp2Q32(x), exp2(x << 32));
    }

    /// @dev one case per kept step: a dropped or mistyped constant shows up here, where the
    /// fuzzer only samples 256 of the 192 * 2**32 inputs
    function testEveryKeptStepIsExact() public pure {
        for (uint256 bit = 32; bit < 64; bit++) {
            uint256 x = (uint256(100) << 32) | (1 << (bit - 32));
            assertEq(exp2Q32(x), exp2(x << 32), vm.toString(bit));
        }
    }

    /// @dev the fraction is 32 bits wide, so a finer exponent simply has nowhere to go
    function testFractionIsThirtyTwoBitsWide() public pure {
        assertEq(exp2Q32(1 << 31), exp2(1 << 63));
        assertEq(exp2Q32(1), exp2(1 << 32));
    }

    function testUnitPriceDomainIsExact(int64 logPrice) public pure {
        int256 log = int256(logPrice);
        vm.assume(log >= -LOG_BIAS && log <= LOG_MAX + LOG_ONE);
        uint256 x = uint256(log + LOG_BIAS);
        assertEq(exp2Q32(x), exp2(x << 32));
    }

    function testScaleDomainIsExact(uint256 elapsed) public pure {
        elapsed = bound(elapsed, 0, SCALE_STALE - 1);
        uint256 x = (elapsed << 32) / SCALE_HALF_LIFE;
        assertEq(exp2Q32(x), exp2(x << 32));
    }

    /// @dev the integer part must stay inside exp2's domain, which `SCALE_STALE` is sized for
    function testScaleDomainStaysInsideExp2() public pure {
        assertLe(((SCALE_STALE - 1) << 32) / SCALE_HALF_LIFE >> 32, MAX_INTEGER_PART);
    }
}
