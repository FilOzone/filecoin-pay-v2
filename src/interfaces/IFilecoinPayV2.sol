// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {IERC6909} from "forge-std/interfaces/IERC6909.sol";

import {Permissions} from "../lib/Permissions.sol";
import {RailId} from "../lib/RailId.sol";

interface IFilecoinPayV2 is IERC6909 {
    function authorize(address operator, Permissions permissions) external;

    function deposit() external payable;
    function depositTo(address recipient) external payable;
    function deposit(address token, uint256 amount) external;
    function depositTo(address token, address recipient, uint256 amount) external;

    /// @param token address(0) withdraws native FIL
    function withdraw(address token, uint256 amount) external;
    /// @param token address(0) withdraws native FIL
    function withdrawTo(address token, address recipient, uint256 amount) external;

    /// @param nonce high bit is FLAG_CALLBACK, settling through IRailV2 callbacks rather than to
    /// recipient; the low 31 bits distinguish rails sharing the other arguments
    function createRail(address from, address recipient, uint64 nonce, uint256 token) external returns (RailId railId);
    function settleRail(address operator, address from, address recipient, uint64 nonce, uint256 token)
        external
        returns (uint256 settledUpTo);
    function modifyRate(address from, address recipient, uint64 nonce, uint256 token, uint88 rate) external;
    function disburse(address from, address recipient, uint64 nonce, uint256 token, uint128 amount) external;
    function lock(address from, address recipient, uint64 nonce, uint256 token, uint256 amount) external;
    function unlock(address from, address recipient, uint64 nonce, uint256 token, uint256 amount) external;
    function terminateRail(address operator, address from, address recipient, uint64 nonce, uint256 token) external;

    function executeScript(bytes calldata script) external payable;
    /// @param scope narrows the authorization a script runs under
    function executeScript(Permissions scope, bytes calldata script) external payable;
}
