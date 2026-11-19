// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestBase} from "@test/core/TestBase.sol";
import {IBondVault} from "@src/interfaces/IBondVault.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract VaultDepositTest is TestBase {
    function test_deposit_mintsPositionAndForwardsToCustody() public {
        uint256 tokenId = _depositUsdt(alice, 5_000e6, T_USDT_90);

        assertEq(vault.ownerOf(tokenId), alice, "NFT minted to depositor");
        assertEq(usdt.balanceOf(custodyUsdt), 5_000e6, "principal forwarded straight to the custody wallet");
        assertEq(usdt.balanceOf(address(vault)), 0, "vault holds no principal");

        IBondVault.Position memory p = vault.getPosition(tokenId);
        assertEq(p.principal, 5_000e6);
        assertEq(p.aprBps, 800);
        assertEq(p.duration, 90 days);
        assertEq(p.startTime, block.timestamp);
    }

    function test_deposit_emitsEvent() public {
        usdt.mint(alice, USDT_1K);
        vm.startPrank(alice);
        usdt.approve(address(vault), USDT_1K);
        vm.expectEmit(true, true, true, true);
        emit IBondVault.Deposited(1, alice, USDT_1K, 700, 30 days);
        vault.deposit(USDT_1K, T_USDT_30);
        vm.stopPrank();
    }

    function test_deposit_usdtSemantics_noReturnValueToken() public {
        // MockUSDT returns nothing from transferFrom — SafeERC20 must cope.
        uint256 tokenId = _depositUsdt(alice, USDT_1K, T_USDT_30);
        assertEq(vault.ownerOf(tokenId), alice);
    }

    function test_oneVaultPerAsset_seriesAreIndependent() public {
        uint256 idUsdt = _depositUsdt(alice, 5_000e6, T_USDT_90);
        uint256 idBtc = _depositWbtc(bob, 1e8, T_WBTC_90); // 1 BTC on its own series

        assertEq(address(vault.asset()), address(usdt));
        assertEq(address(vaultWbtc.asset()), address(wbtc));
        assertEq(vaultWbtc.getPosition(idBtc).principal, 1e8);
        assertEq(wbtc.balanceOf(custodyWbtc), 1e8);
        // token ids are per-series, not global
        assertEq(idUsdt, 1);
        assertEq(idBtc, 1);
    }

    function test_deposit_reverts_unknownTerm() public {
        // a duration the grid never set is simply not a term
        usdt.mint(alice, USDT_1K);
        vm.startPrank(alice);
        usdt.approve(address(vault), USDT_1K);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.TermNotEnabled.selector, 999));
        vault.deposit(USDT_1K, 999);
        vm.stopPrank();
    }

    function test_deposit_reverts_termDisabled() public {
        vm.prank(manager);
        vault.setTerm(T_USDT_30, 0);

        usdt.mint(alice, USDT_1K);
        vm.startPrank(alice);
        usdt.approve(address(vault), USDT_1K);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.TermNotEnabled.selector, T_USDT_30));
        vault.deposit(USDT_1K, T_USDT_30);
        vm.stopPrank();
    }

    function test_deposit_reverts_belowMinDeposit() public {
        usdt.mint(alice, USDT_1K - 1);
        vm.startPrank(alice);
        usdt.approve(address(vault), USDT_1K - 1);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.BelowMinDeposit.selector, USDT_1K - 1, USDT_1K));
        vault.deposit(USDT_1K - 1, T_USDT_30);
        vm.stopPrank();
    }

    function test_deposit_reverts_whenPaused() public {
        vm.prank(pauser);
        vault.pause();

        usdt.mint(alice, USDT_1K);
        vm.startPrank(alice);
        usdt.approve(address(vault), USDT_1K);
        vm.expectRevert();
        vault.deposit(USDT_1K, T_USDT_30);
        vm.stopPrank();
    }

    function test_termRewrite_affectsOnlyFuturePositions() public {
        uint256 before = _depositUsdt(alice, 2_000e6, T_USDT_90);

        vm.prank(manager);
        vault.setTerm(T_USDT_90, 500); // grid cut 8.00% -> 5.00%

        uint256 afterId = _depositUsdt(bob, 2_000e6, T_USDT_90);

        assertEq(vault.getPosition(before).aprBps, 800, "open position keeps the rate written at entry");
        assertEq(vault.getPosition(afterId).aprBps, 500, "new position gets the new grid");
    }

    function test_custodyChange_routesNewDeposits() public {
        address newCustody = makeAddr("newCustody");
        vm.prank(admin);
        vault.setCustody(newCustody);

        _depositUsdt(alice, USDT_1K, T_USDT_30);
        assertEq(usdt.balanceOf(newCustody), USDT_1K);
        assertEq(usdt.balanceOf(custodyUsdt), 0);
    }

    function test_custodyChange_onlyAdmin() public {
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                manager,
                bytes32(0) // DEFAULT_ADMIN_ROLE
            )
        );
        vault.setCustody(makeAddr("x"));
    }
}
