// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract FreelanceEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotClient();
    error InvalidFreelancer();
    error InvalidAmount();
    error InvalidDeadline();
    error InvalidMilestoneIndex();
    error MilestoneNotPending();
    error MilestoneNotApproved();
    error MilestoneNotRefundable();
    error DeadlineNotPassed();
    error TransferFailed();

    enum MilestoneStatus {
        Pending,
        Approved,
        Released,
        Refunded
    }

    struct Milestone {
        uint256 amount;
        MilestoneStatus status;
        uint256 deadline;
    }

    event MilestoneApproved(uint256 indexed milestoneIndex);
    event MilestoneReleased(uint256 indexed milestoneIndex, uint256 amount);
    event MilestoneRefunded(uint256 indexed milestoneIndex, uint256 amount);

    address public immutable client;
    address public immutable freelancer;
    IERC20 public immutable usdcToken;
    uint256 public immutable totalFunded;

    Milestone[3] private milestones;

    modifier onlyClient() {
        if (msg.sender != client) revert NotClient();
        _;
    }

    constructor(
        address _freelancer,
        address _usdcToken,
        uint256[3] memory _amounts,
        uint256[3] memory _deadlines
    ) {
        if (_freelancer == address(0)) revert InvalidFreelancer();
        if (_usdcToken == address(0)) revert TransferFailed();

        client = msg.sender;
        freelancer = _freelancer;
        usdcToken = IERC20(_usdcToken);

        uint256 total = 0;
        for (uint256 i = 0; i < 3; i++) {
            uint256 amount = _amounts[i];
            uint256 deadline = _deadlines[i];

            if (amount == 0) revert InvalidAmount();
            if (deadline <= block.timestamp) revert InvalidDeadline();

            milestones[i] = Milestone({
                amount: amount,
                status: MilestoneStatus.Pending,
                deadline: deadline
            });

            total += amount;
        }

        totalFunded = total;

        uint256 balanceBefore = usdcToken.balanceOf(address(this));
        usdcToken.safeTransferFrom(msg.sender, address(this), total);
        uint256 balanceAfter = usdcToken.balanceOf(address(this));

        if (balanceAfter - balanceBefore != total) revert TransferFailed();
    }

    function approveMilestone(uint256 milestoneIndex) external onlyClient {
        _validateMilestoneIndex(milestoneIndex);

        Milestone storage milestone = milestones[milestoneIndex];
        if (milestone.status != MilestoneStatus.Pending) revert MilestoneNotPending();

        milestone.status = MilestoneStatus.Approved;
        emit MilestoneApproved(milestoneIndex);
    }

    function releaseMilestone(uint256 milestoneIndex) external onlyClient nonReentrant {
        _validateMilestoneIndex(milestoneIndex);

        Milestone storage milestone = milestones[milestoneIndex];
        if (milestone.status != MilestoneStatus.Approved) revert MilestoneNotApproved();

        uint256 amount = milestone.amount;
        milestone.status = MilestoneStatus.Released;

        uint256 balanceBefore = usdcToken.balanceOf(address(this));
        usdcToken.safeTransfer(freelancer, amount);
        uint256 balanceAfter = usdcToken.balanceOf(address(this));

        if (balanceBefore - balanceAfter != amount) revert TransferFailed();

        emit MilestoneReleased(milestoneIndex, amount);
    }

    function refundMilestone(uint256 milestoneIndex) external onlyClient nonReentrant {
        _validateMilestoneIndex(milestoneIndex);

        Milestone storage milestone = milestones[milestoneIndex];
        // Allow refund of both Pending and Approved milestones after deadline.
        // An Approved milestone whose release keeps failing (e.g. freelancer blocklisted)
        // would otherwise lock funds permanently, so we extend the recovery path here.
        if (
            milestone.status != MilestoneStatus.Pending &&
            milestone.status != MilestoneStatus.Approved
        ) revert MilestoneNotRefundable();
        if (block.timestamp <= milestone.deadline) revert DeadlineNotPassed();

        uint256 amount = milestone.amount;
        milestone.status = MilestoneStatus.Refunded;

        uint256 balanceBefore = usdcToken.balanceOf(address(this));
        usdcToken.safeTransfer(client, amount);
        uint256 balanceAfter = usdcToken.balanceOf(address(this));

        if (balanceBefore - balanceAfter != amount) revert TransferFailed();

        emit MilestoneRefunded(milestoneIndex, amount);
    }

    function getMilestone(uint256 index) external view returns (uint256 amount, uint8 status, uint256 deadline) {
        _validateMilestoneIndex(index);

        Milestone storage milestone = milestones[index];
        return (milestone.amount, uint8(milestone.status), milestone.deadline);
    }

    function getContractBalance() external view returns (uint256) {
        return usdcToken.balanceOf(address(this));
    }

    function getEscrowInfo()
        external
        view
        returns (address escrowClient, address escrowFreelancer, address usdc, uint256 funded)
    {
        return (client, freelancer, address(usdcToken), totalFunded);
    }

    function _validateMilestoneIndex(uint256 milestoneIndex) internal pure {
        if (milestoneIndex >= 3) revert InvalidMilestoneIndex();
    }
}
