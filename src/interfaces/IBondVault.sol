// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title BondVault interface — structs, errors, events, external API
/// @notice One vault per asset (a bond series): the USDT vault, the WBTC vault, …
///         are separate deployments of this same contract. The position is a plain
///         ERC-721 with the claim interface of ERC-5725; a staking series is the
///         same contract with a never-maturing term. Queue states are named after
///         ERC-7540 (Pending / Claimable / Claimed) — naming only, not declared in
///         supportsInterface.
interface IBondVault {
    // ** types

    /// @dev ERC-7540-style request lifecycle. None = no request exists.
    enum RequestState {
        None,
        Pending,
        Claimable,
        Claimed
    }

    /// @notice An individual position: amount x term x rate frozen at entry.
    struct Position {
        uint40 startTime;
        uint32 duration;
        uint16 aprBps;
        uint128 principal;
    }

    /// @notice The position's withdrawal request, keyed by its tokenId — a position
    ///         has at most one request ever, so no separate request id exists.
    /// @dev The claimable moment is NOT stored: it is `requestedAt + currentWindow`,
    ///      computed at read time (see claimableAtOf), so a window change moves the
    ///      whole queue retroactively — already-filed requests included. The window
    ///      param itself is hard-capped so this can never become an unbounded lock.
    struct WithdrawRequest {
        uint128 payout; // 0 while Pending; set at funding
        uint40 requestedAt;
        bool early; // true = before maturity (principal only)
        RequestState state;
    }

    /// @notice Standing permission for the operator to roll a matured position.
    ///         The duration is the term's identity (0 = not set); minAprBps is the
    ///         rate floor — the user picks a term, not a rate.
    struct AutoRoll {
        uint32 duration;
        uint16 minAprBps;
    }

    // ** errors

    error TermNotEnabled(uint32 duration);
    error BelowMinDeposit(uint256 amount, uint256 minDeposit);
    error NotTokenOwnerOrApproved(uint256 tokenId, address caller);
    error RequestAlreadyExists(uint256 tokenId);
    error NoActiveRequest(uint256 tokenId);
    error RequestNotPending(uint256 tokenId);
    error RequestNotClaimable(uint256 tokenId);
    error RequestTimelocked(uint256 tokenId, uint256 claimableAt);
    error PositionNotMatured(uint256 tokenId);
    error PayoutBelowBase(uint256 tokenId, uint256 payout, uint256 basePayout);
    error PayoutAboveCap(uint256 tokenId, uint256 payout, uint256 cap);
    error EarlyPayoutNotExact(uint256 tokenId, uint256 payout, uint256 principal);
    error AutoRollNotSet(uint256 tokenId);
    error AutoRollBelowMinApr(uint256 tokenId, uint256 termApr, uint256 minApr);
    error ZeroAddress();
    error ZeroWindow();
    error ZeroDuration();
    error WindowTooLong(uint256 window, uint256 maxWindow);
    error BonusCapTooHigh(uint256 bps, uint256 maxBps);
    error RescueExceedsFloat(uint256 amount, uint256 available);
    error AssetFeeOnTransfer();

    // ** param events

    event MinDepositSet(uint256 minDeposit);
    event CustodySet(address indexed custody);
    event TermSet(uint32 indexed duration, uint16 aprBps);
    event WithdrawWindowSet(bool indexed early, uint256 window);
    event MaxBonusBpsSet(uint256 maxBonusBps);
    event TreasurySet(address indexed treasury);

    // ** flow events

    event Deposited(uint256 indexed tokenId, address indexed owner, uint256 amount, uint16 aprBps, uint32 duration);
    event WithdrawRequested(uint256 indexed tokenId, address owner, bool early, uint256 basePayout);
    event ClaimFunded(uint256 indexed tokenId, uint256 payout);
    event Withdrawn(uint256 indexed tokenId, address indexed to, uint256 payout);
    event Rolled(
        uint256 indexed oldTokenId,
        uint256 indexed newTokenId,
        uint256 newPrincipal,
        uint16 aprBps,
        uint32 duration,
        bool auto_
    );
    event AutoRollSet(uint256 indexed tokenId, uint32 duration, uint16 minAprBps);
    event AutoRollCleared(uint256 indexed tokenId);

    // ** user flow

    /// @notice Deposit `amount` of the vault's asset for `duration`. Pulls the asset
    ///         from the caller, forwards it to the custody wallet, and mints a
    ///         position NFT with the term copied in.
    function deposit(uint256 amount, uint32 duration) external returns (uint256 tokenId);

    /// @notice Request exit. Before maturity: principal only, early window. At/after
    ///         maturity: principal + the APR written in the position (plus whatever
    ///         extra the operator funds), maturity window. Not cancellable.
    function requestWithdraw(uint256 tokenId) external;

    /// @notice Operator step: pulls `payout` from the treasury Safe (via its standing
    ///         ERC-20 allowance) in this same transaction and flips the request to
    ///         Claimable — it cannot be called without the cash being delivered.
    ///         Early requests must be funded at exactly the principal; matured ones at
    ///         >= base plan, <= base + bonus cap.
    function fundAndApproveClaim(uint256 tokenId, uint256 payout) external;

    /// @notice Roll a matured position into a new term: burns the old NFT, mints a new
    ///         one with principal = old principal + base interest, startTime = now.
    function roll(uint256 tokenId, uint32 newDuration) external returns (uint256 newTokenId);

    /// @notice Store standing permission for the operator to roll this position at
    ///         maturity into the `duration` term, provided it still yields >= `minAprBps`.
    function setAutoRoll(uint256 tokenId, uint32 duration, uint16 minAprBps) external;

    /// @notice Remove the standing autoroll permission.
    function clearAutoRoll(uint256 tokenId) external;

    /// @notice Operator executes a user's standing autoroll on a matured position.
    function executeAutoRoll(uint256 tokenId) external returns (uint256 newTokenId);

    // ** views

    function getPosition(uint256 tokenId) external view returns (Position memory);
    function getRequest(uint256 tokenId) external view returns (WithdrawRequest memory);
    /// @notice When the request becomes withdrawable: requestedAt + the CURRENT window
    ///         (retroactive by design — see WithdrawRequest).
    function claimableAtOf(uint256 tokenId) external view returns (uint256);
}
