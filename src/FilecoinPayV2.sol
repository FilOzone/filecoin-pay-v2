// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {IERC165} from "forge-std/interfaces/IERC165.sol";
import {IERC6909} from "forge-std/interfaces/IERC6909.sol";

import {IRailV2} from "./interfaces/IRail.sol";
import "./lib/FilecoinPayOps.sol" as Ops;
import {ALL, CREATE_RAIL, NONE, Permissions} from "./lib/Permissions.sol";
import {FLAG_CALLBACK, RailId, RailIdLibrary, Stream, StreamState} from "./lib/RailId.sol";
import {ScriptReading} from "./lib/Script.sol";

contract FilecoinPayV2 is IERC6909 {
    using ScriptReading for bytes;
    using ScriptReading for uint256;
    using RailIdLibrary for address;

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


    function settleRail(
        address operator, address from, uint192 flags, uint256 token
    )
        external
        returns (uint256 amount)
    {
        RailId railId = operator.deriveRail(from, flags);
        Stream storage stream = railId.getStream(token);
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
                bytes memory script = IRailV2(operator).settleRail(railId, token, prevSettledEpoch, settleUpTo, prevBalance, amount);
                (uint256 curr, uint256 end) = script.memoryIter();
                _dispatch(Auth({authenticated: operator, permissions: ALL, token: token /*stream: stream*/}), curr, end);
            } else {
                address recipient = address(uint160(flags));
                stream.state = loadedStream;
                users[recipient].accounts[token].latest.balance += uint128(amount);
            }
        }
    }

    error Exists();

    function createRail(
        address from,
        uint192 flags,
        uint256 token
    ) external {
        Stream storage stream = msg.sender.deriveRail(from, flags).getStream(token);
        require(stream.state.settledUpTo == 0, Exists());
        require(users[from].authorizations[msg.sender].permissions & CREATE_RAIL != NONE, Unauthorized(from, msg.sender));
        stream.state.settledUpTo = uint40(block.number);
    }

    struct Auth {
        address authenticated;
        Permissions permissions;
        uint256 token;
    }
    error Unauthorized(address user, address operator);

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

    function _dispatch(Auth memory auth, uint256 curr, uint256 end) internal returns (uint256) {
        while (curr < end) {
            uint256 method;
            (method, curr) = curr.nextByte();
            if (method < 8) {
                if (method < 4) {
                    if (method < 2) {
                        if (method == Ops.POP) {
                            // Ops.POP
                            return curr;
                        } else {
                            // Ops.PUSH
                            // TODO(perf): mcopy
                            Auth memory next = Auth({authenticated: auth.authenticated, permissions: auth.permissions, token: auth.token});
                            curr = _dispatch(next, curr, end);
                        }
                    } else {
                        if (method == Ops.RESET) {
                            // Ops.RESET
                            auth.authenticated = msg.sender;
                            auth.permissions = ALL;
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
                        // 4 5
                    } else {
                        // 6 7
                    }
                }
            } else {
                // 8 9 10 11 12 13 14 15
            }
        }
        return curr;
    }
}
