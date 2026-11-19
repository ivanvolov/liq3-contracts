// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestBase} from "@test/core/TestBase.sol";
import {IBondVault} from "@src/interfaces/IBondVault.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract VaultRollTest is TestBase {
    uint256 internal tokenId;
    uint256 internal constant PRINCIPAL = 10_000e6;

    function setUp() public override {
        super.setUp();
        tokenId = _depositUsdt(alice, PRINCIPAL, T_USDT_90);
    }

    function test_roll_reverts_beforeMaturity() public {
        vm.warp(_maturity(tokenId) - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.PositionNotMatured.selector, tokenId));
        vault.roll(tokenId, T_USDT_180);
    }

    function test_roll_burnsOldMintsNew_compoundsInterest() public {
        vm.warp(_maturity(tokenId));
        vm.prank(alice);
        uint256 newTokenId = vault.roll(tokenId, T_USDT_180);

        // old NFT burned
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId));
        vault.ownerOf(tokenId);

        // new bond: principal = old principal + earned base interest, fresh term copied
        uint256 expectedPrincipal = _basePayout(PRINCIPAL, 800, 90 days);
        IBondVault.Position memory p = vault.getPosition(newTokenId);
        assertEq(vault.ownerOf(newTokenId), alice);
        assertEq(p.principal, expectedPrincipal, "money never left the exchange: interest compounds in");
        assertEq(p.aprBps, 900, "new term's rate");
        assertEq(p.duration, 180 days);
        assertEq(p.startTime, block.timestamp);
    }

    function test_roll_reverts_withActiveRequest() public {
        vm.warp(_maturity(tokenId));
        _requestWithdraw(alice, tokenId);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.RequestAlreadyExists.selector, tokenId));
        vault.roll(tokenId, T_USDT_180);
    }

    function test_roll_reverts_disabledTerm() public {
        vm.warp(_maturity(tokenId));
        vm.prank(manager);
        vault.setTerm(T_USDT_180, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.TermNotEnabled.selector, T_USDT_180));
        vault.roll(tokenId, T_USDT_180);
    }

    function test_roll_reverts_notOwner() public {
        vm.warp(_maturity(tokenId));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.NotTokenOwnerOrApproved.selector, tokenId, bob));
        vault.roll(tokenId, T_USDT_180);
    }

    function test_roll_erc721ApprovedCannotRoll() public {
        vm.warp(_maturity(tokenId));
        vm.prank(alice);
        vault.setApprovalForAll(bob, true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.NotTokenOwnerOrApproved.selector, tokenId, bob));
        vault.roll(tokenId, T_USDT_180);
    }

    function test_roll_reverts_whenPaused() public {
        // A roll is a re-deposit: pause (= money-in stop, also how a series is wound
        // down) blocks it.
        vm.warp(_maturity(tokenId));
        vm.prank(pauser);
        vault.pause();
        vm.prank(alice);
        vm.expectRevert();
        vault.roll(tokenId, T_USDT_180);
    }

    function test_manualRoll_dropsStandingAutoRoll() public {
        vm.prank(alice);
        vault.setAutoRoll(tokenId, T_USDT_90, 0);
        vm.warp(_maturity(tokenId));
        vm.prank(alice);
        uint256 newTokenId = vault.roll(tokenId, T_USDT_180);
        assertEq(vault.getAutoRoll(newTokenId).duration, 0, "manual roll = active choice, autoroll re-set if wanted");
    }

    // ** autoroll

    function test_setAutoRoll_ownerOnly_andStored() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.NotTokenOwnerOrApproved.selector, tokenId, bob));
        vault.setAutoRoll(tokenId, T_USDT_90, 750);

        vm.prank(alice);
        vault.setAutoRoll(tokenId, T_USDT_90, 750);
        IBondVault.AutoRoll memory ar = vault.getAutoRoll(tokenId);
        assertEq(ar.duration, T_USDT_90);
        assertEq(ar.minAprBps, 750);
    }

    function test_setAutoRoll_reverts_disabledTerm() public {
        vm.prank(manager);
        vault.setTerm(T_USDT_90, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.TermNotEnabled.selector, T_USDT_90));
        vault.setAutoRoll(tokenId, T_USDT_90, 0);
    }

    function test_setAutoRoll_reverts_withActiveRequest() public {
        _requestWithdraw(alice, tokenId);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.RequestAlreadyExists.selector, tokenId));
        vault.setAutoRoll(tokenId, T_USDT_90, 0);
    }

    function test_autoRoll_clearedOnTransfer() public {
        // Standing permission is personal to the owner who granted it: a buyer must
        // not inherit the seller's instruction to the operator.
        vm.prank(alice);
        vault.setAutoRoll(tokenId, T_USDT_90, 0);
        vm.prank(alice);
        vault.transferFrom(alice, bob, tokenId);
        assertEq(vault.getAutoRoll(tokenId).duration, 0);
    }

    function test_executeAutoRoll_operatorOnly() public {
        vm.prank(alice);
        vault.setAutoRoll(tokenId, T_USDT_90, 0);
        vm.warp(_maturity(tokenId));
        vm.prank(alice);
        vm.expectRevert();
        vault.executeAutoRoll(tokenId);
    }

    function test_executeAutoRoll_reverts_whenNotSet() public {
        vm.warp(_maturity(tokenId));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.AutoRollNotSet.selector, tokenId));
        vault.executeAutoRoll(tokenId);
    }

    function test_executeAutoRoll_honorsRateFloor() public {
        // The user picked a term, not a rate: if the grid moved below the floor the
        // operator must not be able to roll them into it.
        vm.prank(alice);
        vault.setAutoRoll(tokenId, T_USDT_90, 800);
        vm.warp(_maturity(tokenId));

        vm.prank(manager);
        vault.setTerm(T_USDT_90, 799); // one bp below the floor

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.AutoRollBelowMinApr.selector, tokenId, 799, 800));
        vault.executeAutoRoll(tokenId);
    }

    function test_executeAutoRoll_reverts_whenTermDropped() public {
        // The duration IS the term's identity, so the grid can only change its APR —
        // re-locking into a different duration is impossible by construction. If the
        // term is dropped (APR zeroed), the instruction dies cleanly.
        vm.prank(alice);
        vault.setAutoRoll(tokenId, T_USDT_90, 0);
        vm.warp(_maturity(tokenId));

        vm.prank(manager);
        vault.setTerm(T_USDT_90, 0);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.TermNotEnabled.selector, T_USDT_90));
        vault.executeAutoRoll(tokenId);
    }

    function test_executeAutoRoll_happyPath_carriesInstruction() public {
        vm.prank(alice);
        vault.setAutoRoll(tokenId, T_USDT_90, 750);
        vm.warp(_maturity(tokenId));

        vm.prank(operator);
        uint256 newTokenId = vault.executeAutoRoll(tokenId);

        assertEq(vault.ownerOf(newTokenId), alice);
        assertEq(vault.getPosition(newTokenId).principal, _basePayout(PRINCIPAL, 800, 90 days));

        // perpetual: the standing instruction follows onto the new bond
        IBondVault.AutoRoll memory ar = vault.getAutoRoll(newTokenId);
        assertEq(ar.duration, T_USDT_90);
        assertEq(ar.minAprBps, 750);

        // and can run again next maturity
        vm.warp(_maturity(newTokenId));
        vm.prank(operator);
        uint256 thirdId = vault.executeAutoRoll(newTokenId);
        assertEq(vault.getAutoRoll(thirdId).duration, T_USDT_90);
    }

    function test_executeAutoRoll_reverts_beforeMaturity() public {
        vm.prank(alice);
        vault.setAutoRoll(tokenId, T_USDT_90, 0);
        vm.warp(_maturity(tokenId) - 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.PositionNotMatured.selector, tokenId));
        vault.executeAutoRoll(tokenId);
    }

    function test_clearAutoRoll() public {
        vm.prank(alice);
        vault.setAutoRoll(tokenId, T_USDT_90, 0);
        vm.prank(alice);
        vault.clearAutoRoll(tokenId);
        assertEq(vault.getAutoRoll(tokenId).duration, 0);

        vm.warp(_maturity(tokenId));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.AutoRollNotSet.selector, tokenId));
        vault.executeAutoRoll(tokenId);
    }

    function test_rolledPosition_earlyExitIncludesCompoundedInterest() public {
        // After a roll, the previous term's interest IS the new principal — an early
        // exit from the new bond returns it (it was earned, not burned).
        vm.warp(_maturity(tokenId));
        vm.prank(alice);
        uint256 newTokenId = vault.roll(tokenId, T_USDT_180);
        uint256 newPrincipal = vault.getPosition(newTokenId).principal;

        vm.warp(block.timestamp + 10 days); // early in the new term
        _requestWithdraw(alice, newTokenId);
        assertEq(_baseOf(newTokenId), newPrincipal, "old interest kept, new interest burned");
    }
}
