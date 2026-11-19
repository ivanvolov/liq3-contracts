// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestBase} from "@test/core/TestBase.sol";
import {BondVault} from "@src/BondVault.sol";
import {IBondVault} from "@src/interfaces/IBondVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "@test/mocks/MockERC20.sol";

/// @notice Token staking needs no contract of its own: it is one more series of the
///         same BondVault, configured as a lock. One term with a practically-infinite
///         duration and a 1-bps marker APR (0 would mean "no term", and the APR is
///         unreachable anyway: every exit is "early" and pays exactly the principal),
///         both exit windows at 2 days. Reward accounting lives offchain.
contract StakingTest is TestBase {
    MockERC20 public stk; // 18 decimals, the staked token
    BondVault public staking; // the staking series
    address public custodyStk = makeAddr("custodyStk");

    uint32 internal constant LOCK = type(uint32).max; // ~136 years: never matures

    function setUp() public override {
        super.setUp();
        stk = new MockERC20("Stake Token", "STK", 18);
        staking = _deployVault("Staked STK", "STK-STAKE", IERC20(address(stk)), custodyStk);

        bytes32 managerRole = staking.MANAGER_ROLE();
        bytes32 operatorRole = staking.OPERATOR_ROLE();
        vm.prank(admin);
        staking.grantRole(managerRole, manager);
        vm.startPrank(manager);
        staking.grantRole(operatorRole, operator);
        staking.setTerm(LOCK, 1);
        staking.setWithdrawWindowParam(true, 2 days);
        staking.setWithdrawWindowParam(false, 2 days);
        vm.stopPrank();

        vm.prank(treasury);
        stk.approve(address(staking), type(uint256).max);
    }

    function _stake(address user, uint256 amount) internal returns (uint256 tokenId) {
        stk.mint(user, amount);
        vm.startPrank(user);
        stk.approve(address(staking), amount);
        tokenId = staking.deposit(amount, LOCK);
        vm.stopPrank();
    }

    function test_stake_isADeposit() public {
        uint256 tokenId = _stake(alice, 100e18);
        assertEq(staking.ownerOf(tokenId), alice);
        assertEq(stk.balanceOf(custodyStk), 100e18, "stake forwarded like any deposit");

        IBondVault.Position memory p = staking.getPosition(tokenId);
        assertEq(p.principal, 100e18);
        assertEq(p.duration, LOCK);
    }

    function test_unstake_threeStep_fullRefund() public {
        uint256 tokenId = _stake(alice, 100e18);

        vm.warp(block.timestamp + 500 days); // deep into the lock: still "early"
        vm.prank(alice);
        staking.requestWithdraw(tokenId);
        assertTrue(staking.getRequest(tokenId).early, "the lock never matures");
        assertEq(staking.claimableAtOf(tokenId), block.timestamp + 2 days, "the 2-day unstake window");

        // the 1-bps marker APR is unreachable: early exit must be funded at exactly
        // the principal — the full staked amount, nothing else
        stk.mint(treasury, 100e18);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IBondVault.EarlyPayoutNotExact.selector, tokenId, 100e18 + 1, 100e18));
        staking.fundAndApproveClaim(tokenId, 100e18 + 1);

        vm.prank(operator);
        staking.fundAndApproveClaim(tokenId, 100e18);
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        staking.claim(tokenId);
        assertEq(stk.balanceOf(alice), 100e18, "always the full staked amount");
    }

    function test_multipleStakes_perUser() public {
        // "no top-up: to reach a higher tier open a new position" — literally
        uint256 s1 = _stake(alice, 100e18);
        uint256 s2 = _stake(alice, 50e18);
        assertEq(staking.getPosition(s1).principal, 100e18);
        assertEq(staking.getPosition(s2).principal, 50e18);
    }

    function test_stakeNFT_transferable_paysCurrentOwner() public {
        uint256 tokenId = _stake(alice, 100e18);
        vm.prank(alice);
        staking.requestWithdraw(tokenId);
        vm.prank(alice);
        staking.transferFrom(alice, bob, tokenId);

        stk.mint(treasury, 100e18);
        vm.prank(operator);
        staking.fundAndApproveClaim(tokenId, 100e18);
        vm.warp(block.timestamp + 2 days);
        vm.prank(bob);
        staking.claim(tokenId);
        assertEq(stk.balanceOf(bob), 100e18);
    }

    function testFuzz_unstake_exactRefund(uint128 amount) public {
        amount = uint128(bound(amount, 1, 1e27));
        uint256 tokenId = _stake(alice, amount);

        vm.prank(alice);
        staking.requestWithdraw(tokenId);
        stk.mint(treasury, amount);
        vm.prank(operator);
        staking.fundAndApproveClaim(tokenId, amount);
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        staking.claim(tokenId);
        assertEq(stk.balanceOf(alice), amount, "full refund, to the wei");
    }
}
