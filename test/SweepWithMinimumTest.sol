// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";

import {RelayRouter} from "../src/RelayRouter.sol";
import {RelayRouterBase} from "../src/RelayRouterBase.sol";
import {RouteRaceEngine} from "../src/RouteRaceEngine.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

/// @dev A target that pulls a chosen amount of what the router approved it for
contract SweepPullingTarget {
    function pull(address token, uint256 amount) external {
        TestERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}

/// @notice `sweepWithMinimum` with data, when the target pulls only part of the router's balance: after the call the
///         router resets the target's allowance and measures what left it against `minAmount`
contract SweepWithMinimumTest is Test {
    RelayRouter router;
    TestERC20 token;
    SweepPullingTarget target;

    function setUp() public {
        router = new RelayRouter();
        token = new TestERC20();
        target = new SweepPullingTarget();
        token.mint(address(router), 100);
    }

    function test_aPullAtTheMinimumKeepsTheRestOnTheRouterAndLeavesNoAllowance() public {
        _assertPartialPull(60, 60);
    }

    function test_aPullAboveTheMinimumKeepsTheRestOnTheRouterAndLeavesNoAllowance() public {
        _assertPartialPull(99, 60);
    }

    /// @notice The target pulls 59 of 100 for a minimum of 60: the sweep reverts with InsufficientOutput(59, 60), so
    ///         the pull and the approval roll back
    function test_aPullBelowTheMinimumRevertsWithInsufficientOutputAndMovesNothing() public {
        vm.expectRevert(abi.encodeWithSelector(RouteRaceEngine.InsufficientOutput.selector, 59, 60));
        _sweep(59, 60);
        assertEq(token.balanceOf(address(router)), 100, "the router keeps its balance");
        assertEq(token.balanceOf(address(target)), 0, "the target has nothing");
        assertEq(token.allowance(address(router), address(target)), 0, "no allowance");
    }

    /// @dev The router holds 100, the target pulls `pulled` for a minimum of `minAmount`: the sweep succeeds and
    ///      reports what the target pulled, the rest stays on the router, and the target's allowance is 0
    function _assertPartialPull(uint256 pulled, uint256 minAmount) internal {
        vm.expectEmit(address(router));
        emit RelayRouterBase.FundsMovement(address(router), address(target), address(token), pulled, "");
        _sweep(pulled, minAmount);
        assertEq(token.balanceOf(address(target)), pulled, "the target got what it pulled");
        assertEq(token.balanceOf(address(router)), 100 - pulled, "the rest stays on the router");
        assertEq(token.allowance(address(router), address(target)), 0, "no allowance is left");
    }

    function _sweep(uint256 pulled, uint256 minAmount) internal {
        router.sweepWithMinimum(
            address(token),
            minAmount,
            address(target),
            abi.encodeCall(SweepPullingTarget.pull, (address(token), pulled))
        );
    }
}
