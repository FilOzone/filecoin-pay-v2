pragma solidity ^0.8.37;

type Permissions is uint256;

using {and as &, equal as ==, not as ~, notEqual as !=, or as |} for Permissions global;
using PermissionsLibrary for Permissions global;

uint256 constant DEPOSIT_U256 = 1 << 0;
uint256 constant WITHDRAW_U256 = 1 << 1;
uint256 constant TRANSFER_U256 = 1 << 2;
uint256 constant CREATE_RAIL_U256 = 1 << 3;
uint256 constant APPROVE_U256 = 1 << 4;

Permissions constant DEPOSIT = Permissions.wrap(DEPOSIT_U256);
Permissions constant WITHDRAW = Permissions.wrap(WITHDRAW_U256);
Permissions constant TRANSFER = Permissions.wrap(TRANSFER_U256);
Permissions constant CREATE_RAIL = Permissions.wrap(CREATE_RAIL_U256);

// composite permissions
uint256 constant NONE_U256 = 0;
uint256 constant ALL_U256 = type(uint256).max;
uint256 constant DEPOSIT_TO_U256 = DEPOSIT_U256 | TRANSFER_U256;
uint256 constant WITHDRAW_TO_U256 = WITHDRAW_U256 | TRANSFER_U256;

Permissions constant NONE = Permissions.wrap(NONE_U256);
Permissions constant ALL = Permissions.wrap(ALL_U256);
Permissions constant DEPOSIT_TO = Permissions.wrap(DEPOSIT_TO_U256);
Permissions constant WITHRDAW_TO = Permissions.wrap(WITHDRAW_TO_U256);

function and(Permissions a, Permissions b) pure returns (Permissions) {
    return Permissions.wrap(Permissions.unwrap(a) & Permissions.unwrap(b));
}

function or(Permissions a, Permissions b) pure returns (Permissions) {
    return Permissions.wrap(Permissions.unwrap(a) | Permissions.unwrap(b));
}

function equal(Permissions a, Permissions b) pure returns (bool) {
    return Permissions.unwrap(a) == Permissions.unwrap(b);
}

function notEqual(Permissions a, Permissions b) pure returns (bool) {
    return Permissions.unwrap(a) != Permissions.unwrap(b);
}

function not(Permissions a) pure returns (Permissions) {
    return Permissions.wrap(~Permissions.unwrap(a));
}

library PermissionsLibrary {
    function isOperator(Permissions permissions) internal pure returns (bool) {
        return permissions & TRANSFER != NONE;
    }

    function setIsOperator(Permissions permissions, bool approved) internal pure returns (Permissions) {
        if (approved) {
            return permissions | TRANSFER;
        } else {
            return permissions & ~TRANSFER;
        }
    }
}
