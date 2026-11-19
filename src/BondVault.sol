// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ** external imports
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

// ** contracts
import {BondVaultParams} from "./base/BondVaultParams.sol";

// ** libraries
import {TermMath} from "./libraries/TermMath.sol";

// ** interfaces
import {IBondVault} from "./interfaces/IBondVault.sol";
import {IERC5725} from "./interfaces/IERC5725.sol";

/// @title Bond Vault
/// @author Ivan Volovyk <https://github.com/ivanvolov>
/// @notice On-chain copy of the exchange term product, one series per asset. ERC-721
///         positions with the ERC-5725 claim interface; Lido-style three-step exit
///         queue keyed by tokenId.
contract BondVault is ERC721Upgradeable, ReentrancyGuardUpgradeable, BondVaultParams, IERC5725 {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 internal _nextTokenId;
    mapping(uint256 tokenId => Position) internal _positions;
    mapping(uint256 tokenId => WithdrawRequest) internal _requests;
    mapping(uint256 tokenId => AutoRoll) internal _autoRolls;
    /// @notice Funded-but-unclaimed float. The only money this contract holds.
    uint256 public totalClaimableObligations;

    // ** ERC-5725 claim approvals
    mapping(uint256 tokenId => address operator) internal _claimApproved;
    mapping(address owner => mapping(address operator => bool)) internal _claimApprovedForAll;

    uint256[20] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name,
        string memory symbol,
        address _owner,
        IERC20 _asset,
        address _treasury,
        address _custody
    ) external initializer {
        __ERC721_init(name, symbol);
        __ReentrancyGuard_init();
        __BondVaultParams_init(_owner, _asset, _treasury, _custody);
        _nextTokenId = 1;
    }

    // ** Deposit

    function deposit(uint256 amount, uint32 duration) external nonReentrant whenNotPaused returns (uint256 tokenId) {
        uint16 aprBps = terms[duration];
        if (aprBps == 0) revert TermNotEnabled(duration);
        if (amount == 0 || amount < minDeposit) revert BelowMinDeposit(amount, minDeposit);

        tokenId = _nextTokenId++;
        _positions[tokenId] = Position({
            startTime: uint40(block.timestamp), duration: duration, aprBps: aprBps, principal: amount.toUint128()
        });
        _mint(msg.sender, tokenId);
        emit Deposited(tokenId, msg.sender, amount, aprBps, duration);

        // Straight to the exchange wallet; the delta check rejects fee-on-transfer assets.
        uint256 custodyBefore = asset.balanceOf(custody);
        asset.safeTransferFrom(msg.sender, custody, amount);
        if (asset.balanceOf(custody) - custodyBefore < amount) revert AssetFeeOnTransfer();
    }

    // ** Exit queue

    /// @dev Owner-only: an exit request is irreversible and (if early) burns all
    ///      interest, so a marketplace transfer-approval must not be able to file it.
    function requestWithdraw(uint256 tokenId) external onlyTokenOwner(tokenId) noActiveRequest(tokenId) {
        Position memory p = _positions[tokenId];
        bool early = block.timestamp < uint256(p.startTime) + p.duration;

        _requests[tokenId] = WithdrawRequest({
            payout: 0, requestedAt: uint40(block.timestamp), early: early, state: RequestState.Pending
        });
        _clearAutoRoll(tokenId);
        emit WithdrawRequested(tokenId, msg.sender, early, _basePayout(p, early));
    }

    /// @dev Pulls the cash off the treasury Safe's allowance in the same transaction —
    ///      approval without the money landing is impossible (Lido-finalize style).
    function fundAndApproveClaim(uint256 tokenId, uint256 payout) external nonReentrant onlyRole(OPERATOR_ROLE) {
        WithdrawRequest storage r = _requests[tokenId];
        if (r.state != RequestState.Pending) revert RequestNotPending(tokenId);

        uint256 base = _basePayout(_positions[tokenId], r.early);
        if (r.early) {
            if (payout != base) revert EarlyPayoutNotExact(tokenId, payout, base);
        } else {
            if (payout < base) revert PayoutBelowBase(tokenId, payout, base);
            uint256 cap = base + (base * maxBonusBps) / TermMath.BPS;
            if (payout > cap) revert PayoutAboveCap(tokenId, payout, cap);
        }

        r.payout = payout.toUint128();
        r.state = RequestState.Claimable;
        totalClaimableObligations += payout;
        asset.safeTransferFrom(treasury, address(this), payout);
        emit ClaimFunded(tokenId, payout);
    }

    /// @notice The queue's final `withdraw` step and ERC-5725's `claim` are the same call.
    function claim(uint256 tokenId) external nonReentrant {
        WithdrawRequest storage r = _requests[tokenId];
        if (r.state != RequestState.Claimable) revert RequestNotClaimable(tokenId);
        uint256 unlockAt = _claimableAt(r);
        if (block.timestamp < unlockAt) revert RequestTimelocked(tokenId, unlockAt);

        address owner = ownerOf(tokenId);
        if (!(_isAuthorized(owner, msg.sender, tokenId) || _isClaimAuthorized(msg.sender, owner, tokenId))) {
            revert NotTokenOwnerOrApproved(tokenId, msg.sender);
        }

        uint256 payout = r.payout;
        r.state = RequestState.Claimed; // the row survives: claimedPayout reads it after the burn
        totalClaimableObligations -= payout;
        delete _positions[tokenId];
        _burn(tokenId);

        // The NFT stayed transferable through the queue: pay whoever owns it now.
        asset.safeTransfer(owner, payout);
        emit Withdrawn(tokenId, owner, payout);
        emit PayoutClaimed(tokenId, owner, payout);
    }

    // ** Rolling

    /// @dev Owner-only (re-locks principal). A manual roll drops any standing autoroll.
    function roll(uint256 tokenId, uint32 newDuration)
        external
        whenNotPaused
        onlyTokenOwner(tokenId)
        noActiveRequest(tokenId)
        returns (uint256)
    {
        return _roll(tokenId, newDuration, false);
    }

    function setAutoRoll(uint256 tokenId, uint32 duration, uint16 minAprBps)
        external
        onlyTokenOwner(tokenId)
        noActiveRequest(tokenId)
    {
        if (terms[duration] == 0) revert TermNotEnabled(duration);
        _autoRolls[tokenId] = AutoRoll({duration: duration, minAprBps: minAprBps});
        emit AutoRollSet(tokenId, duration, minAprBps);
    }

    function clearAutoRoll(uint256 tokenId) external onlyTokenOwner(tokenId) {
        _clearAutoRoll(tokenId);
    }

    function executeAutoRoll(uint256 tokenId)
        external
        whenNotPaused
        onlyRole(OPERATOR_ROLE)
        noActiveRequest(tokenId)
        returns (uint256 newTokenId)
    {
        AutoRoll memory ar = _autoRolls[tokenId];
        if (ar.duration == 0) revert AutoRollNotSet(tokenId);
        // The user picked a term, not a rate: the floor must still hold.
        uint16 aprBps = terms[ar.duration];
        if (aprBps < ar.minAprBps) revert AutoRollBelowMinApr(tokenId, aprBps, ar.minAprBps);

        newTokenId = _roll(tokenId, ar.duration, true);
        // A standing instruction carries onto the new bond until cleared.
        _autoRolls[newTokenId] = ar;
        emit AutoRollSet(newTokenId, ar.duration, ar.minAprBps);
    }

    function _roll(uint256 tokenId, uint32 newDuration, bool auto_) internal returns (uint256 newTokenId) {
        Position memory p = _positions[tokenId];
        if (block.timestamp < uint256(p.startTime) + p.duration) revert PositionNotMatured(tokenId);
        uint16 aprBps = terms[newDuration];
        if (aprBps == 0) revert TermNotEnabled(newDuration);

        // The money never leaves the exchange account: earned interest compounds in.
        uint256 newPrincipal = uint256(p.principal) + TermMath.interest(p.principal, p.aprBps, p.duration);
        address owner = ownerOf(tokenId);

        delete _positions[tokenId];
        _burn(tokenId);

        newTokenId = _nextTokenId++;
        _positions[newTokenId] = Position({
            startTime: uint40(block.timestamp),
            duration: newDuration,
            aprBps: aprBps,
            principal: newPrincipal.toUint128()
        });
        _mint(owner, newTokenId);
        emit Rolled(tokenId, newTokenId, newPrincipal, aprBps, newDuration, auto_);
    }

    // ** Views

    function getPosition(uint256 tokenId) external view returns (Position memory) {
        return _positions[tokenId];
    }

    function getRequest(uint256 tokenId) external view returns (WithdrawRequest memory) {
        return _requests[tokenId];
    }

    function getAutoRoll(uint256 tokenId) external view returns (AutoRoll memory) {
        return _autoRolls[tokenId];
    }

    function claimableAtOf(uint256 tokenId) external view returns (uint256) {
        WithdrawRequest memory r = _requests[tokenId];
        if (r.state == RequestState.None) revert NoActiveRequest(tokenId);
        return _claimableAt(r);
    }

    // ** ERC-5725

    function claimedPayout(uint256 tokenId) external view returns (uint256) {
        WithdrawRequest memory r = _requests[tokenId];
        return r.state == RequestState.Claimed ? r.payout : 0;
    }

    function claimablePayout(uint256 tokenId) external view returns (uint256) {
        WithdrawRequest memory r = _requests[tokenId];
        if (r.state != RequestState.Claimable || block.timestamp < _claimableAt(r)) return 0;
        return r.payout;
    }

    /// @dev Informational curve; actual payouts are all-or-nothing per the product rules.
    function vestedPayout(uint256 tokenId) external view returns (uint256) {
        return vestedPayoutAtTime(tokenId, block.timestamp);
    }

    function vestedPayoutAtTime(uint256 tokenId, uint256 timestamp) public view returns (uint256) {
        Position memory p = _positions[tokenId];
        return uint256(p.principal) + TermMath.accruedAt(p.principal, p.aprBps, p.startTime, p.duration, timestamp);
    }

    function vestingPayout(uint256 tokenId) external view returns (uint256) {
        Position memory p = _positions[tokenId];
        return _basePayout(p, false) - vestedPayoutAtTime(tokenId, block.timestamp);
    }

    function vestingPeriod(uint256 tokenId) external view returns (uint256 vestingStart, uint256 vestingEnd) {
        Position memory p = _positions[tokenId];
        return (p.startTime, uint256(p.startTime) + p.duration);
    }

    function payoutToken(uint256) external view returns (address) {
        return address(asset);
    }

    function setClaimApprovalForAll(address operator, bool approved) external {
        _claimApprovedForAll[msg.sender][operator] = approved;
        emit ClaimApprovalForAll(msg.sender, operator, approved);
    }

    function setClaimApproval(address operator, bool approved, uint256 tokenId) external onlyTokenOwner(tokenId) {
        _claimApproved[tokenId] = approved ? operator : address(0);
        emit ClaimApproval(msg.sender, operator, tokenId, approved);
    }

    function isClaimApprovedForAll(address owner, address operator) external view returns (bool) {
        return _claimApprovedForAll[owner][operator];
    }

    function getClaimApproved(uint256 tokenId) external view returns (address) {
        return _claimApproved[tokenId];
    }

    // ** Rescue

    /// @dev Capped by the funded-claim float: earmarked user payouts are untouchable.
    function rescueToken(IERC20 token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        uint256 reserved = token == asset ? totalClaimableObligations : 0;
        uint256 available = token.balanceOf(address(this)) - reserved;
        if (amount > available) revert RescueExceedsFloat(amount, available);
        token.safeTransfer(to, amount);
    }

    // ** Modifiers

    modifier onlyTokenOwner(uint256 tokenId) {
        if (_requireOwned(tokenId) != msg.sender) revert NotTokenOwnerOrApproved(tokenId, msg.sender);
        _;
    }

    modifier noActiveRequest(uint256 tokenId) {
        if (_requests[tokenId].state != RequestState.None) revert RequestAlreadyExists(tokenId);
        _;
    }

    // ** Helpers

    function _basePayout(Position memory p, bool early) internal pure returns (uint256) {
        if (early) return p.principal;
        return uint256(p.principal) + TermMath.interest(p.principal, p.aprBps, p.duration);
    }

    function _claimableAt(WithdrawRequest memory r) internal view returns (uint256) {
        return uint256(r.requestedAt) + (r.early ? earlyWithdrawWindow : maturityWithdrawWindow);
    }

    /// @dev ERC-5725 deviation, intentional: claim pays the current owner, never msg.sender.
    function _isClaimAuthorized(address caller, address owner, uint256 tokenId) internal view returns (bool) {
        return _claimApproved[tokenId] == caller || _claimApprovedForAll[owner][caller];
    }

    function _clearAutoRoll(uint256 tokenId) internal {
        if (_autoRolls[tokenId].duration != 0) {
            delete _autoRolls[tokenId];
            emit AutoRollCleared(tokenId);
        }
    }

    /// @dev Standing permissions are personal to the owner who set them — they never
    ///      follow the token; both clears are evented for the offchain bot.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (from != address(0)) {
            _clearAutoRoll(tokenId);
            address approved = _claimApproved[tokenId];
            if (approved != address(0)) {
                delete _claimApproved[tokenId];
                emit ClaimApproval(from, approved, tokenId, false);
            }
        }
    }

    /// @dev ERC-5725 declared (id 0xbd3a202b); ERC-7540/7092 are naming only, absent on purpose.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, AccessControlUpgradeable, IERC165)
        returns (bool)
    {
        return interfaceId == type(IERC5725).interfaceId || super.supportsInterface(interfaceId);
    }
}
