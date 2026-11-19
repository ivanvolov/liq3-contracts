// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestBase} from "@test/core/TestBase.sol";
import {IBondVault} from "@src/interfaces/IBondVault.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract VaultWithdrawEarlyTest is TestBase {
    uint256 internal tokenId;

    function setUp() public override {
        super.setUp();
        tokenId = _depositUsdt(alice, 10_000e6, T_USDT_90);
    }

    function test_requestWithdraw_early_statesAndWindow() public {
        vm.warp(block.timestamp + 10 days); // well before the 90d maturity
        _requestWithdraw(alice, tokenId);

        IBondVault.WithdrawRequest memory r = vault.getRequest(tokenId);
        assertEq(uint8(r.state), uint8(IBondVault.RequestState.Pending));
        assertTrue(r.early);
        assertEq(r.payout, 0, "unfunded until the operator delivers cash");
        assertEq(vault.claimableAtOf(tokenId), block.timestamp + 7 days, "the early-exit window");
        assertEq(_baseOf(tokenId), 10_000e6, "early exit owes the principal only");
    }

    function test_requestWithdraw_reverts_notOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.NotTokenOwnerOrApproved.selector, tokenId, bob));
        vault.requestWithdraw(tokenId);
    }

    function test_requestWithdraw_erc721ApprovedCannotRequest() public {
        // A transfer approval (marketplace-style) must NOT be able to trigger an
        // irreversible, interest-burning exit — strictly owner-only.
        vm.prank(alice);
        vault.approve(bob, tokenId);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.NotTokenOwnerOrApproved.selector, tokenId, bob));
        vault.requestWithdraw(tokenId);

        vm.prank(alice);
        vault.setApprovalForAll(bob, true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.NotTokenOwnerOrApproved.selector, tokenId, bob));
        vault.requestWithdraw(tokenId);
    }

    function test_requestWithdraw_reverts_secondRequest() public {
        _requestWithdraw(alice, tokenId);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.RequestAlreadyExists.selector, tokenId));
        vault.requestWithdraw(tokenId);
    }

    function test_requestWithdraw_notCancellable() public {
        // The spec: a window in which the user can NOT cancel. There is simply no
        // cancel surface — the only path out of a request is the funded claim.
        _requestWithdraw(alice, tokenId);
        vm.prank(alice);
        vault.transferFrom(alice, bob, tokenId);
        assertEq(
            uint8(vault.getRequest(tokenId).state), uint8(IBondVault.RequestState.Pending), "request survives transfer"
        );
    }

    function test_fund_reverts_notOperator() public {
        _requestWithdraw(alice, tokenId);
        _fundTreasuryUsdt(10_000e6);
        vm.prank(alice);
        vm.expectRevert();
        vault.fundAndApproveClaim(tokenId, 10_000e6);
    }

    function test_fund_early_mustBeExactPrincipal() public {
        _requestWithdraw(alice, tokenId);
        _fundTreasuryUsdt(20_000e6);

        // one wei off principal in either direction: the early rule is principal exactly
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IBondVault.EarlyPayoutNotExact.selector, tokenId, 10_000e6 + 1, 10_000e6)
        );
        vault.fundAndApproveClaim(tokenId, 10_000e6 + 1);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IBondVault.EarlyPayoutNotExact.selector, tokenId, 10_000e6 - 1, 10_000e6)
        );
        vault.fundAndApproveClaim(tokenId, 10_000e6 - 1);
    }

    function test_fund_pullsCashInSameTransaction() public {
        _requestWithdraw(alice, tokenId);

        // treasury Safe empty -> funding MUST fail: approval without cash is impossible
        vm.prank(operator);
        vm.expectRevert();
        vault.fundAndApproveClaim(tokenId, 10_000e6);

        // with cash it works and the money lands on the vault
        _fundTreasuryUsdt(10_000e6);
        _fund(tokenId, 10_000e6);
        assertEq(usdt.balanceOf(address(vault)), 10_000e6);
        assertEq(usdt.balanceOf(treasury), 0);
        assertEq(vault.totalClaimableObligations(), 10_000e6);
        assertEq(uint8(vault.getRequest(tokenId).state), uint8(IBondVault.RequestState.Claimable));
    }

    function test_fund_reverts_doubleFunding() public {
        _requestWithdraw(alice, tokenId);
        _fundTreasuryUsdt(20_000e6);
        _fund(tokenId, 10_000e6);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.RequestNotPending.selector, tokenId));
        vault.fundAndApproveClaim(tokenId, 10_000e6);
    }

    function test_withdraw_reverts_beforeWindowEvenIfFunded() public {
        _requestWithdraw(alice, tokenId);
        uint256 claimableAt = vault.claimableAtOf(tokenId);
        _fundTreasuryUsdt(10_000e6);
        _fund(tokenId, 10_000e6);

        vm.warp(claimableAt - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.RequestTimelocked.selector, tokenId, claimableAt));
        vault.claim(tokenId);
    }

    function test_withdraw_reverts_unfunded() public {
        _requestWithdraw(alice, tokenId);
        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.RequestNotClaimable.selector, tokenId));
        vault.claim(tokenId);
    }

    function test_withdraw_happyPath_burnsAndPays() public {
        _requestWithdraw(alice, tokenId);
        _fundTreasuryUsdt(10_000e6);
        _fund(tokenId, 10_000e6);
        vm.warp(block.timestamp + 7 days);

        vm.prank(alice);
        vault.claim(tokenId);

        assertEq(usdt.balanceOf(alice), 10_000e6, "principal back, zero interest");
        assertEq(usdt.balanceOf(address(vault)), 0);
        assertEq(vault.totalClaimableObligations(), 0);
        assertEq(uint8(vault.getRequest(tokenId).state), uint8(IBondVault.RequestState.Claimed));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId));
        vault.ownerOf(tokenId);
    }

    function test_withdraw_paysCurrentOwnerAfterTransfer() public {
        // The NFT stays transferable after the claim request: the payout always goes
        // to the current owner.
        _requestWithdraw(alice, tokenId);
        _fundTreasuryUsdt(10_000e6);
        _fund(tokenId, 10_000e6);

        vm.prank(alice);
        vault.transferFrom(alice, bob, tokenId); // secondary-market sale mid-queue

        vm.warp(block.timestamp + 7 days);
        vm.prank(bob);
        vault.claim(tokenId);

        assertEq(usdt.balanceOf(bob), 10_000e6, "buyer gets the payout");
        assertEq(usdt.balanceOf(alice), 0, "seller got paid on the secondary market, not here");
    }

    function test_withdraw_reverts_strangerCannotClaim() public {
        _requestWithdraw(alice, tokenId);
        _fundTreasuryUsdt(10_000e6);
        _fund(tokenId, 10_000e6);
        vm.warp(block.timestamp + 7 days);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.NotTokenOwnerOrApproved.selector, tokenId, bob));
        vault.claim(tokenId);
    }

    function test_withdraw_worksWhilePaused() public {
        // The exit pipeline is never pausable.
        _requestWithdraw(alice, tokenId);
        _fundTreasuryUsdt(10_000e6);
        _fund(tokenId, 10_000e6);
        vm.warp(block.timestamp + 7 days);

        vm.prank(pauser);
        vault.pause();

        vm.prank(alice);
        vault.claim(tokenId);
        assertEq(usdt.balanceOf(alice), 10_000e6);
    }

    function test_windowChange_isRetroactive_movesWholeQueue() public {
        // Queue extension is retroactive: the whole queue moves to the new window,
        // already-filed requests included.
        _requestWithdraw(alice, tokenId);
        uint256 requestedAt = block.timestamp;
        assertEq(vault.claimableAtOf(tokenId), requestedAt + 7 days);

        vm.prank(manager);
        vault.setWithdrawWindowParam(true, 14 days);

        assertEq(vault.claimableAtOf(tokenId), requestedAt + 14 days, "in-flight request moved too");

        _fundTreasuryUsdt(10_000e6);
        _fund(tokenId, 10_000e6);
        vm.warp(requestedAt + 7 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.RequestTimelocked.selector, tokenId, requestedAt + 14 days));
        vault.claim(tokenId);

        vm.warp(requestedAt + 14 days);
        vm.prank(alice);
        vault.claim(tokenId);
        assertEq(usdt.balanceOf(alice), 10_000e6);
    }

    function test_windowChange_isBounded() public {
        // Retroactivity is safe only because the window is hard-capped.
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.WindowTooLong.selector, 31 days, 30 days));
        vault.setWithdrawWindowParam(true, 31 days);
    }

    function test_requestWithdraw_clearsAutoRoll() public {
        vm.prank(alice);
        vault.setAutoRoll(tokenId, T_USDT_90, 0);
        _requestWithdraw(alice, tokenId);
        assertEq(vault.getAutoRoll(tokenId).duration, 0, "exiting position has no roll future");
    }

    function test_funding_multipleRequests() public {
        // No batching machinery: the bot simply sends one call per request.
        uint256 token2 = _depositUsdt(bob, 3_000e6, T_USDT_30);
        _requestWithdraw(alice, tokenId);
        _requestWithdraw(bob, token2);
        _fundTreasuryUsdt(13_000e6);

        _fund(tokenId, 10_000e6);
        _fund(token2, 3_000e6);

        assertEq(usdt.balanceOf(address(vault)), 13_000e6);
        assertEq(vault.totalClaimableObligations(), 13_000e6);

        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        vault.claim(tokenId);
        vm.prank(bob);
        vault.claim(token2);
        assertEq(usdt.balanceOf(alice), 10_000e6);
        assertEq(usdt.balanceOf(bob), 3_000e6);
    }
}
