// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {IERC165} from "forge-std/interfaces/IERC165.sol";
import {IERC6909} from "forge-std/interfaces/IERC6909.sol";

import {IRailV2} from "./interfaces/IRail.sol";
import "./lib/Script.sol" as Ops;
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {Extsload} from "./Extsload.sol";
import {ALL, CREATE_RAIL, DEPOSIT, DEPOSIT_TO, NONE, Permissions} from "./lib/Permissions.sol";
import {FLAG_CALLBACK, RailId, RailIdLibrary, Stream, StreamState} from "./lib/RailId.sol";
import {ScriptReading} from "./lib/ScriptReading.sol";

/// @dev an allowance of INFINITE is never decremented
uint256 constant INFINITE = type(uint256).max;

contract FilecoinPayV2 is Extsload, IERC6909 {
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

    error InvalidToken();

    function _validateToken(uint256 token) internal pure {
        require(token >> 160 == 0, InvalidToken());
    }

    modifier validToken(uint256 token) {
        _validateToken(token);
        _;
    }

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
    function approve(address spender, uint256 token, uint256 amount) external validToken(token) returns (bool) {
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
    function transfer(address recipient, uint256 token, uint256 amount) external validToken(token) returns (bool) {
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
    function transferFrom(address owner, address recipient, uint256 token, uint256 amount)
        external
        validToken(token)
        returns (bool)
    {
        User storage from = users[owner];
        Account storage debit = from.accounts[token];
        if (!from.authorizations[msg.sender].permissions.isOperator()) {
            uint256 approved = debit.allowance[msg.sender];
            if (approved != INFINITE) {
                debit.allowance[msg.sender] = approved - amount;
            }
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
        _credit(msg.sender, 0, msg.value);
    }

    function depositTo(address recipient) public payable {
        _credit(recipient, 0, msg.value);
    }

    function deposit(address token, uint256 amount) external {
        _depositTo(uint256(uint160(token)), msg.sender, msg.sender, amount);
    }

    function depositTo(address token, address recipient, uint256 amount) external {
        _depositTo(uint256(uint160(token)), msg.sender, recipient, amount);
    }

    function authorize(address operator, Permissions permissions) external {
        users[msg.sender].authorizations[operator].permissions = permissions;
        // emiting the event unconditionally avoids reading the prior state
        emit OperatorSet(msg.sender, operator, permissions.isOperator());
    }

    function settleRail(address operator, address from, address recipient, uint32 nonce, uint256 token)
        external
        validToken(token)
        returns (uint256 settledUpTo)
    {
        // TODO: check exists()
        return _settleRail(operator, from, recipient, nonce, token);
    }

    function _settleRail(address operator, address from, address recipient, uint32 nonce, uint256 token)
        internal
        returns (uint256 settledUpTo)
    {
        Stream storage stream = operator.deriveRail(from, recipient, token, nonce);
        StreamState memory loadedStream = stream.state;

        unchecked {
            settledUpTo = canSettleTo(users[from].accounts[token].latest);
            uint256 prevSettledEpoch = uint256(loadedStream.settledUpTo);
            uint256 blocks = settledUpTo - prevSettledEpoch;
            if (blocks == 0) {
                return settledUpTo;
            }

            loadedStream.settledUpTo = uint40(settledUpTo);

            uint256 amount = blocks * loadedStream.incomingRate;
            if (nonce & FLAG_CALLBACK != 0) {
                uint256 prevBalance = uint256(loadedStream.available);
                loadedStream.available = uint128(prevBalance + amount);
                stream.state = loadedStream;
                bytes memory script = IRailV2(operator)
                    .settleRail(stream.getRailId(), prevSettledEpoch, settledUpTo, prevBalance, amount);
                (uint256 curr, uint256 end) = script.memoryIter();
                _dispatch(
                    Auth({
                        authenticated: operator,
                        permissions: ALL,
                        from: from,
                        recipient: recipient,
                        nonce: nonce,
                        token: token
                    }),
                    curr,
                    end
                );
            } else {
                stream.state = loadedStream;
                users[recipient].accounts[token].latest.balance += uint128(amount);
                emit Transfer(operator, from, recipient, token, amount);
            }
        }
    }

    error RailNotCreated();

    function lock(address from, address recipient, uint32 nonce, uint256 token, uint256 amount)
        external
        validToken(token)
    {
        Stream storage stream = msg.sender.deriveRail(from, recipient, token, nonce);
        // TODO(perf): this duplicates the read of stream.state
        require(stream.exists(), RailNotCreated());
        _lock(stream, users[from].accounts[token], uint128(amount));
    }

    function _lock(Stream storage stream, Account storage from, uint128 amount) internal {
        Checkpoint memory latest = from.latest;
        require(current(latest) >= amount, InsufficientBalance());
        unchecked {
            latest.balance -= amount;
        }
        from.latest = latest;
        unchecked {
            stream.state.available += amount;
        }
    }

    function unlock(address from, address recipient, uint32 nonce, uint256 token, uint256 amount)
        external
        validToken(token)
    {
        Stream storage stream = msg.sender.deriveRail(from, recipient, token, nonce);
        // TODO(perf): this duplicates the read of stream.state
        require(stream.exists(), RailNotCreated());
        _unlock(stream, users[from].accounts[token], uint128(amount));
    }

    function _unlock(Stream storage stream, Account storage from, uint128 amount) internal {
        unchecked {
            from.latest.balance += amount;
        }
        // TODO(doc): defined error instead of stdErr.arithmeticError
        stream.state.available -= amount;
    }

    function terminateRail(address operator, address from, address recipient, uint32 nonce, uint256 token) public {
        require(msg.sender == operator || msg.sender == from, Unauthorized(from, msg.sender));
        Stream storage stream = operator.deriveRail(from, recipient, token, nonce);
        require(stream.exists(), RailNotCreated());

        uint256 settledUpTo = _settleRail(operator, from, recipient, nonce, token);

        StreamState memory state = stream.state;
        Account storage account = users[from].accounts[token];
        Checkpoint memory scratch = account.latest;
        // FIXME: lockup should go toward any debt before being refunded to the user
        unchecked {
            scratch.balance += state.available - uint128(scratch.drainRate)
            * uint128(settledUpTo - scratch.modifiedEpoch);
            scratch.drainRate -= state.incomingRate;
            scratch.modifiedEpoch = uint40(settledUpTo);
        }
        account.latest = scratch;
        delete stream.state;
    }

    error Behind();

    function modifyRate(address from, address recipient, uint32 nonce, uint256 token, uint88 rate)
        external
        validToken(token)
    {
        Stream storage stream = msg.sender.deriveRail(from, recipient, token, nonce);
        require(stream.exists(), RailNotCreated());

        // TODO(perf): this duplicates the deriveRail hashing
        // TODO(perf): this duplicates the stream sload
        uint256 settledUpTo = _settleRail(msg.sender, from, recipient, nonce, token);
        require(settledUpTo == block.number, Behind());

        // NOTE: must re-read this because it can change during _settleRail
        uint88 previousRate = stream.state.incomingRate;
        stream.state.incomingRate = rate;

        Account storage account = users[from].accounts[token];
        Checkpoint memory previous = account.latest;
        if (previous.modifiedEpoch != block.number) {
            unchecked {
                // NOTE: this cannot underflow
                previous.balance -= uint128(
                    (block.number - uint256(previous.modifiedEpoch)) * uint256(previous.drainRate)
                );
                previous.modifiedEpoch = uint40(block.number);
                previous.drainRate += rate - previousRate;
            }
        }
        account.latest = previous;
    }

    function disburse(address from, address recipient, uint32 nonce, uint256 token, uint128 amount)
        external
        validToken(token)
    {
        _disburse(msg.sender.deriveRail(from, recipient, token, nonce), msg.sender, from, recipient, token, amount);
    }

    function _disburse(
        Stream storage stream,
        address operator,
        address from,
        address recipient,
        uint256 token,
        uint128 amount
    ) internal {
        stream.state.available -= amount;
        unchecked {
            users[recipient].accounts[token].latest.balance += amount;
        }
        emit Transfer(operator, from, recipient, token, uint256(amount));
    }

    function _disburseAll(address operator, address from, address recipient, uint32 nonce, uint256 token) internal {
        Stream storage stream = operator.deriveRail(from, recipient, token, nonce);
        uint128 amount = stream.state.available;
        unchecked {
            users[recipient].accounts[token].latest.balance += amount;
        }
        stream.state.available = 0;
        emit Transfer(operator, from, recipient, token, uint256(amount));
    }

    error Exists();

    event RailCreated(
        address indexed payer,
        address indexed payee,
        address indexed operator,
        uint256 token,
        RailId railId,
        uint32 nonce
    );

    /// @param nonce high bit is FLAG_CALLBACK, settling through IRailV2 callbacks rather than to
    /// recipient; the low 31 bits distinguish rails sharing the other arguments
    function createRail(address from, address recipient, uint32 nonce, uint256 token)
        external
        validToken(token)
        returns (RailId railId)
    {
        Stream storage stream = msg.sender.deriveRail(from, recipient, token, nonce);
        require(!stream.exists(), Exists());
        require(
            users[from].authorizations[msg.sender].permissions & CREATE_RAIL != NONE, Unauthorized(from, msg.sender)
        );

        stream.init();
        railId = stream.getRailId();
        emit RailCreated(from, recipient, msg.sender, token, railId, nonce);
    }

    struct Auth {
        address authenticated;
        Permissions permissions;
        address from;
        address recipient;
        uint32 nonce;
        uint256 token;
    }
    error Unauthorized(address user, address operator);

    function _duplicate(Auth memory auth) internal pure returns (Auth memory next) {
        assembly ("memory-safe") {
            next := mload(0x40)
            mcopy(next, auth, 0xc0)
            mstore(0x40, add(next, 0xc0))
        }
    }

    function _copy(Auth memory dst, Auth memory src) internal pure {
        assembly ("memory-safe") {
            mcopy(dst, src, 0xc0)
        }
    }

    // recipient leads: callers hold it nearest the stack top, so the shared body needs the fewest swaps
    function _credit(address recipient, uint256 token, uint256 amount) internal {
        unchecked {
            users[recipient].accounts[token].latest.balance += uint128(amount);
        }
        emit Transfer(msg.sender, address(0), recipient, token, amount);
    }

    function _depositTo(uint256 token, address from, address recipient, uint256 amount) internal {
        _credit(recipient, token, amount);
        address(uint160(token)).safeTransferFrom(from, address(this), amount);
    }

    /**
     * Batch functions
     */

    function executeScript(bytes calldata script) external payable {
        if (msg.value > 0) {
            deposit();
        }
        (uint256 curr, uint256 end) = script.calldataIter();
        _dispatch(
            Auth({
                authenticated: msg.sender, permissions: ALL, from: address(0), recipient: address(0), nonce: 0, token: 0
            }),
            curr,
            end
        );
    }

    function executeScript(Permissions scope, bytes calldata script) external payable {
        if (msg.value > 0) {
            deposit();
        }
        (uint256 curr, uint256 end) = script.calldataIter();
        _dispatch(
            Auth({
                authenticated: msg.sender,
                permissions: scope,
                from: address(0),
                recipient: address(0),
                nonce: 0,
                token: 0
            }),
            curr,
            end
        );
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
                            uint128 amount;
                            (amount, curr) = curr.nextU128();
                            if (method == Ops.DEPOSIT) {
                                // Ops.DEPOSIT
                                require(
                                    auth.permissions & DEPOSIT != NONE, Unauthorized(auth.authenticated, msg.sender)
                                );
                                _depositTo(auth.token, auth.authenticated, auth.authenticated, amount);
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
                    if (method < 12) {
                        // 8 9 10 11
                    } else {
                        if (method < 14) {
                            uint128 amount;
                            (amount, curr) = curr.nextU128();
                            Stream storage stream =
                                auth.authenticated.deriveRail(auth.from, auth.recipient, auth.token, auth.nonce);
                            // TODO(perf): this duplicates the read of stream.state
                            require(stream.exists(), RailNotCreated());
                            if (method == Ops.LOCK) {
                                _lock(stream, users[auth.from].accounts[auth.token], amount);
                            } else {
                                // Ops.UNLOCK
                                _unlock(stream, users[auth.from].accounts[auth.token], amount);
                            }
                        } else {
                            // 14 15
                        }
                    }
                }
            } else {
                if (method < 24) {
                    if (method < 20) {
                        if (method < 18) {
                            if (method == Ops.TRANSFERALL) {} else {
                                // Ops.SETTLERAIL
                                address operator;
                                address from;
                                address recipient;
                                uint32 nonce;
                                (operator, curr) = curr.nextAddress();
                                (from, curr) = curr.nextAddress();
                                (recipient, curr) = curr.nextAddress();
                                (nonce, curr) = curr.nextU32();
                                // TODO: check exists()
                                _settleRail(operator, from, recipient, nonce, auth.token);
                            }
                        } else {
                            if (method == Ops.DISBURSEALL) {
                                _disburseAll(auth.authenticated, auth.from, auth.recipient, auth.nonce, auth.token);
                            } else {
                                // Ops.DISBURSE
                                uint128 amount;
                                (amount, curr) = curr.nextU128();
                                _disburse(
                                    auth.authenticated.deriveRail(auth.from, auth.recipient, auth.token, auth.nonce),
                                    auth.authenticated,
                                    auth.from,
                                    auth.recipient,
                                    auth.token,
                                    amount
                                );
                            }
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
