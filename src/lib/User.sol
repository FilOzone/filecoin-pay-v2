// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {IExtsload} from "../interfaces/IExtsload.sol";
import {Permissions} from "./Permissions.sol";

/// @dev balance is the claim as of modifiedEpoch, ahead of the spendable one by the drain since:
/// balance <= totalSupply + drainRate * epochs. A uint88 rate adds 2**126 over 2**38 epochs, so a
/// supply of 2**127 or less cannot wrap a credit inside 260,000 years of the uint40 epoch's million.
struct Checkpoint {
    uint128 balance;
    uint88 drainRate;
    uint40 modifiedEpoch;
}

struct Authorization {
    Permissions permissions;
}

struct Account {
    Checkpoint latest;
    mapping(address spender => uint256) allowance;
}

struct User {
    mapping(uint256 token => Account) accounts;
    mapping(address authorized => Authorization) authorizations;
}

library UserLibrary {
    /// @dev FilecoinPayV2.users, its only storage variable
    uint256 private constant USERS_SLOT = 0;

    function _user(address owner) private pure returns (uint256 slot) {
        assembly ("memory-safe") {
            mstore(0, owner)
            mstore(32, USERS_SLOT)
            slot := keccak256(0, 64)
        }
    }

    function permissions(IExtsload payments, address owner, address operator)
        internal
        view
        returns (Permissions granted)
    {
        assembly ("memory-safe") {
            mstore(0, owner)
            mstore(32, USERS_SLOT)
            mstore(32, add(1, keccak256(0, 64)))
            mstore(0, operator)
            mstore(32, keccak256(0, 64))
            mstore(0, 0x1e2eaeaf) // extsload
            let success := staticcall(gas(), payments, 28, 36, 0, 32)
            if iszero(success) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
            granted := mload(0)
        }
    }

    function latest(IExtsload payments, address user, uint256 token)
        internal
        view
        returns (Checkpoint memory checkpoint)
    {
        uint256 slot = uint256(keccak256(abi.encode(token, _user(user))));
        uint256 packed = uint256(payments.extsload(bytes32(slot)));
        checkpoint.balance = uint128(packed);
        checkpoint.drainRate = uint88(packed >> 128);
        checkpoint.modifiedEpoch = uint40(packed >> 216);
    }
}
