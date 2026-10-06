// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SeatbeltVault} from "../src/SeatbeltVault.sol";

contract SeatbeltVaultTest is Test {
    SeatbeltVault vault;
    address agent;
    address payable merchant;

    uint256 constant BUDGET = 3 ether;
    uint256 constant CAP = 2 ether;
    uint256 constant WINDOW = 1 hours;
    uint256 constant MAX_DENIALS = 3;

    // lets this test contract (the owner) receive withdrawals
    receive() external payable {}

    function setUp() public {
        agent = makeAddr("agent");
        merchant = payable(makeAddr("merchant"));
        vault = new SeatbeltVault{value: 10 ether}(agent, BUDGET, CAP, WINDOW, MAX_DENIALS);
        vault.setAllowed(merchant, true);
    }

    function test_SpendWithinBudget() public {
        vm.prank(agent);
        bool ok = vault.spend(merchant, 1 ether);
        assertTrue(ok);
        assertEq(merchant.balance, 1 ether);
        assertEq(vault.spentInWindow(), 1 ether);
    }

    function test_DeniedWhenNotAllowlisted() public {
        address stranger = makeAddr("stranger");
        vm.prank(agent);
        bool ok = vault.spend(payable(stranger), 1 ether);
        assertFalse(ok);
        assertEq(stranger.balance, 0);
        assertEq(vault.deniedCount(), 1);
    }

    function test_DeniedOverPerTxCap() public {
        vm.prank(agent);
        bool ok = vault.spend(merchant, 2.5 ether);
        assertFalse(ok);
        assertEq(merchant.balance, 0);
    }

    function test_DeniedOverWindowBudget() public {
        vm.startPrank(agent);
        assertTrue(vault.spend(merchant, 2 ether));
        assertFalse(vault.spend(merchant, 2 ether)); // 4 > 3 budget
        vm.stopPrank();
        assertEq(merchant.balance, 2 ether);
    }

    function test_WindowResets() public {
        vm.startPrank(agent);
        assertTrue(vault.spend(merchant, 2 ether));
        assertFalse(vault.spend(merchant, 2 ether));
        vm.warp(block.timestamp + WINDOW + 1);
        assertTrue(vault.spend(merchant, 2 ether)); // new window
        vm.stopPrank();
        assertEq(merchant.balance, 4 ether);
    }

    function test_AutoFreezesAfterKDenials() public {
        address stranger = makeAddr("stranger");
        vm.startPrank(agent);
        for (uint256 i = 0; i < MAX_DENIALS; i++) {
            assertFalse(vault.spend(payable(stranger), 1 ether));
        }
        assertTrue(vault.frozen());

        vm.expectRevert(SeatbeltVault.IsFrozen.selector);
        vault.spend(merchant, 1 ether); // even a legal spend is blocked now
        vm.stopPrank();
    }

    function test_OnlyAgentCanSpend() public {
        vm.expectRevert(SeatbeltVault.NotAgent.selector);
        vault.spend(merchant, 1 ether); // called by owner, not agent
    }

    function test_OnlyOwnerCanAdminister() public {
        vm.startPrank(agent);
        vm.expectRevert(SeatbeltVault.NotOwner.selector);
        vault.setAllowed(agent, true);
        vm.expectRevert(SeatbeltVault.NotOwner.selector);
        vault.freeze();
        vm.expectRevert(SeatbeltVault.NotOwner.selector);
        vault.withdraw(1 ether);
        vm.stopPrank();
    }

    function test_OwnerCanFreezeAndUnfreeze() public {
        vault.freeze();
        vm.prank(agent);
        vm.expectRevert(SeatbeltVault.IsFrozen.selector);
        vault.spend(merchant, 1 ether);

        vault.unfreeze();
        vm.prank(agent);
        assertTrue(vault.spend(merchant, 1 ether));
    }

    function test_OwnerCanWithdraw() public {
        uint256 before = address(this).balance;
        vault.withdraw(4 ether);
        assertEq(address(this).balance, before + 4 ether);
        assertEq(address(vault).balance, 6 ether);
    }
}