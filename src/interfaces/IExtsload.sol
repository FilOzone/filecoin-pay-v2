// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

interface IExtsload {
    function extsload(bytes32 slot) external view returns (bytes32);
}

