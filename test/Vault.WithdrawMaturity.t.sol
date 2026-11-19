// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestBase} from "@test/core/TestBase.sol";
import {IBondVault} from "@src/interfaces/IBondVault.sol";

contract VaultWithdrawMaturityTest is TestBase {
    uint256 internal tokenId;
    uint256 internal constant PRINCIPAL = 10_000e6;

    function setUp() public override {
        super.setUp();
        tokenId = _depositUsdt(alice, PRINCIPAL, T_USDT_90);
    }

    function _warpToMaturity() internal {
        vm.warp(_maturity(tokenId));
    }

    function test_interestMath_exactUsdtNumbers() public pure {
        // 10,000 USDT, 8.00% (800 bps), 90 days, ACT/365:
        // 10_000e6 * 800 * 90 / (10_000 * 365) = 197_260_273 (~$197.26)
        uint256 expected = PRINCIPAL + (PRINCIPAL * 800 * 90 days) / (10_000 * 365 days);
        assertEq(expected, PRINCIPAL + 197_260_273);
        assertEq(_basePayout(PRINCIPAL, 800, 90 days), expected);
    }

    function test_request_atMaturity_isNotEarly() public {
        _warpToMaturity(); // exactly at maturity: the position has served its term
        _requestWithdraw(alice, tokenId);
        IBondVault.WithdrawRequest memory r = vault.getRequest(tokenId);
        assertFalse(r.early);
        assertEq(vault.claimableAtOf(tokenId), block.timestamp + 2 days, "maturity window, not the early one");
        assertEq(_baseOf(tokenId), _basePayout(PRINCIPAL, 800, 90 days));
    }

    function test_request_oneSecondBeforeMaturity_isEarly() public {
        vm.warp(_maturity(tokenId) - 1);
        _requestWithdraw(alice, tokenId);
        assertTrue(vault.getRequest(tokenId).early);
        assertEq(_baseOf(tokenId), PRINCIPAL, "one second early still burns all interest");
    }

    function test_fund_reverts_belowBasePlan() public {
        _warpToMaturity();
        _requestWithdraw(alice, tokenId);
        uint256 base = _baseOf(tokenId);
        _fundTreasuryUsdt(base);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.PayoutBelowBase.selector, tokenId, base - 1, base));
        vault.fundAndApproveClaim(tokenId, base - 1);
    }

    function test_fund_exactBase_ok() public {
        _warpToMaturity();
        _requestWithdraw(alice, tokenId);
        uint256 base = _baseOf(tokenId);
        _fundTreasuryUsdt(base);
        _fund(tokenId, base);

        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        vault.claim(tokenId);
        assertEq(usdt.balanceOf(alice), base, "principal + the APR written in the position");
    }

    function test_fund_withBonus_contractAllowsPayingMore() public {
        // Rewards (campaigns, points, boosts) have no onchain life: at maturity the
        // operator simply funds a larger amount than the position promises.
        _warpToMaturity();
        _requestWithdraw(alice, tokenId);
        uint256 base = _baseOf(tokenId);
        uint256 boosted = base + (base * 300) / 10_000; // +3% boost, inside the 50% cap
        _fundTreasuryUsdt(boosted);
        _fund(tokenId, boosted);

        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        vault.claim(tokenId);
        assertEq(usdt.balanceOf(alice), boosted, "never less than the base plan, here more");
    }

    function test_fund_reverts_aboveBonusCap() public {
        // The operator is a hot key; its generosity is bounded by maxBonusBps.
        _warpToMaturity();
        _requestWithdraw(alice, tokenId);
        uint256 base = _baseOf(tokenId);
        uint256 cap = base + (base * 5_000) / 10_000;
        _fundTreasuryUsdt(cap + 1);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.PayoutAboveCap.selector, tokenId, cap + 1, cap));
        vault.fundAndApproveClaim(tokenId, cap + 1);
    }

    function test_maturityWindow_paramIndependentFromEarly() public {
        vm.prank(manager);
        vault.setWithdrawWindowParam(false, 5 days); // maturity window only

        _warpToMaturity();
        _requestWithdraw(alice, tokenId);
        assertEq(vault.claimableAtOf(tokenId), block.timestamp + 5 days);

        // the early window is untouched
        uint256 token2 = _depositUsdt(bob, USDT_1K, T_USDT_30);
        _requestWithdraw(bob, token2);
        assertEq(vault.claimableAtOf(token2), block.timestamp + 7 days);
    }

    function test_longAfterMaturity_interestDoesNotKeepAccruing() public {
        // A position that sat unclaimed for a year after maturity still pays exactly
        // the term's interest — the APR written in the position, not a day more.
        vm.warp(_maturity(tokenId) + 365 days);
        _requestWithdraw(alice, tokenId);
        assertEq(_baseOf(tokenId), _basePayout(PRINCIPAL, 800, 90 days));
    }

    function test_decimals_wbtcSeriesMaturityPayout() public {
        uint256 btcToken = _depositWbtc(bob, 2e8, T_WBTC_90); // 2 BTC @ 3.00% 90d
        vm.warp(block.timestamp + 90 days);
        vm.prank(bob);
        vaultWbtc.requestWithdraw(btcToken);

        uint256 base = _basePayout(2e8, 300, 90 days);
        assertEq(_basePayout(2e8, 300, 90 days), base);

        wbtc.mint(treasury, base);
        vm.prank(operator);
        vaultWbtc.fundAndApproveClaim(btcToken, base);
        vm.warp(block.timestamp + 2 days);
        vm.prank(bob);
        vaultWbtc.claim(btcToken);
        assertEq(wbtc.balanceOf(bob), base);
    }
}
