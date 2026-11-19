// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestBase} from "@test/core/TestBase.sol";
import {IBondVault} from "@src/interfaces/IBondVault.sol";

/// @notice Randomized-sequence handler: users deposit, request, transfer; the operator
///         funds (sometimes with a bonus); users withdraw — in any order the fuzzer
///         picks. Scope is deliberately the one USDT series; the invariant it guards
///         (balance == obligations) is series-local by construction.
contract VaultHandler is Test {
    InvariantTest internal base;
    uint256[] public active; // positions without a request
    uint256[] public pending;
    uint256[] public claimable;

    constructor(InvariantTest base_) {
        base = base_;
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1_000e6, 1_000_000e6);
        active.push(base.exposedDeposit(amount));
    }

    function requestWithdraw(uint256 seed) external {
        if (active.length == 0) return;
        uint256 idx = seed % active.length;
        uint256 tokenId = active[idx];
        base.exposedRequest(tokenId);
        active[idx] = active[active.length - 1];
        active.pop();
        pending.push(tokenId);
    }

    function fund(uint256 seed) external {
        if (pending.length == 0) return;
        uint256 idx = seed % pending.length;
        uint256 tokenId = pending[idx];
        base.exposedFund(tokenId);
        pending[idx] = pending[pending.length - 1];
        pending.pop();
        claimable.push(tokenId);
    }

    function withdraw(uint256 seed) external {
        if (claimable.length == 0) return;
        uint256 idx = seed % claimable.length;
        if (!base.exposedWithdraw(claimable[idx])) return;
        claimable[idx] = claimable[claimable.length - 1];
        claimable.pop();
    }

    function transferPosition(uint256 seed) external {
        uint256 total = active.length + pending.length + claimable.length;
        if (total == 0) return;
        uint256 idx = seed % total;
        uint256 tokenId = idx < active.length
            ? active[idx]
            : idx < active.length + pending.length
                ? pending[idx - active.length]
                : claimable[idx - active.length - pending.length];
        base.exposedTransfer(tokenId);
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1 hours, 30 days);
        vm.warp(block.timestamp + secs);
    }

    function claimableCount() external view returns (uint256) {
        return claimable.length;
    }

    function claimableAt(uint256 i) external view returns (uint256) {
        return claimable[i];
    }
}

contract InvariantTest is TestBase {
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new VaultHandler(this);
        targetContract(address(handler));
    }

    // ** handler-callable wrappers (the handler has no prank rights of its own)

    function exposedDeposit(uint256 amount) external returns (uint256 tokenId) {
        return _depositUsdt(alice, amount, T_USDT_90);
    }

    function exposedRequest(uint256 tokenId) external {
        vm.prank(vault.ownerOf(tokenId));
        vault.requestWithdraw(tokenId);
    }

    function exposedFund(uint256 tokenId) external {
        uint256 payout = _baseOf(tokenId);
        // matured requests sometimes get a bonus on top of base (never early ones)
        if (!vault.getRequest(tokenId).early && tokenId % 2 == 0) payout += payout / 100;
        _fundTreasuryUsdt(payout);
        _fund(tokenId, payout);
    }

    function exposedWithdraw(uint256 tokenId) external returns (bool) {
        if (block.timestamp < vault.claimableAtOf(tokenId)) return false;
        vm.prank(vault.ownerOf(tokenId));
        vault.claim(tokenId);
        return true;
    }

    function exposedTransfer(uint256 tokenId) external {
        address owner = vault.ownerOf(tokenId);
        address to = owner == alice ? bob : alice;
        vm.prank(owner);
        vault.transferFrom(owner, to, tokenId);
    }

    /// @notice THE solvency invariant: whatever the sequence, the vault's balance
    ///         always equals its funded-but-unclaimed obligations. Money can never be
    ///         approved without being delivered, and can never leak.
    function invariant_vaultBalanceMatchesObligations() public view {
        assertEq(usdt.balanceOf(address(vault)), vault.totalClaimableObligations());
    }

    /// @notice Every claimable request is individually covered by the vault balance.
    function invariant_everyClaimableRequestIsCovered() public view {
        uint256 n = handler.claimableCount();
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            total += vault.getRequest(handler.claimableAt(i)).payout;
        }
        assertLe(total, usdt.balanceOf(address(vault)));
    }
}
