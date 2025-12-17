// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {Grimmy} from "../src/Grimmy.sol";
import {Stimmy} from "../src/Stimmy.sol";
import {Flippy} from "../src/Flippy.sol";

contract Upgrade is Script {
    Grimmy internal grimmy;
    Stimmy internal stimmy;
    Flippy internal flippy;
    uint256 internal deployerPrivateKey;
    address internal deployer;

    function setUp() external {
        uint256 chainId = block.chainid;
        console2.log("Chain ID:", chainId);

        deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);
        console2.log("Deployer:", deployer);

        if (chainId == 10143) {
            // Testnet
            grimmy = Grimmy(0x3bc3Cb3496d95986c493DFe4E8B379F114C90727);
            stimmy = Stimmy(payable(0xe565994096A61d01b009b98210DcbB68617BcEF4));
            flippy = Flippy(payable(0x9343E8d7359c3F4F1F0003da13003b120C4Ff230));
        } else if (chainId == 143) {
            // Mainnet
            grimmy = Grimmy(0xDcA99DcC29e19022012c5D755f1b12C61D127857);
            stimmy = Stimmy(payable(0x26018Cb486254c9697ed654D023C5d737FDD31e4));
            flippy = Flippy(payable(0x3717F45e87744E48D954684f34f57902da1134da));
        } else {
            revert("Invalid chain ID");
        }
    }

    function upgradeStimmy() external {
        vm.startBroadcast(deployerPrivateKey);

        address stimmyTemplate = address(new Stimmy(address(grimmy)));
        stimmy.upgradeToAndCall(address(stimmyTemplate), "");

        vm.stopBroadcast();

        console2.log("Stimmy upgraded with implementation", address(stimmy));
    }

    function upgradeFlippy() external {
        vm.startBroadcast(deployerPrivateKey);

        address flippyTemplate = address(
            new Flippy(address(flippy.ENTROPY()), address(grimmy), address(stimmy), flippy.INITIAL_GRIMMY_RESERVE())
        );
        flippy.upgradeToAndCall(address(flippyTemplate), "");

        vm.stopBroadcast();
    }
}
