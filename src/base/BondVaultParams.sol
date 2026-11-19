// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ** external imports
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ** interfaces
import {IBondVault} from "../interfaces/IBondVault.sol";

/// @title BondVaultParams
/// @notice Params, storage and setters for one bond series. BondVault inherits this
///         and implements only the flows.
/// @dev Proxied (UUPS), so the OZ *Upgradeable bases and an initializer stand in
///      for constructors. Roles: DEFAULT_ADMIN = timelocked multisig
///      (upgrades, money addresses), MANAGER = multisig (grid and knobs, hot-key
///      admin), OPERATOR = bot, PAUSER = guardian.
abstract contract BondVaultParams is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    IBondVault
{
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @dev Window changes are retroactive for the whole queue, so both knobs are hard-capped.
    uint256 public constant MAX_WITHDRAW_WINDOW = 30 days;
    uint256 public constant MAX_BONUS_BPS = 10_000;

    IERC20 public asset;
    /// @notice The Safe holding operating cash; claims are funded off its standing allowance.
    address public treasury;
    /// @notice The exchange deposit wallet deposits are forwarded to.
    address public custody;
    uint128 public minDeposit;
    /// @notice The terms grid: duration is the term's identity, APR its only content.
    ///         0 APR = no such term. Full terms are copied into the position at mint,
    ///         so rewriting the grid only affects future positions.
    mapping(uint32 duration => uint16 aprBps) public terms;

    /// @notice Exit timelock and funding SLA; read at withdraw time, so a change
    ///         moves in-flight requests too (queue extension is a product rule).
    uint256 public earlyWithdrawWindow;
    uint256 public maturityWithdrawWindow;
    /// @notice Operator overfunding cap: payout <= base * (BPS + maxBonusBps) / BPS.
    uint256 public maxBonusBps;

    uint256[20] private __gap;

    function __BondVaultParams_init(address _owner, IERC20 _asset, address _treasury, address _custody)
        internal
        onlyInitializing
    {
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        if (_owner == address(0) || address(_asset) == address(0) || _treasury == address(0) || _custody == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        // Hot keys are managed by the multisig directly, not through the admin timelock.
        _setRoleAdmin(OPERATOR_ROLE, MANAGER_ROLE);
        _setRoleAdmin(PAUSER_ROLE, MANAGER_ROLE);

        asset = _asset;
        treasury = _treasury;
        custody = _custody;
        earlyWithdrawWindow = 7 days;
        maturityWithdrawWindow = 2 days;
        maxBonusBps = 5_000;
        emit TreasurySet(_treasury);
        emit CustodySet(_custody);
        emit WithdrawWindowSet(true, 7 days);
        emit WithdrawWindowSet(false, 2 days);
        emit MaxBonusBpsSet(5_000);
    }

    // ** Setters: admin (timelocked multisig)

    function setTreasury(address _treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    function setCustody(address _custody) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_custody == address(0)) revert ZeroAddress();
        custody = _custody;
        emit CustodySet(_custody);
    }

    // ** Setters: manager (multisig)

    function setMinDeposit(uint128 _minDeposit) external onlyRole(MANAGER_ROLE) {
        minDeposit = _minDeposit;
        emit MinDepositSet(_minDeposit);
    }

    /// @dev One setter runs the whole grid: set the APR, change it, or zero it to
    ///      drop the term. Safe for open positions — terms are copied at mint.
    function setTerm(uint32 _duration, uint16 _aprBps) external onlyRole(MANAGER_ROLE) {
        if (_duration == 0) revert ZeroDuration();
        terms[_duration] = _aprBps;
        emit TermSet(_duration, _aprBps);
    }

    function setWithdrawWindowParam(bool _early, uint256 _window) external onlyRole(MANAGER_ROLE) {
        if (_window == 0) revert ZeroWindow();
        if (_window > MAX_WITHDRAW_WINDOW) revert WindowTooLong(_window, MAX_WITHDRAW_WINDOW);
        if (_early) earlyWithdrawWindow = _window;
        else maturityWithdrawWindow = _window;
        emit WithdrawWindowSet(_early, _window);
    }

    function setMaxBonusBps(uint256 _maxBonusBps) external onlyRole(MANAGER_ROLE) {
        if (_maxBonusBps > MAX_BONUS_BPS) revert BonusCapTooHigh(_maxBonusBps, MAX_BONUS_BPS);
        maxBonusBps = _maxBonusBps;
        emit MaxBonusBpsSet(_maxBonusBps);
    }

    function unpause() external onlyRole(MANAGER_ROLE) {
        _unpause();
    }

    // ** Pauser

    /// @dev Pause stops money-in only (deposit, roll); the exit pipeline is never pausable.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
