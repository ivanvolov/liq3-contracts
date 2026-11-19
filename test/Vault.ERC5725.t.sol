// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestBase} from "@test/core/TestBase.sol";
import {IBondVault} from "@src/interfaces/IBondVault.sol";
import {IERC5725} from "@src/interfaces/IERC5725.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract VaultERC5725Test is TestBase {
    uint256 internal tokenId;
    uint256 internal constant PRINCIPAL = 10_000e6;

    function setUp() public override {
        super.setUp();
        tokenId = _depositUsdt(alice, PRINCIPAL, T_USDT_90);
    }

    function test_supportsInterface_andPublishedId() public view {
        assertTrue(vault.supportsInterface(type(IERC5725).interfaceId), "ERC-5725 declared");
        assertEq(type(IERC5725).interfaceId, bytes4(0xbd3a202b), "matches the id published in EIP-5725");
        assertTrue(vault.supportsInterface(type(IERC721).interfaceId), "plain ERC-721");
        assertTrue(vault.supportsInterface(type(IAccessControl).interfaceId));
    }

    function test_vestingViews() public {
        (uint256 start, uint256 end) = vault.vestingPeriod(tokenId);
        assertEq(start, block.timestamp);
        assertEq(end, block.timestamp + 90 days);
        assertEq(vault.payoutToken(tokenId), address(usdt));

        // at entry: principal vested, all interest still vesting
        assertEq(vault.vestedPayout(tokenId), PRINCIPAL);
        uint256 fullInterest = _basePayout(PRINCIPAL, 800, 90 days) - PRINCIPAL;
        assertEq(vault.vestingPayout(tokenId), fullInterest);

        // halfway: half the interest accrued
        vm.warp(block.timestamp + 45 days);
        assertEq(vault.vestedPayout(tokenId), PRINCIPAL + fullInterest / 2);

        // past maturity: capped at the full base plan
        vm.warp(block.timestamp + 400 days);
        assertEq(vault.vestedPayout(tokenId), PRINCIPAL + fullInterest);
        assertEq(vault.vestingPayout(tokenId), 0);
    }

    function test_claimablePayout_lifecycle() public {
        assertEq(vault.claimablePayout(tokenId), 0, "no request yet");

        _requestWithdraw(alice, tokenId);
        assertEq(vault.claimablePayout(tokenId), 0, "pending, unfunded");

        _fundTreasuryUsdt(PRINCIPAL);
        _fund(tokenId, PRINCIPAL);
        assertEq(vault.claimablePayout(tokenId), 0, "funded but still timelocked");

        vm.warp(block.timestamp + 7 days);
        assertEq(vault.claimablePayout(tokenId), PRINCIPAL, "funded and unlocked");

        vm.prank(alice);
        vault.claim(tokenId);
        assertEq(vault.claimedPayout(tokenId), PRINCIPAL, "readable after the burn");
    }

    function test_claim_equalsWithdraw() public {
        _requestWithdraw(alice, tokenId);
        _fundTreasuryUsdt(PRINCIPAL);
        _fund(tokenId, PRINCIPAL);
        vm.warp(block.timestamp + 7 days);

        vm.prank(alice);
        vault.claim(tokenId);
        assertEq(usdt.balanceOf(alice), PRINCIPAL);
    }

    function test_claim_reverts_noRequest() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.RequestNotClaimable.selector, tokenId));
        vault.claim(tokenId);
    }

    function test_claimApproval_perToken() public {
        _requestWithdraw(alice, tokenId);
        _fundTreasuryUsdt(PRINCIPAL);
        _fund(tokenId, PRINCIPAL);
        vm.warp(block.timestamp + 7 days);

        address keeper = makeAddr("keeper");
        vm.prank(alice);
        vault.setClaimApproval(keeper, true, tokenId);
        assertEq(vault.getClaimApproved(tokenId), keeper);

        vm.prank(keeper);
        vault.claim(tokenId);
        assertEq(usdt.balanceOf(alice), PRINCIPAL, "keeper triggers, the owner is paid");
        assertEq(usdt.balanceOf(keeper), 0);
    }

    function test_claimApprovalForAll() public {
        address keeper = makeAddr("keeper");
        vm.prank(alice);
        vault.setClaimApprovalForAll(keeper, true);
        assertTrue(vault.isClaimApprovedForAll(alice, keeper));
    }

    function test_claimApproval_clearedOnTransfer_withEvent() public {
        address keeper = makeAddr("keeper");
        vm.prank(alice);
        vault.setClaimApproval(keeper, true, tokenId);

        vm.expectEmit(true, true, true, true);
        emit IERC5725.ClaimApproval(alice, keeper, tokenId, false);
        vm.prank(alice);
        vault.transferFrom(alice, bob, tokenId);
        assertEq(vault.getClaimApproved(tokenId), address(0), "approval is the seller's, not the buyer's");
    }

    function test_setClaimApproval_ownerOnly() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.NotTokenOwnerOrApproved.selector, tokenId, bob));
        vault.setClaimApproval(bob, true, tokenId);
    }
}
