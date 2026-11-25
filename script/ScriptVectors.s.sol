// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {ALL, CREATE_RAIL, NONE} from "../src/lib/Permissions.sol";
import {FLAG_CALLBACK} from "../src/lib/RailId.sol";
import "../src/lib/Script.sol" as Ops;
import {newScript} from "../src/lib/Script.sol";
import {ScriptReading} from "../src/lib/ScriptReading.sol";

/// @dev writes vectors/script.json, which every client library must reproduce byte for byte
contract ScriptVectors is Script {
    using ScriptReading for uint256;
    using ScriptReading for bytes;

    error NotDryRun();
    error TruncatedOp();
    error UnnamedOp(uint256 op);

    string private constant PATH = "vectors/script.json";

    address private constant ALICE = 0xA11cea11CEA11CEA11cEa11CeA11ceA11CEA11Ce;
    address private constant BOB = 0xb0bB0bB0Bb0Bb0bB0Bb0bb0bb0bB0BB0Bb0BB0Bb;
    address private constant TOKEN = 0x1111111111111111111111111111111111111111;
    address private constant OPERATOR = 0x2222222222222222222222222222222222222222;
    address private constant CAROL = 0xCA401ca401Ca401CA401CA401cA401CA401ca401;
    // a saturated operand would collide with its neighbour if a shift were off by a byte,
    // and a counting one would not survive a swap or a reversal
    address private constant MAX_ADDRESS = address(type(uint160).max);
    uint128 private constant MAX_AMOUNT = type(uint128).max;
    uint128 private constant AMOUNT = 0x0102030405060708090a0b0c0d0e0f10;
    uint64 private constant MAX_NONCE = type(uint64).max;
    uint64 private constant NONCE = 0x0102030405060708;
    uint88 private constant MAX_RATE = type(uint88).max;
    uint88 private constant RATE = 0x0102030405060708090a0b;

    mapping(uint256 op => string) private names;
    string[] private cases;
    string[] private ops;

    function setUp() public {
        names[Ops.POP] = "pop";
        names[Ops.PUSH] = "push";
        names[Ops.RESET] = "reset";
        names[Ops.SUDO] = "sudo";
        names[Ops.SETTOKEN] = "setToken";
        names[Ops.AUTHORIZE] = "authorize";
        names[Ops.SETRAIL] = "setRail";
        names[Ops.CREATERAIL] = "createRail";
        names[Ops.SETTLERAIL] = "settleRail";
        names[Ops.WITHDRAW] = "withdraw";
        names[Ops.DEPOSIT] = "deposit";
        names[Ops.WITHDRAWTO] = "withdrawTo";
        names[Ops.DEPOSITTO] = "depositTo";
        names[Ops.TRANSFER] = "transfer";
        names[Ops.TRANSFERFROM] = "transferFrom";
        names[Ops.TRANSFERALL] = "transferAll";
        names[Ops.INCREASERATE] = "increaseRate";
        names[Ops.DECREASERATE] = "decreaseRate";
        names[Ops.SETRATE] = "setRate";
        names[Ops.DISBURSEALL] = "disburseAll";
        names[Ops.DISBURSE] = "disburse";
        names[Ops.LOCK] = "lock";
        names[Ops.UNLOCK] = "unlock";
        names[Ops.SETAVAILABLE] = "setAvailable";
        names[Ops.TERMINATERAIL] = "terminateRail";
        names[Ops.TERMINATERAILBY] = "terminateRailBy";
    }

    // the builder writes at the free memory pointer, so nothing may allocate between newScript()
    // and build(): each script is finished in one expression before _case sees it
    function run() public {
        require(vm.isContext(VmSafe.ForgeContext.ScriptDryRun), NotDryRun());

        bytes memory script = newScript().build();
        _case("empty", script);

        script = newScript().pop().build();
        _case("pop", script);
        script = newScript().push().build();
        _case("push", script);
        script = newScript().reset().build();
        _case("reset", script);
        script = newScript().sudo(ALICE).build();
        _case("sudo", script);
        script = newScript().setToken(MAX_ADDRESS).build();
        _case("setToken", script);
        script = newScript().authorize(ALICE, ALL).build();
        _case("authorize", script);
        script = newScript().setRail(MAX_ADDRESS, BOB, NONCE).build();
        _case("setRail", script);
        script = newScript().createRail(ALICE, MAX_ADDRESS, MAX_NONCE).build();
        _case("createRail", script);
        script = newScript().settleRail(ALICE, BOB, MAX_NONCE, OPERATOR).build();
        _case("settleRail", script);
        script = newScript().withdraw(MAX_AMOUNT).build();
        _case("withdraw", script);
        script = newScript().deposit(AMOUNT).build();
        _case("deposit", script);
        script = newScript().withdrawTo(MAX_AMOUNT, BOB).build();
        _case("withdrawTo", script);
        script = newScript().depositTo(AMOUNT, MAX_ADDRESS).build();
        _case("depositTo", script);
        script = newScript().transfer(BOB, MAX_AMOUNT).build();
        _case("transfer", script);
        script = newScript().transferFrom(MAX_ADDRESS, AMOUNT, ALICE).build();
        _case("transferFrom", script);
        script = newScript().transferAll(BOB).build();
        _case("transferAll", script);
        script = newScript().increaseRate(MAX_RATE).build();
        _case("increaseRate", script);
        script = newScript().decreaseRate(RATE).build();
        _case("decreaseRate", script);
        script = newScript().setRate(MAX_RATE).build();
        _case("setRate", script);
        script = newScript().disburseAll().build();
        _case("disburseAll", script);
        script = newScript().disburse(MAX_AMOUNT).build();
        _case("disburse", script);
        script = newScript().lock(AMOUNT).build();
        _case("lock", script);
        script = newScript().unlock(MAX_AMOUNT).build();
        _case("unlock", script);
        script = newScript().setAvailable(AMOUNT).build();
        _case("setAvailable", script);
        script = newScript().terminateRail().build();
        _case("terminateRail", script);
        script = newScript().terminateRailBy(BOB).build();
        _case("terminateRailBy", script);

        script = newScript()
            .sudo(address(0))
            .setToken(address(0))
            .authorize(address(0), NONE)
            .setRail(address(0), address(0), 0)
            .createRail(address(0), address(0), 0)
            .settleRail(address(0), address(0), 0, address(0))
            .withdraw(0)
            .deposit(0)
            .withdrawTo(0, address(0))
            .depositTo(0, address(0))
            .transfer(address(0), 0)
            .transferFrom(address(0), 0, address(0))
            .transferAll(address(0))
            .increaseRate(0)
            .decreaseRate(0)
            .setRate(0)
            .disburse(0)
            .lock(0)
            .unlock(0)
            .setAvailable(0)
            .terminateRailBy(address(0))
            .build();
        _case("zeroOperands", script);

        script = newScript().setToken(TOKEN).deposit(100e18).authorize(OPERATOR, CREATE_RAIL).build();
        _case("depositAndAuthorize", script);

        script =
            newScript().setToken(TOKEN).createRail(ALICE, BOB, FLAG_CALLBACK | 1).setRate(1000).lock(500_000).build();
        _case("createAndFundRail", script);

        // FLAG_CALLBACK is the only nonce bit Pay reads: bit 62 is the operator's own data
        script = newScript()
            .setToken(TOKEN)
            .createRail(ALICE, BOB, FLAG_CALLBACK | 7)
            .lock(0.5e18)
            .createRail(ALICE, BOB, 7)
            .lock(1e18)
            .createRail(ALICE, CAROL, 1 << 62 | 7)
            .lock(0.3e18)
            .build();
        _case("createThreeRails", script);

        script = newScript()
            .setToken(TOKEN)
            .settleRail(ALICE, BOB, 1, OPERATOR)
            .settleRail(ALICE, BOB, 2, OPERATOR)
            .settleRail(MAX_ADDRESS, BOB, FLAG_CALLBACK | 3, OPERATOR)
            .withdrawTo(42e18, ALICE)
            .build();
        _case("settleAndWithdraw", script);

        script = newScript().setToken(TOKEN).setRail(ALICE, BOB, FLAG_CALLBACK | 1).terminateRailBy(OPERATOR).build();
        _case("payerTerminate", script);

        script = newScript().setToken(TOKEN).push().sudo(ALICE).transfer(BOB, 5).pop().reset().transferAll(BOB).build();
        _case("sudoTransfer", script);

        vm.writeJson(vm.serializeString("root", "cases", cases), PATH);
    }

    function _case(string memory name, bytes memory script) internal {
        (uint256 curr, uint256 end) = script.memoryIter();
        while (curr < end) {
            string memory op;
            (op, curr) = _op(curr, string.concat(name, ".", vm.toString(ops.length)));
            ops.push(op);
        }
        require(curr == end, TruncatedOp());
        vm.serializeString(name, "name", name);
        vm.serializeBytes(name, "script", script);
        cases.push(vm.serializeString(name, "ops", ops));
        delete ops;
    }

    /// @dev integers are decimal strings, since they outgrow a JSON number
    function _op(uint256 curr, string memory key) internal returns (string memory, uint256) {
        uint256 op;
        (op, curr) = curr.nextByte();
        string memory argsKey = string.concat(key, ".args");
        string memory args = "{}";
        address who;
        uint128 amount;
        if (op < Ops.SUDO || op == Ops.DISBURSEALL || op == Ops.TERMINATERAIL) {
            // no operands
        } else if (op < Ops.WITHDRAW) {
            (who, curr) = curr.nextAddress();
            if (op == Ops.SUDO) {
                args = vm.serializeAddress(argsKey, "who", who);
            } else if (op == Ops.SETTOKEN) {
                args = vm.serializeAddress(argsKey, "token", who);
            } else if (op == Ops.AUTHORIZE) {
                uint256 permissions;
                (permissions, curr) = curr.nextByte();
                vm.serializeAddress(argsKey, "operator", who);
                args = _uint(argsKey, "permissions", permissions);
            } else {
                address recipient;
                uint64 nonce;
                (recipient, nonce, curr) = curr.nextAddressU64();
                vm.serializeAddress(argsKey, "from", who);
                vm.serializeAddress(argsKey, "recipient", recipient);
                args = _uint(argsKey, "nonce", nonce);
                if (op == Ops.SETTLERAIL) {
                    (who, curr) = curr.nextAddress();
                    args = vm.serializeAddress(argsKey, "operator", who);
                }
            }
        } else if (op < Ops.TRANSFER) {
            (amount, curr) = curr.nextU128();
            args = _uint(argsKey, "amount", amount);
            if (op > Ops.DEPOSIT) {
                (who, curr) = curr.nextAddress();
                args = vm.serializeAddress(argsKey, "recipient", who);
            }
        } else if (op == Ops.TRANSFERALL) {
            (who, curr) = curr.nextAddress();
            args = vm.serializeAddress(argsKey, "recipient", who);
        } else if (op < Ops.INCREASERATE) {
            (who, amount, curr) = curr.nextAddressU128();
            vm.serializeAddress(argsKey, "recipient", who);
            args = _uint(argsKey, "amount", amount);
            if (op == Ops.TRANSFERFROM) {
                (who, curr) = curr.nextAddress();
                args = vm.serializeAddress(argsKey, "owner", who);
            }
        } else if (op < Ops.DISBURSEALL) {
            uint88 rate;
            (rate, curr) = curr.nextU88();
            args = _uint(argsKey, "rate", rate);
        } else if (op == Ops.TERMINATERAILBY) {
            (who, curr) = curr.nextAddress();
            args = vm.serializeAddress(argsKey, "operator", who);
        } else {
            (amount, curr) = curr.nextU128();
            args = _uint(argsKey, "amount", amount);
        }
        require(bytes(names[op]).length != 0, UnnamedOp(op));
        vm.serializeString(key, "op", names[op]);
        return (vm.serializeString(key, "args", args), curr);
    }

    function _uint(string memory key, string memory name, uint256 value) internal returns (string memory) {
        return vm.serializeString(key, name, vm.toString(value));
    }
}
