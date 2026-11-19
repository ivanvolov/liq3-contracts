// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondVault} from "@src/BondVault.sol";
import {IBondVault} from "@src/interfaces/IBondVault.sol";
import {TermMath} from "@src/libraries/TermMath.sol";

import {MockERC20} from "@test/mocks/MockERC20.sol";
import {MockUSDT} from "@test/mocks/MockUSDT.sol";

/// @notice Shared fixture. One vault per asset: the USDT series (primary, with the
///         full rate grid) plus a WBTC series to prove the
///         one-contract-per-asset shape. WBT staking is just one more series — see
///         Staking.t.sol. The treasury is just the Safe
///         multisig's address — it holds the cash and grants each vault a standing
///         allowance, exactly as production would. Roles are split across distinct
///         addresses (admin = timelocked multisig, manager = multisig, operator =
///         bot hot key, pauser = guardian).
abstract contract TestBase is Test {
    // ** actors
    address public admin = makeAddr("admin");
    address public manager = makeAddr("manager");
    address public operator = makeAddr("operator");
    address public pauser = makeAddr("pauser");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public custodyUsdt = makeAddr("custodyUsdt");
    address public custodyWbtc = makeAddr("custodyWbtc");
    /// @dev The Safe multisig address. Not a contract of this system.
    address public treasury = makeAddr("treasurySafe");

    // ** assets
    MockUSDT public usdt; // 6 decimals, USDT semantics
    MockERC20 public wbtc; // 8 decimals

    // ** system
    BondVault public vault; // the USDT series (primary)
    BondVault public vaultWbtc; // a second series, same code

    // ** the rate grid: the duration IS the term's identity
    uint32 public constant T_USDT_30 = 30 days; // @ 7.00%
    uint32 public constant T_USDT_90 = 90 days; // @ 8.00%
    uint32 public constant T_USDT_180 = 180 days; // @ 9.00%
    uint32 public constant T_USDT_360 = 360 days; // @ 11.00%
    uint32 public constant T_WBTC_90 = 90 days; // @ 3.00% on the WBTC vault

    uint256 internal constant USDT_1K = 1_000e6;

    function setUp() public virtual {
        // A realistic non-zero starting time so uint40 timestamps are exercised.
        vm.warp(1_790_000_000);

        usdt = new MockUSDT();
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);

        vault = _deployVault("Term USDT", "TERM-USDT", IERC20(address(usdt)), custodyUsdt);
        vaultWbtc = _deployVault("Term WBTC", "TERM-WBTC", IERC20(address(wbtc)), custodyWbtc);

        // roles: admin seats the manager; the manager seats the hot keys
        // (OPERATOR/PAUSER are MANAGER-administered so a leaked hot key can be
        // revoked without the admin timelock)
        vm.startPrank(admin);
        vault.grantRole(vault.MANAGER_ROLE(), manager);
        vaultWbtc.grantRole(vault.MANAGER_ROLE(), manager);
        vm.stopPrank();

        vm.startPrank(manager);
        vault.grantRole(vault.OPERATOR_ROLE(), operator);
        vault.grantRole(vault.PAUSER_ROLE(), pauser);
        vaultWbtc.grantRole(vault.OPERATOR_ROLE(), operator);
        vault.setMinDeposit(uint128(USDT_1K)); // $1,000 minimum
        vault.setTerm(T_USDT_30, 700);
        vault.setTerm(T_USDT_90, 800);
        vault.setTerm(T_USDT_180, 900);
        vault.setTerm(T_USDT_360, 1100);
        vaultWbtc.setTerm(T_WBTC_90, 300);
        vm.stopPrank();

        // the Safe's standing allowances, one per series
        vm.startPrank(treasury);
        usdt.approve(address(vault), 0);
        usdt.approve(address(vault), type(uint256).max);
        wbtc.approve(address(vaultWbtc), type(uint256).max);
        vm.stopPrank();
    }

    function _deployVault(string memory name, string memory symbol, IERC20 asset, address custody)
        internal
        returns (BondVault)
    {
        BondVault impl = new BondVault();
        return BondVault(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(BondVault.initialize, (name, symbol, admin, asset, treasury, custody))
                )
            )
        );
    }

    // ** helpers (USDT series unless named otherwise)

    function _depositUsdt(address user, uint256 amount, uint32 duration) internal returns (uint256 tokenId) {
        usdt.mint(user, amount);
        vm.startPrank(user);
        usdt.approve(address(vault), 0);
        usdt.approve(address(vault), amount);
        tokenId = vault.deposit(amount, duration);
        vm.stopPrank();
    }

    function _depositWbtc(address user, uint256 amount, uint32 duration) internal returns (uint256 tokenId) {
        wbtc.mint(user, amount);
        vm.startPrank(user);
        wbtc.approve(address(vaultWbtc), amount);
        tokenId = vaultWbtc.deposit(amount, duration);
        vm.stopPrank();
    }

    function _fundTreasuryUsdt(uint256 amount) internal {
        usdt.mint(treasury, amount);
    }

    function _requestWithdraw(address user, uint256 tokenId) internal {
        vm.prank(user);
        vault.requestWithdraw(tokenId);
    }

    function _fund(uint256 tokenId, uint256 payout) internal {
        vm.prank(operator);
        vault.fundAndApproveClaim(tokenId, payout);
    }

    /// @notice principal + full-term base interest, the contract's own math re-derived.
    function _basePayout(uint256 principal, uint256 aprBps, uint256 duration) internal pure returns (uint256) {
        return principal + (principal * aprBps * duration) / (10_000 * 365 days);
    }

    /// @notice The base plan the operator owes for tokenId's request (view replacement
    ///         for the removed onchain basePayoutOf).
    function _baseOf(uint256 tokenId) internal view returns (uint256) {
        IBondVault.Position memory p = vault.getPosition(tokenId);
        IBondVault.WithdrawRequest memory r = vault.getRequest(tokenId);
        if (r.state == IBondVault.RequestState.Claimable || r.state == IBondVault.RequestState.Claimed) {
            return r.payout;
        }
        return r.early ? p.principal : _basePayout(p.principal, p.aprBps, p.duration);
    }

    function _maturity(uint256 tokenId) internal view returns (uint256) {
        IBondVault.Position memory p = vault.getPosition(tokenId);
        return uint256(p.startTime) + p.duration;
    }
}
