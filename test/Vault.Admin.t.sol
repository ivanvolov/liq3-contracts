// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestBase} from "@test/core/TestBase.sol";
import {IBondVault} from "@src/interfaces/IBondVault.sol";
import {BondVault} from "@src/BondVault.sol";
import {BondVaultV2} from "@test/mocks/BondVaultV2.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract VaultAdminTest is TestBase {
    function test_roles_managerSettersRejectStrangers() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.setMinDeposit(0);
        vm.expectRevert();
        vault.setTerm(30 days, 700);
        vm.expectRevert();
        vault.setWithdrawWindowParam(true, 1 days);
        vm.expectRevert();
        vault.setMaxBonusBps(100);
        vm.expectRevert();
        vault.unpause();
        vm.stopPrank();
    }

    function test_roles_adminSettersRejectManager() public {
        // manager is deliberately weaker than admin: custody and treasury moves are
        // timelocked-admin territory
        vm.startPrank(manager);
        vm.expectRevert();
        vault.setCustody(makeAddr("x"));
        vm.expectRevert();
        vault.setTreasury(makeAddr("x"));
        vm.stopPrank();
    }

    function test_roles_operatorCannotTouchParams() public {
        vm.startPrank(operator);
        vm.expectRevert();
        vault.setWithdrawWindowParam(true, 1);
        vm.expectRevert();
        vault.setMaxBonusBps(100);
        vm.stopPrank();
    }

    function test_managerRevokesHotKeysWithoutTimelock() public {
        // OPERATOR/PAUSER are MANAGER-administered: a leaked hot key is disarmed by
        // the multisig immediately, not after the 2-day admin timelock.
        bytes32 operatorRole = vault.OPERATOR_ROLE();
        bytes32 pauserRole = vault.PAUSER_ROLE();

        vm.startPrank(manager);
        vault.revokeRole(operatorRole, operator);
        vault.revokeRole(pauserRole, pauser);
        vm.stopPrank();
        assertFalse(vault.hasRole(operatorRole, operator));
        assertFalse(vault.hasRole(pauserRole, pauser));

        // ...and the admin (timelock) cannot grant them directly anymore
        vm.prank(admin);
        vm.expectRevert();
        vault.grantRole(operatorRole, operator);
    }

    function test_setWithdrawWindow_rejectsZero() public {
        vm.prank(manager);
        vm.expectRevert(IBondVault.ZeroWindow.selector);
        vault.setWithdrawWindowParam(true, 0);
    }

    function test_setMaxBonusBps_capped() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.BonusCapTooHigh.selector, 10_001, 10_000));
        vault.setMaxBonusBps(10_001);

        vm.prank(manager);
        vault.setMaxBonusBps(10_000); // exactly the cap is fine
        assertEq(vault.maxBonusBps(), 10_000);
    }

    function test_pause_gating() public {
        vm.prank(alice); // stranger cannot pause
        vm.expectRevert();
        vault.pause();

        vm.prank(pauser);
        vault.pause();

        vm.prank(pauser); // pauser cannot unpause — that is manager's call
        vm.expectRevert();
        vault.unpause();

        vm.prank(manager);
        vault.unpause();
    }

    function test_pause_blocksMoneyInOnly() public {
        uint256 tokenId = _depositUsdt(alice, 10_000e6, T_USDT_90);
        vm.prank(pauser);
        vault.pause();

        // the whole exit pipeline still flows under pause
        _requestWithdraw(alice, tokenId);
        uint256 base = _baseOf(tokenId);
        _fundTreasuryUsdt(base);
        _fund(tokenId, base);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        vault.claim(tokenId);
        assertEq(usdt.balanceOf(alice), base, "paused vault cannot trap exits");
    }

    function test_upgrade_adminOnly_andStatePreserved() public {
        uint256 tokenId = _depositUsdt(alice, 5_000e6, T_USDT_90);

        BondVaultV2 v2 = new BondVaultV2();

        vm.prank(manager);
        vm.expectRevert();
        vault.upgradeToAndCall(address(v2), "");

        vm.prank(admin);
        vault.upgradeToAndCall(address(v2), "");

        assertEq(BondVaultV2(address(vault)).version(), 2, "new logic live");
        assertEq(vault.ownerOf(tokenId), alice, "positions survive the upgrade");
        assertEq(vault.getPosition(tokenId).principal, 5_000e6);
        assertEq(vault.terms(T_USDT_90), 800, "params survive the upgrade");
    }

    function test_initialize_cannotRerun() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize("x", "x", alice, IERC20(address(usdt)), treasury, custodyUsdt);
    }

    function test_implementation_cannotBeInitialized() public {
        BondVault impl = new BondVault();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize("x", "x", alice, IERC20(address(usdt)), treasury, custodyUsdt);
    }

    function test_setTreasury_redirectsFunding() public {
        // the treasury is just a Safe address; a new Safe takes over by granting its
        // own allowance
        address newSafe = makeAddr("newSafe");
        vm.prank(admin);
        vault.setTreasury(newSafe);
        vm.startPrank(newSafe);
        usdt.approve(address(vault), 0);
        usdt.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        uint256 tokenId = _depositUsdt(alice, USDT_1K, T_USDT_30);
        _requestWithdraw(alice, tokenId);
        usdt.mint(newSafe, USDT_1K);
        _fund(tokenId, USDT_1K);
        assertEq(usdt.balanceOf(newSafe), 0, "pulled from the new Safe");
    }

    function test_rescueToken_cappedByClaimFloat() public {
        // fund a claim so the vault holds earmarked money
        uint256 tokenId = _depositUsdt(alice, 5_000e6, T_USDT_30);
        _requestWithdraw(alice, tokenId);
        _fundTreasuryUsdt(5_000e6);
        _fund(tokenId, 5_000e6);

        // stray tokens land on the vault
        usdt.mint(address(vault), 777e6);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.RescueExceedsFloat.selector, 777e6 + 1, 777e6));
        vault.rescueToken(IERC20(address(usdt)), admin, 777e6 + 1);

        vm.prank(admin);
        vault.rescueToken(IERC20(address(usdt)), admin, 777e6);
        assertEq(usdt.balanceOf(admin), 777e6, "stray recovered");

        // the earmarked payout is untouched
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        vault.claim(tokenId);
        assertEq(usdt.balanceOf(alice), 5_000e6);
    }

    function test_claimableAtOf_noRequest() public {
        uint256 tokenId = _depositUsdt(alice, USDT_1K, T_USDT_30);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.NoActiveRequest.selector, tokenId));
        vault.claimableAtOf(tokenId);
    }
}
