// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title TermMath
/// @notice The product's entire interest arithmetic: simple pro-rata interest,
///         ACT/365, in native asset units (decimal-agnostic).
library TermMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant DAY_BASIS = 365 days;

    /// @notice Full-term base interest: principal * aprBps * duration / (365d * 10000).
    function interest(uint256 principal, uint256 aprBps, uint256 duration) internal pure returns (uint256) {
        return (principal * aprBps * duration) / (BPS * DAY_BASIS);
    }

    /// @notice Interest accrued between start and `at`, capped at maturity. Zero
    ///         before start. Informational only (ERC-5725 vesting views) — payouts are
    ///         all-or-nothing per the product rules.
    function accruedAt(uint256 principal, uint256 aprBps, uint256 start, uint256 duration, uint256 at)
        internal
        pure
        returns (uint256)
    {
        if (at <= start) return 0;
        uint256 elapsed = at - start;
        if (elapsed > duration) elapsed = duration;
        return interest(principal, aprBps, elapsed);
    }
}
