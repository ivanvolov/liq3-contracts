// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondVault} from "@src/BondVault.sol";

/// @notice Deploys ONE series (one vault for one asset). Run once per asset — the
///         USDT series, the WBTC series, and a token staking series (a lock-shaped
///         grid: one ~infinite term at the 1-bps marker APR, both windows 2 days) are
///         all this same contract. A 2-day TimelockController fronts the multisig for
///         admin-level actions; the multisig holds MANAGER directly; the bot holds
///         OPERATOR. The treasury is the Safe itself — after deployment it grants the
///         vault an ERC-20 allowance for the series asset (that allowance IS the
///         funding pipe). The deployer wires everything and hands over, keeping
///         nothing.
///
/// Env:
///   MULTISIG      — the owner multisig (Safe); also the treasury cash holder
///   OPERATOR_BOT  — the ops bot hot key
///   PAUSER        — emergency guardian (can be the bot or a separate key)
///   ASSET         — the series asset (USDT, WBTC, ...)
///   CUSTODY       — the exchange deposit wallet for this asset
///   NAME, SYMBOL  — the series NFT name/symbol
///   TIMELOCK_MIN_DELAY — seconds, default 2 days if unset
contract Deploy is Script {
    struct Ctx {
        address multisig;
        address operatorBot;
        address pauser;
        address asset;
        address custody;
        string name;
        string symbol;
        uint256 minDelay;
        address deployer;
    }

    TimelockController internal timelock;
    BondVault internal vault;

    function run() external {
        Ctx memory c = Ctx({
            multisig: vm.envAddress("MULTISIG"),
            operatorBot: vm.envAddress("OPERATOR_BOT"),
            pauser: vm.envAddress("PAUSER"),
            asset: vm.envAddress("ASSET"),
            custody: vm.envAddress("CUSTODY"),
            name: vm.envOr("NAME", string("Term Position")),
            symbol: vm.envOr("SYMBOL", string("TERM")),
            minDelay: vm.envOr("TIMELOCK_MIN_DELAY", uint256(2 days)),
            deployer: address(0)
        });

        vm.startBroadcast();
        c.deployer = msg.sender;

        // the timelock: multisig proposes and executes, nobody else
        address[] memory proposers = new address[](1);
        proposers[0] = c.multisig;
        timelock = new TimelockController(c.minDelay, proposers, proposers, address(0));

        vault = BondVault(
            address(
                new ERC1967Proxy(
                    address(new BondVault()),
                    abi.encodeCall(
                        BondVault.initialize, (c.name, c.symbol, c.deployer, IERC20(c.asset), c.multisig, c.custody)
                    )
                )
            )
        );

        // OPERATOR/PAUSER are MANAGER-administered, so the deployer briefly takes
        // MANAGER to hand them out, then renounces it. Min deposit and the terms grid
        // are set by the multisig afterwards — operational data, not code.
        vault.grantRole(vault.MANAGER_ROLE(), c.multisig);
        vault.grantRole(vault.MANAGER_ROLE(), c.deployer);
        vault.grantRole(vault.OPERATOR_ROLE(), c.operatorBot);
        vault.grantRole(vault.PAUSER_ROLE(), c.pauser);
        vault.renounceRole(vault.MANAGER_ROLE(), c.deployer);

        // hand admin to the timelock, renounce the deployer
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vault.grantRole(adminRole, address(timelock));
        vault.renounceRole(adminRole, c.deployer);
        vm.stopBroadcast();

        _assertWiring(c);

        console.log("timelock: %s", address(timelock));
        console.log("vault:    %s", address(vault));
        console.log("NOTE: the Safe must now approve the vault to spend the series asset (the funding pipe).");
    }

    /// @dev Post-deploy assertions: fail the run if the handover is wrong.
    function _assertWiring(Ctx memory c) internal view {
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        require(vault.hasRole(adminRole, address(timelock)) && !vault.hasRole(adminRole, c.deployer), "admin");
        require(vault.hasRole(vault.MANAGER_ROLE(), c.multisig), "manager");
        require(vault.hasRole(vault.OPERATOR_ROLE(), c.operatorBot), "operator");
        require(!vault.hasRole(vault.MANAGER_ROLE(), c.deployer), "deployer manager");
        require(vault.treasury() == c.multisig && vault.custody() == c.custody, "addresses");
    }
}
