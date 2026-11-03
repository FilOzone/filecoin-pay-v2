pragma solidity ^0.8.37;

interface IRailV2 {
    function settleRail(uint256 prevSettledEpoch, uint256 settledUpTo, uint256 prevBalance, uint256 addsBalance)
        external
        returns (bytes memory script);
}
