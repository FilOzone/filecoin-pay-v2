// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {RailId} from "../lib/RailId.sol";

interface IRailV2 {
    function settleRail(
        RailId railId,
        uint256 prevSettledEpoch,
        uint256 settledUpTo,
        uint256 prevBalance,
        uint256 addsBalance
    ) external returns (bytes memory script);
}
