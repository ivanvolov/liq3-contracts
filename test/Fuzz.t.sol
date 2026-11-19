// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestBase} from "@test/core/TestBase.sol";
import {TermMath} from "@src/libraries/TermMath.sol";
import {IBondVault} from "@src/interfaces/IBondVault.sol";

contract FuzzTest is TestBase {
    /// @notice Interest math never overflows over the entire realistic domain
    ///         (principal up to 1e38 — beyond any supply; APR up to 655.35%;
    ///         duration up to 10 years).
    function testFuzz_termMath_interest_bounded(uint128 principal, uint16 aprBps, uint32 duration) public pure {
        duration = uint32(bound(duration, 1, 3650 days));
        uint256 interest = TermMath.interest(principal, aprBps, duration);
        assertLe(interest, (uint256(principal) * 65_535 * 3650) / (10_000 * 365));
    }

    function testFuzz_termMath_accrued_capsAtMaturity(uint128 principal, uint16 aprBps, uint32 duration, uint40 at)
        public
        pure
    {
        duration = uint32(bound(duration, 1, 3650 days));
        uint256 start = 1_790_000_000;
        uint256 accrued = TermMath.accruedAt(principal, aprBps, start, duration, at);
        uint256 full = TermMath.interest(principal, aprBps, duration);
        assertLe(accrued, full, "accrual is capped at the full term");
        if (at >= start + duration) assertEq(accrued, full);
        if (at <= start) assertEq(accrued, 0);
    }

    /// @notice Deposit -> mature -> fund(base) -> withdraw returns exactly
    ///         principal + interest for any amount and any term in the grid.
    function testFuzz_fullCycle_maturityPayoutExact(uint256 amount, uint8 termIndex) public {
        amount = bound(amount, USDT_1K, 1_000_000_000e6); // $1k .. $1B
        uint32[4] memory grid = [T_USDT_30, T_USDT_90, T_USDT_180, T_USDT_360];
        uint32 duration = grid[termIndex % 4];

        uint256 tokenId = _depositUsdt(alice, amount, duration);
        IBondVault.Position memory p = vault.getPosition(tokenId);

        vm.warp(uint256(p.startTime) + p.duration);
        _requestWithdraw(alice, tokenId);
        uint256 base = _baseOf(tokenId);
        assertEq(base, _basePayout(amount, p.aprBps, p.duration), "contract and test derive the same number");

        _fundTreasuryUsdt(base);
        _fund(tokenId, base);
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        vault.claim(tokenId);

        assertEq(usdt.balanceOf(alice), base);
        assertEq(usdt.balanceOf(address(vault)), 0, "vault drained to exactly zero, no dust stranded");
    }

    /// @notice Early exit returns exactly the principal for any timing inside the term.
    function testFuzz_fullCycle_earlyPayoutIsPrincipal(uint256 amount, uint32 elapsed) public {
        amount = bound(amount, USDT_1K, 1_000_000_000e6);
        uint256 tokenId = _depositUsdt(alice, amount, T_USDT_360);
        elapsed = uint32(bound(elapsed, 0, 360 days - 1));

        vm.warp(block.timestamp + elapsed);
        _requestWithdraw(alice, tokenId);
        assertEq(_baseOf(tokenId), amount, "principal only, whatever the timing");

        _fundTreasuryUsdt(amount);
        _fund(tokenId, amount);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        vault.claim(tokenId);
        assertEq(usdt.balanceOf(alice), amount);
    }

    /// @notice The funding bounds hold for any operator-chosen payout: below base and
    ///         above cap always revert, anything inside always succeeds.
    function testFuzz_fundingBounds(uint256 payout) public {
        uint256 tokenId = _depositUsdt(alice, 10_000e6, T_USDT_90);
        vm.warp(_maturity(tokenId));
        _requestWithdraw(alice, tokenId);
        uint256 base = _baseOf(tokenId);
        uint256 cap = base + (base * vault.maxBonusBps()) / 10_000;

        payout = bound(payout, 0, cap * 2);
        _fundTreasuryUsdt(cap * 2);

        vm.prank(operator);
        if (payout < base || payout > cap) {
            vm.expectRevert();
            vault.fundAndApproveClaim(tokenId, payout);
        } else {
            vault.fundAndApproveClaim(tokenId, payout);
            assertEq(vault.getRequest(tokenId).payout, payout);
        }
    }

    /// @notice Rolling N times compounds exactly like the closed-form product.
    function testFuzz_rollCompounding(uint8 rounds) public {
        rounds = uint8(bound(rounds, 1, 8));
        uint256 tokenId = _depositUsdt(alice, 10_000e6, T_USDT_90);

        uint256 expected = 10_000e6;
        for (uint256 i = 0; i < rounds; i++) {
            expected = _basePayout(expected, 800, 90 days);
            vm.warp(_maturity(tokenId));
            vm.prank(alice);
            tokenId = vault.roll(tokenId, T_USDT_90);
        }
        assertEq(vault.getPosition(tokenId).principal, expected);
    }
}
