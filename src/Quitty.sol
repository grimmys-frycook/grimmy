// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/**
 * @title Quitty
 * @notice A simple contract where players can self-exclude with a deadline and delete their exclusion
 */
contract Quitty {
    mapping(address => uint256) public deadlineOf;

    event SelfExcluded(address indexed player, uint256 deadline);
    event ExclusionDeleted(address indexed player);

    error InvalidDeadline();

    /**
     * @notice Self-exclude with a deadline
     * @param deadline The timestamp until which the player is excluded
     */
    function selfExclude(uint256 deadline) external {
        if (deadline <= block.timestamp) {
            revert InvalidDeadline();
        }

        deadlineOf[msg.sender] = deadline;
        emit SelfExcluded(msg.sender, deadline);
    }

    /**
     * @notice Delete your exclusion
     */
    function deleteExclusion() external {
        deadlineOf[msg.sender] = 0;
        emit ExclusionDeleted(msg.sender);
    }

    /**
     * @notice Check if an address is currently excluded
     * @param player The address to check
     * @return Whether the player is currently excluded
     */
    function isExcluded(address player) external view returns (bool) {
        return deadlineOf[player] > block.timestamp;
    }
}
