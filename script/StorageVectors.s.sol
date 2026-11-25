// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {FilecoinPayV2} from "../src/FilecoinPayV2.sol";
import {ALL, CREATE_RAIL, Permissions, TRANSFER} from "../src/lib/Permissions.sol";
import {FLAG_CALLBACK, RailId, RailIdLibrary, Stream, StreamState} from "../src/lib/RailId.sol";
import {Checkpoint, UserLibrary} from "../src/lib/User.sol";

import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @dev writes vectors/storage.json, the slots and packed words every client library reads through extsload
contract StorageVectors is Script {
    using RailIdLibrary for address;
    using RailIdLibrary for FilecoinPayV2;
    using RailIdLibrary for Stream;
    using UserLibrary for FilecoinPayV2;

    error NotDryRun();
    error UserSlotChanged();
    error AccountSlotChanged();
    error PermissionsSlotChanged();
    error RailIdChanged();
    error EmptySlot(bytes32 slot);
    error CheckpointMismatch(bytes32 slot);
    error PermissionsMismatch(bytes32 slot);
    error StreamMismatch(bytes32 railId);
    error CheckpointPackingChanged(bytes32 word);
    error StreamPackingChanged(bytes32 word);

    string private constant PATH = "vectors/storage.json";

    // every actor is a slot input, so none may depend on deployment order or be address(this)
    address private constant ALICE = 0xA11cea11CEA11CEA11cEa11CeA11ceA11CEA11Ce;
    address private constant BOB = 0xb0bB0bB0Bb0Bb0bB0Bb0bb0bb0bB0BB0Bb0BB0Bb;
    address private constant CAROL = 0xCA401ca401Ca401CA401CA401cA401CA401ca401;
    address private constant TOKEN = 0x1111111111111111111111111111111111111111;
    address private constant OPERATOR = 0x2222222222222222222222222222222222222222;
    uint256 private constant NATIVE_TOKEN = 0;
    uint256 private constant TOKEN_ID = uint256(uint160(TOKEN));
    /// @dev FilecoinPayV2.users
    uint256 private constant USERS_SLOT = 0;

    // real state only holds small numbers: a saturated field would spill into its neighbour under
    // a wrong mask, and a counting one would not survive a swap or a reversal
    uint128 private constant COUNTING_U128 = 0x0102030405060708090a0b0c0d0e0f10;
    uint88 private constant COUNTING_U88 = 0x1112131415161718191a1b;
    uint40 private constant COUNTING_U40 = 0x1c1d1e1f20;

    FilecoinPayV2 private payments;

    Checkpoint private packedCheckpoint;
    StreamState private packedStream;

    string[] private users;
    string[] private accounts;
    string[] private permissions;
    string[] private rails;
    string[] private packedCheckpoints;
    string[] private packedStreams;

    function setUp() public {
        vm.roll(1000);
        payments = new FilecoinPayV2();
        vm.etch(TOKEN, address(new MockERC20()).code);

        MockERC20(TOKEN).mint(ALICE, 500e18);
        MockERC20(TOKEN).mint(BOB, 200e18);
        vm.deal(ALICE, 3e18);
        vm.deal(BOB, 1e18);

        vm.startPrank(ALICE);
        MockERC20(TOKEN).approve(address(payments), type(uint256).max);
        payments.deposit(TOKEN, 500e18);
        payments.deposit{value: 3e18}();
        payments.authorize(OPERATOR, CREATE_RAIL);
        payments.authorize(CAROL, ALL);
        vm.stopPrank();

        vm.startPrank(BOB);
        MockERC20(TOKEN).approve(address(payments), type(uint256).max);
        payments.deposit(TOKEN, 200e18);
        payments.deposit{value: 1e18}();
        payments.authorize(OPERATOR, CREATE_RAIL | TRANSFER);
        vm.stopPrank();

        vm.startPrank(OPERATOR);
        payments.createRail(ALICE, BOB, 1, TOKEN_ID);

        vm.roll(1010);
        payments.modifyRate(ALICE, BOB, 1, TOKEN_ID, 5e15);
        payments.lock(ALICE, BOB, 1, TOKEN_ID, 10e18);

        // OPERATOR has no code to answer IRailV2.settleRail: a settle spanning no epochs never calls it
        vm.roll(1020);
        payments.createRail(ALICE, BOB, FLAG_CALLBACK | 2, TOKEN_ID);
        payments.modifyRate(ALICE, BOB, FLAG_CALLBACK | 2, TOKEN_ID, 3e15);
        payments.lock(ALICE, BOB, FLAG_CALLBACK | 2, TOKEN_ID, 20e18);

        vm.roll(1030);
        payments.createRail(ALICE, CAROL, 3, NATIVE_TOKEN);
        payments.modifyRate(ALICE, CAROL, 3, NATIVE_TOKEN, 7e12);
        payments.lock(ALICE, CAROL, 3, NATIVE_TOKEN, 0.5e18);

        vm.roll(1040);
        payments.settleRail(OPERATOR, ALICE, BOB, 1, TOKEN_ID);
        vm.roll(1050);
        payments.settleRail(OPERATOR, ALICE, CAROL, 3, NATIVE_TOKEN);
        vm.stopPrank();
    }

    function run() public {
        require(vm.isContext(VmSafe.ForgeContext.ScriptDryRun), NotDryRun());

        require(
            _userSlot(ALICE) == 0x3e37386a03f45c688560b8782ec465a97cb1243fd074f4023f67a690faa9f9ce, UserSlotChanged()
        );
        require(
            _accountSlot(ALICE, TOKEN_ID) == 0x43534bc6586293c75dc1bcb6b28331f9733d3a31504b1a9059e00c5784d42795,
            AccountSlotChanged()
        );
        require(
            _permissionsSlot(ALICE, OPERATOR) == 0x1c90174af6b8577a7e4c7525ecf4c3175e4b2a67818c0de9b0abd5b6f592ebc6,
            PermissionsSlotChanged()
        );

        _user(ALICE);
        _user(BOB);
        _user(CAROL);

        _account(ALICE, NATIVE_TOKEN);
        _account(ALICE, TOKEN_ID);
        _account(BOB, NATIVE_TOKEN);
        _account(BOB, TOKEN_ID);
        _account(CAROL, NATIVE_TOKEN);

        _permissions(ALICE, OPERATOR);
        _permissions(ALICE, CAROL);
        _permissions(BOB, OPERATOR);

        _rail(OPERATOR, ALICE, TOKEN_ID, BOB, 1);
        _rail(OPERATOR, ALICE, TOKEN_ID, BOB, FLAG_CALLBACK | 2);
        _rail(OPERATOR, ALICE, NATIVE_TOKEN, CAROL, 3);

        _packedCheckpoint(type(uint128).max, type(uint88).max, type(uint40).max);
        _packedCheckpoint(COUNTING_U128, COUNTING_U88, COUNTING_U40);
        _packedCheckpoint(type(uint128).max, 0, 0);
        _packedCheckpoint(0, type(uint88).max, 0);
        _packedCheckpoint(0, 0, type(uint40).max);

        _packedStream(type(uint88).max, type(uint40).max, type(uint128).max);
        _packedStream(COUNTING_U88, COUNTING_U40, COUNTING_U128);
        _packedStream(type(uint88).max, 0, 0);
        _packedStream(0, type(uint40).max, 0);
        _packedStream(0, 0, type(uint128).max);

        vm.serializeString("packing", "checkpoints", packedCheckpoints);
        vm.serializeString("root", "packing", vm.serializeString("packing", "streams", packedStreams));
        vm.serializeString("root", "users", users);
        vm.serializeString("root", "accounts", accounts);
        vm.serializeString("root", "permissions", permissions);
        vm.writeJson(vm.serializeString("root", "rails", rails), PATH);
    }

    function _userSlot(address owner) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, USERS_SLOT));
    }

    /// @dev User.accounts is the user's first slot
    function _accountSlot(address owner, uint256 token) internal pure returns (bytes32) {
        return keccak256(abi.encode(token, _userSlot(owner)));
    }

    /// @dev User.authorizations is the user's second slot
    function _permissionsSlot(address owner, address operator) internal pure returns (bytes32) {
        return keccak256(abi.encode(operator, uint256(_userSlot(owner)) + 1));
    }

    function _unpackCheckpoint(bytes32 word) internal pure returns (Checkpoint memory checkpoint) {
        checkpoint.balance = uint128(uint256(word));
        checkpoint.drainRate = uint88(uint256(word) >> 128);
        checkpoint.modifiedEpoch = uint40(uint256(word) >> 216);
    }

    function _unpackStream(bytes32 word) internal pure returns (StreamState memory state) {
        state.incomingRate = uint88(uint256(word));
        state.settledUpTo = uint40(uint256(word) >> 88);
        state.available = uint128(uint256(word) >> 128);
    }

    function _load(bytes32 slot) internal view returns (bytes32 word) {
        word = payments.extsload(slot);
        require(word != bytes32(0), EmptySlot(slot));
    }

    function _user(address owner) internal {
        string memory key = string.concat("user.", vm.toString(users.length));
        vm.serializeAddress(key, "owner", owner);
        users.push(vm.serializeBytes32(key, "slot", _userSlot(owner)));
    }

    function _account(address owner, uint256 token) internal {
        bytes32 slot = _accountSlot(owner, token);
        bytes32 word = _load(slot);
        Checkpoint memory checkpoint = _unpackCheckpoint(word);
        Checkpoint memory latest = payments.latest(owner, token);
        require(
            checkpoint.balance == latest.balance && checkpoint.drainRate == latest.drainRate
                && checkpoint.modifiedEpoch == latest.modifiedEpoch,
            CheckpointMismatch(slot)
        );

        string memory key = string.concat("account.", vm.toString(accounts.length));
        vm.serializeAddress(key, "owner", owner);
        vm.serializeAddress(key, "token", address(uint160(token)));
        vm.serializeBytes32(key, "slot", slot);
        accounts.push(_checkpoint(key, word, checkpoint));
    }

    function _permissions(address owner, address operator) internal {
        bytes32 slot = _permissionsSlot(owner, operator);
        bytes32 word = _load(slot);
        require(Permissions.wrap(uint256(word)) == payments.permissions(owner, operator), PermissionsMismatch(slot));

        string memory key = string.concat("permissions.", vm.toString(permissions.length));
        vm.serializeAddress(key, "owner", owner);
        vm.serializeAddress(key, "operator", operator);
        vm.serializeBytes32(key, "slot", slot);
        vm.serializeBytes32(key, "word", word);
        permissions.push(_uint(key, "permissions", abi.encodePacked(uint256(word))));
    }

    function _rail(address operator, address from, uint256 token, address recipient, uint64 nonce) internal {
        bytes32 railId = keccak256(abi.encodePacked(operator, from, address(uint160(token)), recipient, nonce));
        require(
            uint256(railId) == RailId.unwrap(operator.deriveRail(from, recipient, token, nonce).getRailId()),
            RailIdChanged()
        );
        bytes32 word = _load(railId);
        StreamState memory state = _unpackStream(word);
        StreamState memory stored = payments.getRail(RailId.wrap(uint256(railId)));
        require(
            state.incomingRate == stored.incomingRate && state.settledUpTo == stored.settledUpTo
                && state.available == stored.available,
            StreamMismatch(railId)
        );

        string memory key = string.concat("rail.", vm.toString(rails.length));
        vm.serializeAddress(key, "operator", operator);
        vm.serializeAddress(key, "from", from);
        vm.serializeAddress(key, "token", address(uint160(token)));
        vm.serializeAddress(key, "recipient", recipient);
        _uint(key, "nonce", abi.encodePacked(nonce));
        vm.serializeBytes32(key, "railId", railId);
        rails.push(_stream(key, word, state));
    }

    function _packedCheckpoint(uint128 balance, uint88 drainRate, uint40 modifiedEpoch) internal {
        packedCheckpoint = Checkpoint({balance: balance, drainRate: drainRate, modifiedEpoch: modifiedEpoch});
        bytes32 word;
        assembly ("memory-safe") {
            word := sload(packedCheckpoint.slot)
        }
        Checkpoint memory checkpoint = _unpackCheckpoint(word);
        require(
            checkpoint.balance == balance && checkpoint.drainRate == drainRate
                && checkpoint.modifiedEpoch == modifiedEpoch,
            CheckpointPackingChanged(word)
        );
        packedCheckpoints.push(
            _checkpoint(string.concat("packing.checkpoint.", vm.toString(packedCheckpoints.length)), word, checkpoint)
        );
    }

    function _packedStream(uint88 incomingRate, uint40 settledUpTo, uint128 available) internal {
        packedStream = StreamState({incomingRate: incomingRate, settledUpTo: settledUpTo, available: available});
        bytes32 word;
        assembly ("memory-safe") {
            word := sload(packedStream.slot)
        }
        StreamState memory state = _unpackStream(word);
        require(
            state.incomingRate == incomingRate && state.settledUpTo == settledUpTo && state.available == available,
            StreamPackingChanged(word)
        );
        packedStreams.push(_stream(string.concat("packing.stream.", vm.toString(packedStreams.length)), word, state));
    }

    function _checkpoint(string memory key, bytes32 word, Checkpoint memory checkpoint)
        internal
        returns (string memory)
    {
        vm.serializeBytes32(key, "word", word);
        _uint(key, "balance", abi.encodePacked(checkpoint.balance));
        _uint(key, "drainRate", abi.encodePacked(checkpoint.drainRate));
        return _uint(key, "modifiedEpoch", abi.encodePacked(checkpoint.modifiedEpoch));
    }

    function _stream(string memory key, bytes32 word, StreamState memory state) internal returns (string memory) {
        vm.serializeBytes32(key, "word", word);
        _uint(key, "incomingRate", abi.encodePacked(state.incomingRate));
        _uint(key, "settledUpTo", abi.encodePacked(state.settledUpTo));
        return _uint(key, "available", abi.encodePacked(state.available));
    }

    /// @dev integers are hex padded to the width of their type, which shows the type and lines the
    /// field up with the raw bytes beside it
    function _uint(string memory key, string memory name, bytes memory packed) internal returns (string memory) {
        return vm.serializeBytes(key, name, packed);
    }
}
