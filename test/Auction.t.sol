// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {WFIL} from "fevmate/token/WFIL.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdError} from "forge-std/StdError.sol";
import {BURN_ADDRESS} from "fvm-solidity/FVMActors.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC6909} from "forge-std/interfaces/IERC6909.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

import {Auction, HALVING_INTERVAL, LOG_BIAS, LOG_MAX, LOG_ONE, SCALE_HALF_LIFE} from "../src/Auction.sol";
import {FilecoinPayV2} from "../src/FilecoinPayV2.sol";
import {TRANSFER} from "../src/lib/Permissions.sol";
import {FilecoinPayTest} from "./FilecoinPayTest.sol";

contract AuctionTest is FilecoinPayTest {
    function depositNative(address from, address to, uint256 amount) internal {
        vm.deal(from, amount);
        vm.prank(from);
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(from, address(0), to, NATIVE_TOKEN, amount);
        payments.depositTo{value: amount}(to);
    }

    function testBurn() public {
        depositNative(alice, address(auction), 5 ether);

        vm.deal(address(auction), 2 ether);

        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(auction), address(0), address(auction), NATIVE_TOKEN, 2 ether);
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(auction), address(auction), address(0), NATIVE_TOKEN, 7 ether);
        auction.burn();

        assertEq(BURN_ADDRESS.balance, 7 ether);
    }

    function mockAndDepositTo(MockERC20 token, address from, address to, uint256 amount) internal {
        token.mint(from, amount);
        erc20DepositTo(IERC20(address(token)), from, to, amount);
    }

    function erc20DepositTo(IERC20 token, address from, address to, uint256 amount) internal {
        vm.expectEmit(address(token));
        emit IERC20.Approval(from, address(payments), amount);
        vm.prank(from);
        token.approve(address(payments), amount);

        uint256 tokenId = uint256(uint160(address(token)));

        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(from, address(0), to, tokenId, amount);
        vm.expectEmit(address(token));
        emit IERC20.Transfer(from, address(payments), amount);
        vm.prank(from);
        payments.depositTo(address(token), to, amount);
    }

    function depositWrapped(address from, address to, uint256 amount) internal {
        vm.deal(from, amount);

        vm.expectEmit(address(wfil));
        emit WFIL.Deposit(from, amount);
        vm.prank(from);
        wfil.deposit{value: amount}();

        erc20DepositTo(IERC20(address(wfil)), from, to, amount);
    }

    function testUnwrap() public {
        depositWrapped(alice, address(auction), 5 ether);

        uint256 wfil_token = uint256(uint160(address(wfil)));

        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(auction), address(auction), address(0), wfil_token, 5 ether);
        vm.expectEmit(address(wfil));
        emit WFIL.Withdrawal(address(auction), 5 ether);
        auction.unwrap();

        assertEq(address(auction).balance, 5 ether);
        assertEq(BURN_ADDRESS.balance, 0);

        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(auction), address(0), address(auction), NATIVE_TOKEN, 5 ether);
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(auction), address(auction), address(0), NATIVE_TOKEN, 5 ether);
        auction.burn();

        assertEq(address(auction).balance, 0);
        assertEq(BURN_ADDRESS.balance, 5 ether);
    }

    function testAcceptNativeOrWrappedReverts() public {
        depositNative(alice, alice, 1 ether);
        depositWrapped(alice, address(auction), 1 ether);
        depositNative(alice, address(auction), 1 ether);

        // the constructor dates both auctions NEVER, so measuring elapsed underflows
        vm.expectRevert(stdError.arithmeticError);
        auction.accept(address(0), 1 ether, 1 ether);
        vm.expectRevert(stdError.arithmeticError);
        auction.accept(address(wfil), 1 ether, 1 ether);
    }

    uint256 constant WHOLE_OF_16 = 23083120654223414531; // 16 ether / ln2

    function usdfcId() internal view returns (uint256) {
        return uint256(uint160(address(usdfc)));
    }

    function logPriceOf(address t) internal view returns (int64 l) {
        (l,,) = auction.auctionOf(t);
    }

    function scaleOf(address t) internal view returns (uint128 s) {
        (, s,) = auction.auctionOf(t);
    }

    function fund(uint256 nativeAmount, uint256 tokenAmount) internal {
        if (tokenAmount > 0) {
            usdfc.mint(alice, tokenAmount);
            vm.prank(alice);
            usdfc.approve(address(payments), tokenAmount);
            vm.prank(alice);
            payments.depositTo(address(usdfc), address(auction), tokenAmount);
        }
        if (nativeAmount > 0) {
            vm.deal(alice, nativeAmount);
            vm.prank(alice);
            payments.depositTo{value: nativeAmount}(alice);
        }
        vm.prank(alice);
        payments.setOperator(address(auction), true);
    }

    function testFirstAuctionPricesWholeBalanceAtOneDoubling() public {
        fund(WHOLE_OF_16 + 1, 16 ether);

        vm.expectRevert(abi.encodeWithSelector(Auction.Insufficient.selector, WHOLE_OF_16));
        vm.prank(alice);
        auction.accept(address(usdfc), 16 ether, uint128(WHOLE_OF_16));

        vm.expectEmit(address(auction));
        emit Auction.Auctioned(address(usdfc), 16 ether, uint128(WHOLE_OF_16), uint128(WHOLE_OF_16 + 1));
        vm.prank(alice);
        auction.accept(address(usdfc), 16 ether, uint128(WHOLE_OF_16 + 1));

        assertEq(logPriceOf(address(usdfc)), int64(LOG_ONE));
        assertEq(uint256(scaleOf(address(usdfc))), 16 ether);
        assertEq(payments.balanceOf(alice, usdfcId()), 16 ether);
    }

    function testPriceHalvesOverHalvingInterval() public {
        fund(WHOLE_OF_16 + 1, 16 ether);
        vm.prank(alice);
        auction.accept(address(usdfc), 16 ether, uint128(WHOLE_OF_16 + 1));

        vm.roll(vm.getBlockNumber() + HALVING_INTERVAL);
        fund(WHOLE_OF_16 + 1, 16 ether);

        // one halving exactly undoes the doubling the first sale produced
        vm.expectEmit(address(auction));
        emit Auction.Auctioned(address(usdfc), 16 ether, uint128(WHOLE_OF_16), uint128(WHOLE_OF_16 + 1));
        vm.prank(alice);
        auction.accept(address(usdfc), 16 ether, uint128(WHOLE_OF_16 + 1));
        assertEq(logPriceOf(address(usdfc)), int64(LOG_ONE));
    }

    function testSplittingAPurchaseCostsTheSame() public {
        fund(WHOLE_OF_16 * 2, 16 ether);

        vm.recordLogs();
        vm.prank(alice);
        auction.accept(address(usdfc), 8 ether, uint128(WHOLE_OF_16));
        vm.prank(alice);
        auction.accept(address(usdfc), 8 ether, uint128(WHOLE_OF_16));

        uint256 split;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == Auction.Auctioned.selector) {
                (, uint128 valuation,) = abi.decode(logs[i].data, (uint128, uint128, uint128));
                split += valuation;
            }
        }
        assertApproxEqAbs(split, WHOLE_OF_16, 2);
        assertEq(logPriceOf(address(usdfc)), int64(LOG_ONE));
    }

    function testOneWeiAcceptsCannotRatchet() public {
        fund(WHOLE_OF_16 + 1, 16 ether);
        vm.prank(alice);
        auction.accept(address(usdfc), 16 ether, uint128(WHOLE_OF_16 + 1));
        int64 before = logPriceOf(address(usdfc));

        for (uint256 i = 0; i < 64; i++) {
            fund(1 ether, 1);
            vm.prank(alice);
            auction.accept(address(usdfc), 1, 1 ether);
        }

        // the old rule multiplied the price by 4 per accept; impact is now proportional to quantity
        assertLt(logPriceOf(address(usdfc)) - before, int64(LOG_ONE / 1000));
    }

    function testPriceCannotBeZeroed() public {
        fund(WHOLE_OF_16 + 1, 16 ether);
        vm.prank(alice);
        auction.accept(address(usdfc), 16 ether, uint128(WHOLE_OF_16 + 1));

        fund(1 ether, 1);
        vm.prank(alice);
        auction.accept(address(usdfc), 1, 1 ether);

        fund(0, 100 ether);
        assertGt(valuationOf(100 ether), WHOLE_OF_16);
    }

    function testBitePastTheBalanceAlwaysReverts() public {
        fund(type(uint128).max, 16 ether);

        // one wei over is still one doubling, so it prices normally and only the transfer objects
        vm.expectRevert(FilecoinPayV2.InsufficientBalance.selector);
        vm.prank(alice);
        auction.accept(address(usdfc), 16 ether + 1, uint128(WHOLE_OF_16 + 1));

        // 64 doublings stays in exp2's domain but quotes past what uint128 can ever pay
        vm.expectRevert(abi.encodeWithSelector(Auction.Insufficient.selector, 425808419131018319969043854928866432403));
        vm.prank(alice);
        auction.accept(address(usdfc), 64 * 16 ether, type(uint128).max);

        // past 127 doublings the quote leaves exp2's domain and underflows before the transfer
        vm.expectRevert(stdError.arithmeticError);
        vm.prank(alice);
        auction.accept(address(usdfc), 128 * 16 ether, type(uint128).max);
    }

    function testEmptyBiteIsHarmless() public {
        // no balance and no memory leaves no scale to price against
        vm.expectRevert(stdError.divisionError);
        auction.accept(address(token), 0, 1 ether);

        // otherwise it quotes nothing, and the strict check still charges the caller
        fund(1, 16 ether);
        vm.prank(alice);
        auction.accept(address(usdfc), 0, 1);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 0);
        assertEq(logPriceOf(address(usdfc)), 0);
    }

    /// @dev the auction's valuation of `bite`, read by offering nothing; reverts before touching state
    function valuationOf(uint128 bite) internal returns (uint256) {
        vm.prank(alice);
        try auction.accept(address(usdfc), bite, 0) {
            revert("expected Insufficient");
        } catch (bytes memory err) {
            assertEq(bytes4(err), Auction.Insufficient.selector);
            uint256 valuation;
            assembly {
                valuation := mload(add(err, 0x24))
            }
            return valuation;
        }
    }

    function poke(int64 logPrice, uint128 scale) internal {
        vm.store(
            address(auction),
            keccak256(abi.encode(address(usdfc), uint256(0))),
            bytes32(uint256(uint64(logPrice)) | (uint256(scale) << 64) | (uint256(block.number) << 192))
        );
    }

    /// decay floors `logPrice` at -LOG_BIAS, below which exp2 would read a wrapped operand
    function decayToFloor() internal {
        fund(WHOLE_OF_16 + 1, 16 ether);
        vm.prank(alice);
        auction.accept(address(usdfc), 16 ether, uint128(WHOLE_OF_16 + 1));
        vm.roll(vm.getBlockNumber() + 70 * HALVING_INTERVAL);
    }

    function testFlooredPriceIsNeverFree() public {
        decayToFloor();
        fund(1, 16 ether);

        // 1e18 * 2^logPrice truncates to zero here, so the quote is zero but the sale is not free
        assertEq(valuationOf(16 ether), 0);
        vm.expectRevert(abi.encodeWithSelector(Auction.Insufficient.selector, 0));
        vm.prank(alice);
        auction.accept(address(usdfc), 16 ether, 0);

        vm.prank(alice);
        auction.accept(address(usdfc), 16 ether, 1);
        assertEq(logPriceOf(address(usdfc)), int64(-LOG_BIAS + LOG_ONE));
    }

    function testFlooredPriceRecoversOnPurchases() public {
        decayToFloor();

        // each clear is one doubling off the floor, so a quote reappears without any demand signal lost
        for (uint256 i = 0; i < 4; i++) {
            fund(1, 16 ether);
            vm.prank(alice);
            auction.accept(address(usdfc), 16 ether, 1);
        }
        assertEq(logPriceOf(address(usdfc)), int64(-LOG_BIAS + 4 * LOG_ONE));

        fund(0, 16 ether);
        assertEq(valuationOf(16 ether), 23);
    }

    /// LOG_MAX is the lowest of the three ceilings: exp2's domain binds before uint128 payment or int64 storage
    function testCappedPriceStaysInsideExp2Domain() public {
        fund(0, 1);
        poke(int64(LOG_MAX), 1);

        // one unit is the whole scale, so this is the full doubling that takes exp2 to 191
        uint256 valuation = valuationOf(1);
        assertEq(valuation, 122730920814699141510468829034012455559); // 2^126 / ln2, a third of uint128
        assertLt(valuation, type(uint128).max);

        fund(valuation + 1, 0);
        vm.prank(alice);
        auction.accept(address(usdfc), 1, uint128(valuation + 1));
        assertEq(logPriceOf(address(usdfc)), int64(LOG_MAX));
    }

    /// @dev nothing lowers the stored lot: it is floored at `available`, which only a donation moves,
    /// and the decay term is the one input a griefer cannot buy
    function testGrieferCannotLowerTheLot() public {
        fund(WHOLE_OF_16 + 1, 16 ether);
        vm.prank(alice);
        auction.accept(address(usdfc), 16 ether, uint128(WHOLE_OF_16 + 1));
        assertEq(scaleOf(address(usdfc)), 16 ether);
        uint256 snap = vm.snapshotState();

        // left alone, one half-life halves the memory
        vm.roll(vm.getBlockNumber() + SCALE_HALF_LIFE);
        fund(1, 0);
        vm.prank(alice);
        auction.accept(address(usdfc), 0, 1);
        uint256 control = scaleOf(address(usdfc));
        assertEq(control, 8 ether);

        vm.revertToState(snap);

        // the cheapest attack is to compound that decay, one empty attoFIL accept per epoch
        fund(SCALE_HALF_LIFE, 0);
        for (uint256 i = 0; i < SCALE_HALF_LIFE; i++) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.prank(alice);
            auction.accept(address(usdfc), 0, 1);
        }
        uint256 attacked = scaleOf(address(usdfc));

        // 1024 accepts land 5,197 wei above the control: exp2 rounds down, so compounding the
        // decay in steps loses less than applying it once, and the griefer pays to raise the lot
        assertGe(attacked, control);
        assertLt(attacked - control, 1e5);
    }

    function testGrieferRaisingTheLotCostsMoreThanItSaves() public {
        fund(2 ether, 1 ether);
        uint256 first = valuationOf(1 ether);
        vm.prank(alice);
        auction.accept(address(usdfc), 1 ether, uint128(first + 1));
        assertEq(scaleOf(address(usdfc)), 1 ether);

        // one halving undoes the doubling that sale produced, so a unit is back to 1 attoFIL
        vm.roll(vm.getBlockNumber() + HALVING_INTERVAL);
        fund(0, 1 ether);
        uint256 unmanipulated = valuationOf(1 ether);
        assertEq(unmanipulated, 1442695040888963408); // 1 ether / ln2

        // the cheapest raise: donate, then commit the inflated balance with an empty accept
        fund(1, 15 ether);
        vm.prank(alice);
        auction.accept(address(usdfc), 0, 1);
        assertEq(scaleOf(address(usdfc)), 16 ether);

        // a 16x lot caps the saving at what convexity was worth, 1 - ln2 of the clear
        uint256 saved = unmanipulated - valuationOf(1 ether);
        assertEq(saved, 420717979298133336);

        // the donation is 15 ether at the auction's own unit price, and it is unwithdrawable:
        // forfeiting gifts the protocol 35 clears worth of saving, buying it back costs 51
        assertGt(15 ether, saved * 35);
        assertGt(valuationOf(16 ether) - unmanipulated, saved * 51);
    }
}
