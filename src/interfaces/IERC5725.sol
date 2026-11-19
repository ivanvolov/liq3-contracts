// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title ERC-5725 Transferable Vesting NFT interface
/// @notice Claim interface for an NFT that pays out an ERC-20 on a schedule.
/// @dev Verified against the published EIP-5725 text (eips.ethereum.org/EIPS/eip-5725,
///      2026-11-19): signatures match and type(IERC5725).interfaceId == 0xbd3a202b,
///      asserted in the test suite.
interface IERC5725 is IERC721 {
    /// @notice Emitted when a payout is claimed from a token.
    event PayoutClaimed(uint256 indexed tokenId, address indexed recipient, uint256 claimAmount);

    /// @notice Emitted when claim rights over one token are granted or revoked.
    event ClaimApproval(address indexed owner, address indexed operator, uint256 indexed tokenId, bool approved);

    /// @notice Emitted when claim rights over all of an owner's tokens are granted or revoked.
    event ClaimApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /// @notice Claim whatever is claimable on `tokenId`; payout goes to the current owner.
    function claim(uint256 tokenId) external;

    /// @notice Total amount already claimed on `tokenId`.
    function claimedPayout(uint256 tokenId) external view returns (uint256 payout);

    /// @notice Amount claimable right now on `tokenId`.
    function claimablePayout(uint256 tokenId) external view returns (uint256 payout);

    /// @notice Amount vested as of the current block timestamp.
    function vestedPayout(uint256 tokenId) external view returns (uint256 payout);

    /// @notice Amount vested as of `timestamp`.
    function vestedPayoutAtTime(uint256 tokenId, uint256 timestamp) external view returns (uint256 payout);

    /// @notice Amount still vesting (not yet vested) on `tokenId`.
    function vestingPayout(uint256 tokenId) external view returns (uint256 payout);

    /// @notice The vesting window of `tokenId`.
    function vestingPeriod(uint256 tokenId) external view returns (uint256 vestingStart, uint256 vestingEnd);

    /// @notice The ERC-20 asset `tokenId` pays out.
    function payoutToken(uint256 tokenId) external view returns (address token);

    /// @notice Grant or revoke claim rights over all caller's tokens.
    function setClaimApprovalForAll(address operator, bool approved) external;

    /// @notice Grant or revoke claim rights over one token the caller owns.
    function setClaimApproval(address operator, bool approved, uint256 tokenId) external;

    /// @notice Whether `operator` may claim on all of `owner`'s tokens.
    function isClaimApprovedForAll(address owner, address operator) external view returns (bool);

    /// @notice The single operator approved to claim on `tokenId` (zero if none).
    function getClaimApproved(uint256 tokenId) external view returns (address operator);
}
