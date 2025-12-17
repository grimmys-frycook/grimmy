// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract Grimmy is ERC20, Ownable {
    uint256 public constant TOTAL_SUPPLY = 4_200_000_000 * 10 ** 18; // 4.2 billion

    mapping(address => bool) private _blacklisted;

    event Blacklisted(address indexed account);
    event UnBlacklisted(address indexed account);

    constructor() {
        _mint(msg.sender, TOTAL_SUPPLY);
        _initializeOwner(msg.sender);
    }

    function blacklist(address account) external onlyOwner {
        require(!_blacklisted[account], "Already blacklisted");
        _blacklisted[account] = true;
        emit Blacklisted(account);
    }

    function unblacklist(address account) external onlyOwner {
        require(_blacklisted[account], "Not blacklisted");
        _blacklisted[account] = false;
        emit UnBlacklisted(account);
    }

    function isBlacklisted(address account) external view returns (bool) {
        return _blacklisted[account];
    }

    function name() public pure override returns (string memory) {
        return "The Grimmy Stimmy";
    }

    function symbol() public pure override returns (string memory) {
        return "GRIMMY";
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal view override {
        require(!_blacklisted[from], "Sender blacklisted");
        require(!_blacklisted[to], "Recipient blacklisted");
    }
}
