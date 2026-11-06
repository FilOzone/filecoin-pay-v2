// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {IERC165} from "forge-std/interfaces/IERC165.sol";
import {IERC6909} from "forge-std/interfaces/IERC6909.sol";

import {IRailV2} from "./interfaces/IRail.sol";
import "./lib/FilecoinPayOps.sol" as Ops;
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ALL, CREATE_RAIL, DEPOSIT, DEPOSIT_TO, NONE, Permissions} from "./lib/Permissions.sol";
import {FLAG_CALLBACK, RailIdLibrary, Stream, StreamState} from "./lib/RailId.sol";
import {ScriptReading} from "./lib/Script.sol";

contract FilecoinPayV2 is IERC6909 {
    using ScriptReading for bytes;
    using ScriptReading for uint256;
    using RailIdLibrary for address;
    using RailIdLibrary for Stream;
    using SafeTransferLib for address;

    struct Authorization {
        Permissions permissions;
    }

    struct Checkpoint {
        uint128 balance;
        uint88 drainRate;
        uint40 modifiedEpoch;
    }

    struct Account {
        Checkpoint latest;
        mapping(address spender => uint256) allowance;
    }

    struct User {
        mapping(uint256 token => Account) accounts;
        mapping(address authorized => Authorization) authorizations;
    }

    mapping(address owner => User) private users;

    function current(Checkpoint memory latest) internal view returns (uint256 balance) {
        unchecked {
            balance = uint256(latest.balance);
            uint256 drainRate = uint256(latest.drainRate);
            if (drainRate > 0) {
                uint256 drain = drainRate * (block.number - uint256(latest.modifiedEpoch));
                if (drain > balance) {
                    return 0;
                } else {
                    balance -= drain;
                }
            }
        }
    }

    function canSettleTo(Checkpoint memory latest) internal view returns (uint256 when) {
        unchecked {
            uint256 drainRate = uint256(latest.drainRate);
            if (drainRate == 0) {
                return block.number;
            }
            uint256 balance = uint256(latest.balance);
            when = uint256(latest.modifiedEpoch) + balance / drainRate;
            if (when > block.number) {
                return block.number;
            }
        }
    }

    /// @inheritdoc IERC6909
    function balanceOf(address owner, uint256 token) public view returns (uint256) {
        Account storage account = users[owner].accounts[token];
        Checkpoint memory balance = account.latest;
        return current(balance);
    }

    /// @inheritdoc IERC6909
    function isOperator(address owner, address spender) public view returns (bool) {
        return users[owner].authorizations[spender].permissions.isOperator();
    }

    /// @inheritdoc IERC6909
    function allowance(address owner, address spender, uint256 token) public view returns (uint256) {
        return users[owner].accounts[token].allowance[spender];
    }

    /// @inheritdoc IERC6909
    function setOperator(address spender, bool approved) external returns (bool) {
        Authorization storage authorization = users[msg.sender].authorizations[spender];
        authorization.permissions = authorization.permissions.setIsOperator(approved);
        emit OperatorSet(msg.sender, spender, approved);
        return true;
    }

    /// @inheritdoc IERC6909
    function approve(address spender, uint256 token, uint256 amount) external returns (bool) {
        users[msg.sender].accounts[token].allowance[spender] = amount;
        emit Approval(msg.sender, spender, token, amount);
        return true;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure returns (bool supported) {
        return interfaceId == 0x0f632fb3 || interfaceId == 0x01ffc9a7;
    }

    error InsufficientBalance();

    /// @inheritdoc IERC6909
    function transfer(address recipient, uint256 token, uint256 amount) external returns (bool) {
        Account storage spender = users[msg.sender].accounts[token];
        Checkpoint memory spenderBalance = spender.latest;
        require(current(spenderBalance) >= amount, InsufficientBalance());
        unchecked {
            spenderBalance.balance -= uint128(amount);
        }
        spender.latest = spenderBalance;

        unchecked {
            users[recipient].accounts[token].latest.balance += uint128(amount);
        }
        emit Transfer(msg.sender, msg.sender, recipient, token, amount);
        return true;
    }

    /// @inheritdoc IERC6909
    function transferFrom(address owner, address recipient, uint256 token, uint256 amount) external returns (bool) {
        User storage from = users[owner];
        Account storage debit = from.accounts[token];
        if (!from.authorizations[msg.sender].permissions.isOperator()) {
            // TODO handle "infinite" allowance
            debit.allowance[msg.sender] -= amount;
        }
        Checkpoint memory spenderBalance = debit.latest;
        require(current(spenderBalance) >= amount, InsufficientBalance());
        unchecked {
            spenderBalance.balance -= uint128(amount);
        }
        debit.latest = spenderBalance;
        unchecked {
            users[recipient].accounts[token].latest.balance += uint128(amount);
        }
        emit Transfer(msg.sender, owner, recipient, token, amount);
        return true;
    }

    function deposit() public payable {
        unchecked {
            users[msg.sender].accounts[0].latest.balance += uint128(msg.value);
        }
    }

    function depositTo(address recipient) public payable {
        unchecked {
            users[recipient].accounts[0].latest.balance += uint128(msg.value);
        }
    }

    function deposit(address token, uint256 amount) external {
        _deposit(uint256(uint160(token)), msg.sender, amount);
    }

    function depositTo(address token, address recipient, uint256 amount) external {
        _depositTo(uint256(uint160(token)), msg.sender, recipient, amount);
    }

    function authorize(address operator, Permissions permissions) external {
        users[msg.sender].authorizations[operator].permissions = permissions;
        emit OperatorSet(msg.sender, operator, permissions.isOperator());
    }

    function settleRail(address operator, address from, uint192 flags, uint256 token) public returns (uint256 amount) {
        Stream storage stream = operator.deriveRail(from, token, flags);
        StreamState memory loadedStream = stream.state;

        unchecked {
            uint256 settleUpTo = canSettleTo(users[from].accounts[token].latest);
            uint256 prevSettledEpoch = uint256(loadedStream.settledUpTo);
            uint256 blocks = settleUpTo - prevSettledEpoch;
            if (blocks == 0) {
                return 0;
            }

            loadedStream.settledUpTo = uint40(settleUpTo);

            amount = blocks * loadedStream.incomingRate;
            emit Transfer(operator, from, operator, token, amount);
            if (flags & FLAG_CALLBACK != 0) {
                uint256 prevBalance = uint256(loadedStream.available);
                loadedStream.available = uint128(prevBalance + amount);
                stream.state = loadedStream;
                // TODO determine whether to allow separate validator
                // validator = address(uint160(operator))
                bytes memory script =
                    IRailV2(operator).settleRail(stream.getRailId(), prevSettledEpoch, settleUpTo, prevBalance, amount);
                (uint256 curr, uint256 end) = script.memoryIter();
                _dispatch(
                    Auth({
                        authenticated: operator,
                        permissions: ALL,
                        token: token /*stream: stream*/
                    }),
                    curr,
                    end
                );
            } else {
                address recipient = address(uint160(flags));
                stream.state = loadedStream;
                users[recipient].accounts[token].latest.balance += uint128(amount);
            }
        }
    }

    error RailNotCreated();

    function lock(address from, uint192 flags, uint256 token, uint256 amount) external {
        Stream storage stream = msg.sender.deriveRail(from, token, flags);
        require(stream.state.settledUpTo != 0, RailNotCreated());
        _lock(stream, users[from].accounts[token], uint128(amount));
    }

    function _lock(Stream storage stream, Account storage from, uint128 amount) internal {
        Checkpoint memory latest = from.latest;
        require(current(latest) >= amount, InsufficientBalance());
        latest.balance -= amount;
        from.latest = latest;
        unchecked {
            stream.state.available += amount;
        }
    }

    function unlock(address from, uint192 flags, uint256 token, uint256 amount) external {
        Stream storage stream = msg.sender.deriveRail(from, token, flags);
        require(stream.state.settledUpTo != 0, RailNotCreated());
        Account storage from = users[from].accounts[token];
        _unlock(stream, from, uint128(amount));
    }

    function _unlock(Stream storage stream, Account storage from, uint128 amount) internal {
        from.latest.balance += amount;
        stream.state.available -= amount;
    }

    function modifyRate(address from, uint192 flags, uint256 token, uint256 rate) external {
        settleRail(msg.sender, from, flags, token);

        // TODO(perf): this duplicates the deriveRail hashing
        Stream storage stream = msg.sender.deriveRail(from, token, flags);
        require(stream.state.settledUpTo != 0, RailNotCreated());
        Account storage from = users[from].accounts[token];
        _modifyRate(stream, uint88(rate));
    }

    error Behind();

    function _modifyRate(Stream storage stream, uint88 rate) internal {
        require(stream.state.settledUpTo == block.number, Behind());
        stream.state.incomingRate = rate;
    }

    error Exists();

    function createRail(address from, uint192 flags, uint256 token) external {
        StreamState storage state = msg.sender.deriveRail(from, token, flags).state;
        require(state.settledUpTo == 0, Exists());
        require(
            users[from].authorizations[msg.sender].permissions & CREATE_RAIL != NONE, Unauthorized(from, msg.sender)
        );
        state.settledUpTo = uint40(block.number);
    }

    struct Auth {
        address authenticated;
        Permissions permissions;
        uint256 token;
    }
    error Unauthorized(address user, address operator);

    function _duplicate(Auth memory auth) internal pure returns (Auth memory next) {
        assembly ("memory-safe") {
            next := mload(0x40)
            mcopy(next, auth, 0x60)
            mstore(0x40, add(next, 0x60))
        }
    }

    function _copy(Auth memory dst, Auth memory src) internal pure {
        assembly ("memory-safe") {
            mcopy(dst, src, 0x60)
        }
    }

    function _deposit(uint256 token, address owner, uint256 amount) internal {
        unchecked {
            users[owner].accounts[token].latest.balance += uint128(amount);
        }
        emit Transfer(msg.sender, address(0), owner, token, amount);
        address(uint160(token)).safeTransferFrom(owner, address(this), amount);
    }

    function _depositTo(uint256 token, address from, address recipient, uint256 amount) internal {
        unchecked {
            users[recipient].accounts[token].latest.balance += uint128(amount);
        }
        emit Transfer(msg.sender, address(0), recipient, token, amount);
        address(uint160(token)).safeTransferFrom(from, address(this), amount);
    }

    /**
     * Batch functions
     */

    function executeScript(bytes calldata script) external {
        (uint256 curr, uint256 end) = script.calldataIter();
        _dispatch(Auth({authenticated: msg.sender, permissions: ALL, token: 0}), curr, end);
    }

    function executeScript(Permissions scope, bytes calldata script) external {
        (uint256 curr, uint256 end) = script.calldataIter();
        _dispatch(Auth({authenticated: msg.sender, permissions: scope, token: 0}), curr, end);
    }

    function depositWithScript(Permissions scope, bytes calldata script) external payable {
        deposit();
        (uint256 curr, uint256 end) = script.calldataIter();
        _dispatch(Auth({authenticated: msg.sender, permissions: scope, token: 0}), curr, end);
    }

    function _dispatch(Auth memory startingAuth, uint256 curr, uint256 end) internal returns (uint256) {
        Auth memory auth = _duplicate(startingAuth);
        while (curr < end) {
            uint256 method;
            (method, curr) = curr.nextByte();

            // switch(method)

            if (method < 16) {
                if (method < 8) {
                    if (method < 4) {
                        if (method < 2) {
                            if (method == Ops.POP) {
                                // Ops.POP
                                return curr;
                            } else {
                                // Ops.PUSH
                                curr = _dispatch(auth, curr, end);
                            }
                        } else {
                            if (method == Ops.RESET) {
                                // Ops.RESET
                                _copy(auth, startingAuth);
                            } else {
                                // Ops.SUDO
                                address who;
                                (who, curr) = curr.nextAddress();
                                Permissions permissions =
                                    users[who].authorizations[auth.authenticated].permissions & auth.permissions;
                                require(permissions != NONE, Unauthorized(who, auth.authenticated));
                                auth.authenticated = who;
                                auth.permissions = permissions;
                            }
                        }
                    } else {
                        if (method < 6) {
                            if (method == Ops.SETTOKEN) {
                                // Ops.SETTOKEN
                                address token;
                                (token, curr) = curr.nextAddress();
                                auth.token = uint256(uint160(token));
                            } else {
                                // 5
                            }
                        } else {
                            uint256 amount;
                            (amount, curr) = curr.nextU256();
                            if (method == Ops.DEPOSIT) {
                                // Ops.DEPOSIT
                                require(
                                    auth.permissions & DEPOSIT != NONE, Unauthorized(auth.authenticated, msg.sender)
                                );
                                _deposit(auth.token, auth.authenticated, amount);
                            } else {
                                // Ops.DEPOSITTO
                                require(
                                    auth.permissions & DEPOSIT_TO == DEPOSIT_TO,
                                    Unauthorized(auth.authenticated, msg.sender)
                                );
                                address recipient;
                                (recipient, curr) = curr.nextAddress();
                                _depositTo(auth.token, auth.authenticated, recipient, amount);
                            }
                        }
                    }
                } else {
                    // 8 9 10 11 12 13 14 15
                }
            } else {
                if (method < 24) {
                    if (method < 20) {
                        if (method < 18) {
                            if (method == Ops.TRANSFERALL) {} else {
                                // Ops.SETTLERAIL
                                address operator;
                                address from;
                                uint192 flags;
                                (operator, curr) = curr.nextAddress();
                                (from, curr) = curr.nextAddress();
                                (flags, curr) = curr.nextU192();
                                settleRail(operator, from, flags, auth.token);
                            }
                        } else {
                            // 18 19
                        }
                    } else {
                        // 20 21 22 23
                    }
                } else {
                    // 24 25 26 27 28 29 30 31
                }
            }
        }
        return curr;
    }
}
