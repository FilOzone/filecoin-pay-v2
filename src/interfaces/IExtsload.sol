// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

interface IExtsload {
    function extsload(bytes32 slot) external view returns (bytes32);
    function extsloadStruct(bytes32 slot, uint256 size) external view returns (bytes32[] memory);
}

