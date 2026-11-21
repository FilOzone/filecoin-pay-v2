// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {IERC165} from "forge-std/interfaces/IERC165.sol";
import {IERC6909} from "forge-std/interfaces/IERC6909.sol";

import {FVMPay} from "fvm-solidity/FVMPay.sol";

import {IRailV2} from "./interfaces/IRail.sol";
import "./lib/Script.sol" as Ops;
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {Auction} from "./Auction.sol";
import {Extsload} from "./Extsload.sol";
import {IFilecoinPayV2} from "./interfaces/IFilecoinPayV2.sol";
import {IWFIL} from "./interfaces/IWFIL.sol";
import {
    ALL,
    AUTHORIZE_U256,
    CREATE_RAIL,
    CREATE_RAIL_U256,
    DEPOSIT_TO_U256,
    DEPOSIT_U256,
    NONE,
    Permissions,
    TRANSFER_U256,
    WITHDRAW_TO_U256,
    WITHDRAW_U256
} from "./lib/Permissions.sol";
import {FLAG_CALLBACK, RailId, RailIdLibrary, Stream, StreamState} from "./lib/RailId.sol";
import {ScriptReading} from "./lib/ScriptReading.sol";
import {Account, Checkpoint, User} from "./lib/User.sol";

/// @dev an allowance of INFINITE is never decremented
uint256 constant INFINITE = type(uint256).max;

/// @dev one byte per op, indexed by the op: the Permissions the dispatcher requires of it
uint256 constant PERMISSION_BY_OP = (AUTHORIZE_U256 << (8 * Ops.AUTHORIZE)) | (WITHDRAW_U256 << (8 * Ops.WITHDRAW))
    | (DEPOSIT_U256 << (8 * Ops.DEPOSIT)) | (WITHDRAW_TO_U256 << (8 * Ops.WITHDRAWTO))
    | (DEPOSIT_TO_U256 << (8 * Ops.DEPOSITTO)) | (TRANSFER_U256 << (8 * Ops.TRANSFER))
    | (TRANSFER_U256 << (8 * Ops.TRANSFERFROM)) | (TRANSFER_U256 << (8 * Ops.TRANSFERALL))
    | (CREATE_RAIL_U256 << (8 * Ops.TERMINATERAIL)) | (CREATE_RAIL_U256 << (8 * Ops.TERMINATERAILBY));

contract FilecoinPayV2 is Extsload, IFilecoinPayV2 {
    using ScriptReading for bytes;
    using ScriptReading for uint256;
    using RailIdLibrary for address;
    using RailIdLibrary for Stream;
    using RailIdLibrary for StreamState;
    using FVMPay for address;
    using SafeTransferLib for address;

    mapping(address owner => User) private users;

    error InvalidToken();

    /// @custom:solar-inline always
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

    event Authorized(address indexed user, address indexed operator, Permissions permissions);

    /// @inheritdoc IERC6909
    function setOperator(address spender, bool approved) external returns (bool) {
        _authorize(msg.sender, spender, users[msg.sender].authorizations[spender].permissions.setIsOperator(approved));
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
        return _move(users[msg.sender].accounts[token], recipient, msg.sender, token, amount);
    }

    /// @inheritdoc IERC6909
    function transferFrom(address owner, address recipient, uint256 token, uint256 amount)
        external
        validToken(token)
        returns (bool)
    {
        return _transferFrom(msg.sender, owner, recipient, token, amount);
    }

    function _transferFrom(address spender, address owner, address recipient, uint256 token, uint256 amount)
        internal
        returns (bool)
    {
        User storage from = users[owner];
        Account storage debit = from.accounts[token];
        if (!from.authorizations[spender].permissions.isOperator()) {
            uint256 approved = debit.allowance[spender];
            if (approved != INFINITE) {
                debit.allowance[spender] = approved - amount;
            }
        }
        return _move(debit, recipient, owner, token, amount);
    }

    function deposit() public payable {
        _credit(msg.sender, address(0), 0, msg.value);
    }

    function depositTo(address recipient) public payable {
        _credit(recipient, address(0), 0, msg.value);
    }

    function deposit(address token, uint256 amount) external {
        _depositTo(uint256(uint160(token)), msg.sender, msg.sender, amount);
    }

    function depositTo(address token, address recipient, uint256 amount) external {
        _depositTo(uint256(uint160(token)), msg.sender, recipient, amount);
    }

    /// @param token address(0) withdraws native FIL
    function withdraw(address token, uint256 amount) external {
        _withdrawTo(uint256(uint160(token)), msg.sender, msg.sender, amount);
    }

    /// @param token address(0) withdraws native FIL
    function withdrawTo(address token, address recipient, uint256 amount) external {
        _withdrawTo(uint256(uint160(token)), msg.sender, recipient, amount);
    }

    function authorize(address operator, Permissions permissions) external {
        _authorize(msg.sender, operator, permissions);
    }

    function _authorize(address owner, address operator, Permissions permissions) internal {
        users[owner].authorizations[operator].permissions = permissions;
        // emiting the event unconditionally avoids reading the prior state
        emit Authorized(owner, operator, permissions);
        emit OperatorSet(owner, operator, permissions.isOperator());
    }

    error RailNotCreated();

    function settleRail(address operator, address from, address recipient, uint64 nonce, uint256 token)
        external
        validToken(token)
        returns (uint256 settledUpTo)
    {
        return _settleRail(operator, from, recipient, nonce, token);
    }

    function _settleRail(address operator, address from, address recipient, uint64 nonce, uint256 token)
        internal
        returns (uint256 settledUpTo)
    {
        return _settleStream(
            operator.deriveRail(from, recipient, token, nonce), operator, from, recipient, nonce, token
        );
    }

    event RailSettled(RailId indexed railId, uint256 settledUpTo, uint256 amount);

    /// @dev for callers that already hold the rail, so the derivation is not paid twice
    /// @return settledUpTo this settle's reach, possibly stale due to the callback
    function _settleStream(
        Stream storage stream,
        address operator,
        address from,
        address recipient,
        uint64 nonce,
        uint256 token
    ) internal returns (uint256 settledUpTo) {
        StreamState memory loadedStream = stream.state;
        require(loadedStream.exists(), RailNotCreated());

        unchecked {
            settledUpTo = canSettleTo(users[from].accounts[token].latest);
            uint256 prevSettledEpoch = uint256(loadedStream.settledUpTo);
            uint256 blocks = settledUpTo - prevSettledEpoch;
            if (blocks == 0) {
                return settledUpTo;
            }

            loadedStream.settledUpTo = uint40(settledUpTo);

            uint256 amount = blocks * loadedStream.incomingRate;
            emit RailSettled(stream.getRailId(), settledUpTo, amount);
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
                if (amount > 0) {
                    _creditWithFee(recipient, operator, from, token, amount);
                }
            }
        }
    }

    function lock(address from, address recipient, uint64 nonce, uint256 token, uint256 amount)
        external
        validToken(token)
    {
        _lockup(from, recipient, nonce, token, amount, true);
    }

    /// @param add moves the payer's balance into the lockup; otherwise the lockup back to the payer
    function _lockup(Stream storage stream, Account storage from, uint128 amount, bool add) internal {
        if (add) {
            Checkpoint memory latest = from.latest;
            require(current(latest) >= amount, InsufficientBalance());
            unchecked {
                latest.balance -= amount;
            }
            from.latest = latest;
            unchecked {
                stream.state.available += amount;
            }
        } else {
            unchecked {
                from.latest.balance += amount;
            }
            // TODO(doc): defined error instead of stdErr.arithmeticError
            stream.state.available -= amount;
        }
    }

    function unlock(address from, address recipient, uint64 nonce, uint256 token, uint256 amount)
        external
        validToken(token)
    {
        _lockup(from, recipient, nonce, token, amount, false);
    }

    function _lockup(address from, address recipient, uint64 nonce, uint256 token, uint256 amount, bool add) internal {
        _lockup(
            _existingRail(msg.sender, from, recipient, token, nonce), users[from].accounts[token], uint128(amount), add
        );
    }

    function terminateRail(address operator, address from, address recipient, uint64 nonce, uint256 token) public {
        require(msg.sender == operator || msg.sender == from, Unauthorized(from, msg.sender));
        _terminateRail(operator, from, recipient, nonce, token, msg.sender);
    }

    event RailTerminated(RailId indexed railId, address terminator);

    /// @dev either side of the rail may terminate it, so a caller has to be one of them: the
    /// dispatcher proves it by deriving the rail from the identity its script authenticated as
    function _terminateRail(
        address operator,
        address from,
        address recipient,
        uint64 nonce,
        uint256 token,
        address terminator
    ) internal {
        Stream storage stream = operator.deriveRail(from, recipient, token, nonce);

        _settleStream(stream, operator, from, recipient, nonce, token);
        emit RailTerminated(stream.getRailId(), terminator);

        StreamState memory state = stream.state;
        // not the epoch _settleStream returned: its script may have settled the rail again
        uint256 settledUpTo = uint256(state.settledUpTo);
        Account storage account = users[from].accounts[token];
        Checkpoint memory scratch = account.latest;
        // settling stopped where the balance ran out, so the blocks after it are this rail's debt,
        // and the lockup answers for it before any of it goes back to the payer
        uint256 owed = (block.number - settledUpTo) * uint256(state.incomingRate);
        uint128 paid = uint128(owed);
        if (owed >= state.available || terminator == from) {
            paid = state.available;
        }
        // the script may have charged the payer past it; charging that span again underflows
        if (settledUpTo < scratch.modifiedEpoch) {
            settledUpTo = uint256(scratch.modifiedEpoch);
        }
        unchecked {
            scratch.balance += state.available - paid - uint128(scratch.drainRate)
            * uint128(settledUpTo - scratch.modifiedEpoch);
            scratch.drainRate -= state.incomingRate;
            scratch.modifiedEpoch = uint40(settledUpTo);
        }
        account.latest = scratch;
        delete stream.state;
        if (paid > 0) {
            _creditWithFee(recipient, operator, from, token, paid);
        }
    }

    error Behind();

    function modifyRate(address from, address recipient, uint64 nonce, uint256 token, uint88 rate)
        external
        validToken(token)
    {
        Stream storage stream = _settleForRate(msg.sender, from, recipient, nonce, token);
        _setRate(stream, users[from].accounts[token], stream.state.incomingRate, rate);
    }

    /// @dev settling first is what lets the new rate apply from this block on
    function _settleForRate(address operator, address from, address recipient, uint64 nonce, uint256 token)
        internal
        returns (Stream storage stream)
    {
        stream = operator.deriveRail(from, recipient, token, nonce);
        // _settleRail requires the rail exists
        require(_settleStream(stream, operator, from, recipient, nonce, token) == block.number, Behind());
    }

    event RailRateSet(RailId indexed railId, uint88 rate);

    /// @param previousRate must be read after settling, which a callback script can change
    function _setRate(Stream storage stream, Account storage account, uint88 previousRate, uint88 rate) internal {
        stream.state.incomingRate = rate;
        emit RailRateSet(stream.getRailId(), rate);

        Checkpoint memory previous = account.latest;
        if (previous.modifiedEpoch != block.number) {
            unchecked {
                // _settleForRate required settling to reach this block, bounding the drain by balance
                previous.balance -= uint128(
                    (block.number - uint256(previous.modifiedEpoch)) * uint256(previous.drainRate)
                );
                previous.modifiedEpoch = uint40(block.number);
            }
        }
        previous.drainRate = previous.drainRate - previousRate + rate;
        account.latest = previous;
    }

    function disburse(address from, address recipient, uint64 nonce, uint256 token, uint128 amount)
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
        _creditWithFee(recipient, operator, from, token, uint256(amount));
    }

    error Exists();

    event RailCreated(
        address indexed payer,
        address indexed payee,
        address indexed operator,
        uint256 token,
        RailId railId,
        uint64 nonce
    );

    /// @param nonce high bit is FLAG_CALLBACK, settling through IRailV2 callbacks rather than to
    /// recipient; the low 31 bits distinguish rails sharing the other arguments
    function createRail(address from, address recipient, uint64 nonce, uint256 token)
        external
        validToken(token)
        returns (RailId railId)
    {
        return _createRail(msg.sender, from, recipient, nonce, token, ALL);
    }

    /// @param scope narrows the authorization a script runs under
    function _createRail(
        address operator,
        address from,
        address recipient,
        uint64 nonce,
        uint256 token,
        Permissions scope
    ) internal returns (RailId railId) {
        Stream storage stream = operator.deriveRail(from, recipient, token, nonce);
        require(!stream.exists(), Exists());
        require(
            scope & users[from].authorizations[operator].permissions & CREATE_RAIL != NONE, Unauthorized(from, operator)
        );

        stream.init();
        railId = stream.getRailId();
        emit RailCreated(from, recipient, operator, token, railId, nonce);
    }

    struct Auth {
        address authenticated;
        Permissions permissions;
        address from;
        address recipient;
        uint64 nonce;
        uint256 token;
    }
    error Unauthorized(address user, address operator);

    function _existingRail(Auth memory auth) internal view returns (Stream storage stream) {
        return _existingRail(auth.authenticated, auth.from, auth.recipient, auth.token, auth.nonce);
    }

    function _existingRail(address operator, address from, address recipient, uint256 token, uint64 nonce)
        internal
        view
        returns (Stream storage stream)
    {
        stream = operator.deriveRail(from, recipient, token, nonce);
        // TODO(perf): this duplicates the read of stream.state
        require(stream.exists(), RailNotCreated());
    }

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
    function _credit(address recipient, address operator, address owner, uint256 token, uint256 amount) internal {
        unchecked {
            // amount and the sum stay inside uint128 by the bound on Checkpoint
            users[recipient].accounts[token].latest.balance += uint128(amount);
        }
        emit Transfer(operator, owner, recipient, token, amount);
    }

    function _credit(address recipient, address owner, uint256 token, uint256 amount) internal {
        _credit(recipient, msg.sender, owner, token, amount);
    }

    address private immutable AUCTION;
    uint256 private immutable WFIL;
    uint256 private immutable USDFC;

    constructor(IWFIL wfil, address usdfc) {
        AUCTION = address(new Auction(wfil));
        WFIL = uint256(uint160(address(wfil)));
        USDFC = uint256(uint160(usdfc));
    }

    function _creditWithFee(address recipient, address operator, address owner, uint256 token, uint256 amount)
        internal
    {
        // TODO(perf): consider bitwise & (probabilistic but cheaper)
        uint256 wfil = WFIL;
        uint256 usdfc = USDFC;
        uint256 fee;
        assembly ("memory-safe") {
            fee := div(mul(sub(2, iszero(mul(mul(token, xor(token, wfil)), xor(token, usdfc)))), amount), 50)
        }
        _credit(AUCTION, operator, owner, token, fee);
        _credit(recipient, operator, owner, token, amount - fee);
    }

    /// @dev the checkpoint keeps its epoch, so the rails it owes still drain from where they left off
    function _debit(Account storage account, uint256 amount) internal {
        Checkpoint memory balance = account.latest;
        require(current(balance) >= amount, InsufficientBalance());
        unchecked {
            balance.balance -= uint128(amount);
        }
        account.latest = balance;
    }

    function _move(Account storage debit, address recipient, address owner, uint256 token, uint256 amount)
        internal
        returns (bool)
    {
        _debit(debit, amount);
        _credit(recipient, owner, token, amount);
        return true;
    }

    function _depositTo(uint256 token, address from, address recipient, uint256 amount) internal {
        _credit(recipient, address(0), token, amount);
        address(uint160(token)).safeTransferFrom(from, address(this), amount);
    }

    error PaymentFailed();

    function _withdrawTo(uint256 token, address owner, address recipient, uint256 amount) internal {
        Account storage account = users[owner].accounts[token];
        _debit(account, amount);
        emit Transfer(msg.sender, owner, address(0), token, amount);
        if (token == 0) {
            require(recipient.pay(amount), PaymentFailed());
        } else {
            address(uint160(token)).safeTransfer(recipient, amount);
        }
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

            // switch(method), numbered so that adjacent ops share the reads and checks they have in common

            // an op with no entry in the table takes no permission, so its mask passes
            Permissions scope = Permissions.wrap((PERMISSION_BY_OP >> (method << 3)) & 0xff);
            require(auth.permissions & scope == scope, Unauthorized(auth.authenticated, msg.sender));

            if (method < Ops.WITHDRAW) {
                if (method < Ops.SUDO) {
                    if (method == Ops.POP) {
                        return curr;
                    } else if (method == Ops.PUSH) {
                        curr = _dispatch(auth, curr, end);
                    } else {
                        // Ops.RESET
                        _copy(auth, startingAuth);
                    }
                } else {
                    // every op from here to Ops.SETTLERAIL leads with an address
                    address who;
                    (who, curr) = curr.nextAddress();
                    if (method < Ops.SETRAIL) {
                        if (method == Ops.SETTOKEN) {
                            auth.token = uint256(uint160(who));
                        } else if (method == Ops.AUTHORIZE) {
                            uint256 granted;
                            (granted, curr) = curr.nextByte();
                            // a script grants only what it was itself trusted with
                            _authorize(auth.authenticated, who, Permissions.wrap(granted) & auth.permissions);
                        } else {
                            // Ops.SUDO
                            Permissions permissions =
                                users[who].authorizations[auth.authenticated].permissions & auth.permissions;
                            require(permissions != NONE, Unauthorized(who, auth.authenticated));
                            auth.authenticated = who;
                            auth.permissions = permissions;
                        }
                    } else {
                        // Ops.SETRAIL, Ops.CREATERAIL, Ops.SETTLERAIL: `who` is the payer of each
                        address recipient;
                        uint64 nonce;
                        (recipient, nonce, curr) = curr.nextAddressU64();
                        if (method == Ops.SETTLERAIL) {
                            address operator;
                            (operator, curr) = curr.nextAddress();
                            _settleRail(operator, who, recipient, nonce, auth.token);
                        } else {
                            // the rail ops that follow address this one
                            auth.from = who;
                            auth.recipient = recipient;
                            auth.nonce = nonce;
                            if (method == Ops.CREATERAIL) {
                                _createRail(auth.authenticated, who, recipient, nonce, auth.token, auth.permissions);
                            }
                        }
                    }
                }
            } else if (method < Ops.INCREASERATE) {
                if (method < Ops.TRANSFER) {
                    // Ops.WITHDRAW, Ops.DEPOSIT, Ops.WITHDRAWTO, Ops.DEPOSITTO
                    uint128 amount;
                    (amount, curr) = curr.nextU128();
                    address recipient = auth.authenticated;
                    if (method > Ops.DEPOSIT) {
                        (recipient, curr) = curr.nextAddress();
                    }
                    // Script.sol numbers the two directions by parity
                    if (method & 1 == 0) {
                        _depositTo(auth.token, auth.authenticated, recipient, amount);
                    } else {
                        _withdrawTo(auth.token, auth.authenticated, recipient, amount);
                    }
                } else {
                    // Ops.TRANSFER, Ops.TRANSFERFROM, Ops.TRANSFERALL
                    address recipient;
                    if (method == Ops.TRANSFERFROM) {
                        uint128 operand;
                        address owner;
                        (recipient, operand, curr) = curr.nextAddressU128();
                        (owner, curr) = curr.nextAddress();
                        _transferFrom(auth.authenticated, owner, recipient, auth.token, operand);
                    } else {
                        Account storage debit = users[auth.authenticated].accounts[auth.token];
                        uint256 amount;
                        if (method == Ops.TRANSFER) {
                            uint128 operand;
                            (recipient, operand, curr) = curr.nextAddressU128();
                            amount = operand;
                        } else {
                            // Ops.TRANSFERALL: what the rails have accrued stays behind
                            (recipient, curr) = curr.nextAddress();
                            amount = current(debit.latest);
                        }
                        _move(debit, recipient, auth.authenticated, auth.token, amount);
                    }
                }
            } else {
                if (method < Ops.DISBURSEALL) {
                    // Ops.INCREASERATE, Ops.DECREASERATE, Ops.SETRATE
                    uint88 rate;
                    (rate, curr) = curr.nextU88();
                    Stream storage stream =
                        _settleForRate(auth.authenticated, auth.from, auth.recipient, auth.nonce, auth.token);
                    uint88 previousRate = stream.state.incomingRate;
                    if (method == Ops.INCREASERATE) {
                        rate = previousRate + rate;
                    } else if (method == Ops.DECREASERATE) {
                        rate = previousRate - rate;
                    }
                    _setRate(stream, users[auth.from].accounts[auth.token], previousRate, rate);
                } else if (method >= Ops.TERMINATERAIL) {
                    // Ops.TERMINATERAIL, Ops.TERMINATERAILBY
                    address operator = auth.authenticated;
                    address from = auth.from;
                    if (method == Ops.TERMINATERAILBY) {
                        // the payer is who the script authenticated as, and names the operator
                        from = operator;
                        (operator, curr) = curr.nextAddress();
                    }
                    _terminateRail(operator, from, auth.recipient, auth.nonce, auth.token, auth.authenticated);
                } else {
                    // Ops.DISBURSEALL, Ops.DISBURSE, Ops.LOCK, Ops.UNLOCK, Ops.SETAVAILABLE
                    Stream storage stream = _existingRail(auth);
                    uint128 amount;
                    if (method == Ops.DISBURSEALL) {
                        amount = stream.state.available;
                    } else {
                        (amount, curr) = curr.nextU128();
                    }
                    if (method < Ops.LOCK) {
                        _disburse(stream, auth.authenticated, auth.from, auth.recipient, auth.token, amount);
                    } else {
                        bool increase = method != Ops.UNLOCK;
                        if (method == Ops.SETAVAILABLE) {
                            uint128 available = stream.state.available;
                            assembly ("memory-safe") {
                                increase := gt(amount, available)
                                // amount = increase ? amount - available : available - amount
                                amount := mul(sub(shl(1, increase), 1), sub(amount, available))
                            }
                        }
                        _lockup(stream, users[auth.from].accounts[auth.token], amount, increase);
                    }
                }
            }
        }
        return curr;
    }
}
