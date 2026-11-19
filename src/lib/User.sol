// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {IExtsload} from "../interfaces/IExtsload.sol";
import {Permissions} from "./Permissions.sol";

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
        return uint256(keccak256(abi.encode(owner, USERS_SLOT)));
    }

    function permissions(IExtsload payments, address owner, address operator)
        internal
        view
        returns (Permissions granted)
    {
        uint256 slot = uint256(keccak256(abi.encode(operator, _user(owner) + 1)));
        return Permissions.wrap(uint256(payments.extsload(bytes32(slot))));
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
