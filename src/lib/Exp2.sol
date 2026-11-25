// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {UNIT} from "prb-math/Common.sol";

// the step constants are prb-math's, verbatim; the tests are `!= 0` rather than its `> 0`,
// which is what makes solar branch per step instead of multiplying through every bit of an
// entered byte-group: worth 123 instructions and up to 560k gas on a dense exponent
/// @notice `prb-math`'s `exp2` with the four low byte-groups of its fraction removed.
/// @dev The fraction is 32 bits rather than 64, which is all `logPrice` carries: dropping the
/// four low byte-groups halves the unrolled steps, and taking the exponent already in Q32.32
/// saves 4 bytes on each surviving mask. `test/Exp2.t.sol` pins it against the dependency,
/// which is what prb-math is still here for.
/// @param x a 224.32 fixed-point exponent, integer part at most 191
/// @return result 2**x as an unsigned 60.18 fixed-point number
function exp2Q32(uint256 x) pure returns (uint256 result) {
    unchecked {
        // Start from 0.5 in the 192.64-bit fixed-point format.
        result = 0x800000000000000000000000000000000000000000000000;
        if (x & 0xFF000000 != 0) {
            if (x & 0x80000000 != 0) {
                result = (result * 0x16A09E667F3BCC909) >> 64;
            }
            if (x & 0x40000000 != 0) {
                result = (result * 0x1306FE0A31B7152DF) >> 64;
            }
            if (x & 0x20000000 != 0) {
                result = (result * 0x1172B83C7D517ADCE) >> 64;
            }
            if (x & 0x10000000 != 0) {
                result = (result * 0x10B5586CF9890F62A) >> 64;
            }
            if (x & 0x8000000 != 0) {
                result = (result * 0x1059B0D31585743AE) >> 64;
            }
            if (x & 0x4000000 != 0) {
                result = (result * 0x102C9A3E778060EE7) >> 64;
            }
            if (x & 0x2000000 != 0) {
                result = (result * 0x10163DA9FB33356D8) >> 64;
            }
            if (x & 0x1000000 != 0) {
                result = (result * 0x100B1AFA5ABCBED61) >> 64;
            }
        }

        if (x & 0xFF0000 != 0) {
            if (x & 0x800000 != 0) {
                result = (result * 0x10058C86DA1C09EA2) >> 64;
            }
            if (x & 0x400000 != 0) {
                result = (result * 0x1002C605E2E8CEC50) >> 64;
            }
            if (x & 0x200000 != 0) {
                result = (result * 0x100162F3904051FA1) >> 64;
            }
            if (x & 0x100000 != 0) {
                result = (result * 0x1000B175EFFDC76BA) >> 64;
            }
            if (x & 0x80000 != 0) {
                result = (result * 0x100058BA01FB9F96D) >> 64;
            }
            if (x & 0x40000 != 0) {
                result = (result * 0x10002C5CC37DA9492) >> 64;
            }
            if (x & 0x20000 != 0) {
                result = (result * 0x1000162E525EE0547) >> 64;
            }
            if (x & 0x10000 != 0) {
                result = (result * 0x10000B17255775C04) >> 64;
            }
        }

        if (x & 0xFF00 != 0) {
            if (x & 0x8000 != 0) {
                result = (result * 0x1000058B91B5BC9AE) >> 64;
            }
            if (x & 0x4000 != 0) {
                result = (result * 0x100002C5C89D5EC6D) >> 64;
            }
            if (x & 0x2000 != 0) {
                result = (result * 0x10000162E43F4F831) >> 64;
            }
            if (x & 0x1000 != 0) {
                result = (result * 0x100000B1721BCFC9A) >> 64;
            }
            if (x & 0x800 != 0) {
                result = (result * 0x10000058B90CF1E6E) >> 64;
            }
            if (x & 0x400 != 0) {
                result = (result * 0x1000002C5C863B73F) >> 64;
            }
            if (x & 0x200 != 0) {
                result = (result * 0x100000162E430E5A2) >> 64;
            }
            if (x & 0x100 != 0) {
                result = (result * 0x1000000B172183551) >> 64;
            }
        }

        if (x & 0xFF != 0) {
            if (x & 0x80 != 0) {
                result = (result * 0x100000058B90C0B49) >> 64;
            }
            if (x & 0x40 != 0) {
                result = (result * 0x10000002C5C8601CC) >> 64;
            }
            if (x & 0x20 != 0) {
                result = (result * 0x1000000162E42FFF0) >> 64;
            }
            if (x & 0x10 != 0) {
                result = (result * 0x10000000B17217FBB) >> 64;
            }
            if (x & 0x8 != 0) {
                result = (result * 0x1000000058B90BFCE) >> 64;
            }
            if (x & 0x4 != 0) {
                result = (result * 0x100000002C5C85FE3) >> 64;
            }
            if (x & 0x2 != 0) {
                result = (result * 0x10000000162E42FF1) >> 64;
            }
            if (x & 0x1 != 0) {
                result = (result * 0x100000000B17217F8) >> 64;
            }
        }

        // In the code snippet below, two operations are executed simultaneously:
        //
        // 1. The result is multiplied by $(2^n + 1)$, where $2^n$ represents the integer part, and the additional 1
        // accounts for the initial guess of 0.5. This is achieved by subtracting from 191 instead of 192.
        // 2. The result is then converted to an unsigned 60.18-decimal fixed-point format.
        //
        // The underlying logic is based on the relationship $2^{191-ip} = 2^{ip} / 2^{191}$, where $ip$ denotes the
        // integer part, $2^n$.
        result *= UNIT;
        result >>= (191 - (x >> 32));
    }
}
