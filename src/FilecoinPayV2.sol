pragma solidity ^0.8.37;

import {IERC165} from "forge-std/interfaces/IERC165.sol";
import {IERC6909} from "forge-std/interfaces/IERC6909.sol";
import {LibClone} from "solady/utils/LibClone.sol";

import {IRailV2} from "./interfaces/IRail.sol";
import "./lib/FilecoinPayOps.sol" as Ops;
import {ALL, NONE, Permissions} from "./lib/Permissions.sol";
import {ScriptIterator, ScriptReading} from "./lib/Script.sol";

contract FilecoinPayV2 is IERC6909 {
    using ScriptReading for bytes;
    using ScriptReading for ScriptIterator;
    using LibClone for bytes32;

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
        IncomingStream stream;
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

    struct IncomingStream {
        uint88 incomingRate;
        uint40 settledUpTo;
        // NOTE: it may be more effiicent to accumulate pending balance here and sweep it later
        // uint128 available;
    }

    function settleRail(
        bytes32 initcodeHash,
        bytes32[2] calldata /*packedRailInfo*/
    )
        external
        returns (uint256 amount)
    {
        address from;
        uint256 token;
        address operator;
        address railAddress;
        {
            bytes32 salt;
            assembly ("memory-safe") {
                calldatacopy(0, 36, 64)
                from := shr(96, mload(0))
                token := shr(96, mload(20))
                operator := shr(96, mload(40))
                salt := keccak256(0, 64)
            }
            railAddress = initcodeHash.predictDeterministicAddress(salt, address(this));
        }
        User storage rail = users[railAddress];
        IncomingStream memory stream = rail.stream;

        unchecked {
            uint256 settleUpTo = canSettleTo(users[from].accounts[token].latest);
            uint256 prevSettledEpoch = uint256(stream.settledUpTo);
            uint256 blocks = settleUpTo - prevSettledEpoch;
            if (blocks == 0) {
                return 0;
            }

            stream.settledUpTo = uint40(settleUpTo);
            rail.stream = stream;

            amount = blocks * stream.incomingRate;
            Account storage railAccount = rail.accounts[token];
            uint256 prevBalance = current(railAccount.latest);
            railAccount.latest.balance += uint128(amount);
            // judgement: the initiator of the payment is the operator, not the caller
            emit Transfer(operator, from, railAddress, token, amount);

            bytes memory script = IRailV2(railAddress).settleRail(prevSettledEpoch, settleUpTo, prevBalance, amount);

            _dispatch(Auth({authenticated: railAddress, permissions: ALL}), script.memoryIter());
        }
    }

    function createRail(
        address template,
        address, // from
        address, // token
        uint32, // nonce
        bytes calldata /*params*/
    )
        external
        payable
        returns (bytes32 initcodeHash, address railAddress)
    {
        assembly ("memory-safe") {
            mstore(28, caller())
            calldatacopy(0, 48, 20)
            calldatacopy(20, 80, 20)
            calldatacopy(60, 128, 4)
            let salt := keccak256(0, 64)
            let start := mload(0x40)
            let size := extcodesize(template)
            extcodecopy(template, start, 0, size)
            // TODO params
            initcodeHash := keccak256(start, size)
            railAddress := create2(callvalue(), start, size, salt)
        }
    }

    struct Auth {
        address authenticated;
        Permissions permissions;
    }
    error Unauthorized(address user, address operator);
    error BadSalt(address calculated, address expected);

    /**
     * Batch functions
     */

    function executeScript(bytes calldata script) external {
        _dispatch(Auth({authenticated: msg.sender, permissions: ALL}), script.calldataIter());
    }

    function executeScript(Permissions scope, bytes calldata script) external {
        _dispatch(Auth({authenticated: msg.sender, permissions: scope}), script.calldataIter());
    }

    function _dispatch(Auth memory auth, ScriptIterator memory remaining) internal {
        while (remaining.curr < remaining.end) {
            uint256 method = remaining.nextByte();
            if (method < 8) {
                if (method < 4) {
                    if (method < 2) {
                        if (method == Ops.POP) {
                            // Ops.POP
                            return;
                        } else {
                            // Ops.PUSH
                            Auth memory next = Auth({authenticated: auth.authenticated, permissions: auth.permissions});
                            _dispatch(next, remaining);
                        }
                    } else {
                        if (method == Ops.RESET) {
                            // Ops.RESET
                            auth.authenticated = msg.sender;
                            auth.permissions = ALL;
                        } else {
                            // Ops.SUDO
                            address who = remaining.nextAddress();
                            Permissions permissions =
                                users[who].authorizations[auth.authenticated].permissions & auth.permissions;
                            require(permissions != NONE, Unauthorized(who, auth.authenticated));
                            auth.authenticated = who;
                            auth.permissions = permissions;
                        }
                    }
                } else {
                    if (method < 6) {
                        if (method == Ops.AUTHRAIL) {
                            // Ops.AUTHRAIL
                            (
                                address rail,
                                address from,
                                /*address token*/, /*address operator*/
                            ) = remaining.nextRailInfo();
                            require(rail == auth.authenticated, BadSalt(rail, auth.authenticated));
                            // TODO: determine whether to allow operator revocation
                            // users[from].authorizations[operator].permissions
                            // users[from].authorizations[rail].permissions
                            auth.authenticated = from;
                        } else {
                            // 5
                        }
                    } else {
                        // 6 7
                    }
                }
            } else {
                // 8 9 10 11 12 13 14 15
            }
        }
    }
}
