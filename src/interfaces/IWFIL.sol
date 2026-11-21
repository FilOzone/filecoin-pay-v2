// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;
import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IWFIL is IERC20 {
    function withdraw(uint256 amount) external;
}
