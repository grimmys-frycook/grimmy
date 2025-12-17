// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Grimmy} from "../src/Grimmy.sol";
import {Stimmy} from "../src/Stimmy.sol";
import {Flippy} from "../src/Flippy.sol";

contract Deploy is Script {
    Grimmy internal grimmy;
    Stimmy internal stimmy;
    Flippy internal flippy;

    uint256 internal chainId;

    uint256 internal initialReserve;
    uint256 internal initialDividendThreshold;
    uint256 internal initialMinBet;
    uint256 internal initialMaxBet;

    function run() external {
        chainId = block.chainid;
        console2.log("Chain ID:", chainId);

        if (chainId == 10143) {
            // Testnet
            initialReserve = 2_898_000_000 ether;
            initialDividendThreshold = 5 ether;
        } else if (chainId == 143) {
            // Mainnet
            initialReserve = 2_898_000_000 ether;
            initialDividendThreshold = 1_000_000 ether;
            initialMinBet = 100 ether;
            initialMaxBet = 50_000 ether;
        } else {
            revert("Invalid chain ID");
        }

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address entropy = vm.envOr("ENTROPY_ADDRESS", address(0));
        address provider = vm.envOr("ENTROPY_PROVIDER", address(0));
        require(entropy != address(0), "ENTROPY_ADDRESS not set");
        require(provider != address(0), "ENTROPY_PROVIDER not set");
        require(initialReserve > 0, "initial reserve zero");

        uint32 callbackGasLimit = 200_000;

        vm.startBroadcast(deployerPrivateKey);

        grimmy = new Grimmy();
        {
            address stimmyTemplate = address(new Stimmy(address(grimmy)));
            console2.log("Stimmy template address:", address(stimmyTemplate));
            stimmy = Stimmy(
                payable(new ERC1967Proxy(
                        address(stimmyTemplate), abi.encodeWithSelector(Stimmy.initialize.selector, deployer)
                    ))
            );
        }
        address flippyTemplate = address(new Flippy(entropy, address(grimmy), address(stimmy), initialReserve));
        console2.log("Flippy template address:", address(flippyTemplate));

        // Get nonce after deploying Grimmy and Stimmy
        // The approval transaction will use the next nonce, and Flippy will use the one after that
        uint64 currentNonce = vm.getNonce(deployer);
        uint64 flippyNonce = currentNonce + 1; // +1 because approve() will be broadcast first
        address predictedFlippy = vm.computeCreateAddress(deployer, flippyNonce);

        console2.log("Current nonce:", currentNonce);
        console2.log("Flippy will deploy at nonce:", flippyNonce);
        console2.log("Flippy predicted address:", predictedFlippy);

        SafeTransferLib.safeTransfer(address(grimmy), predictedFlippy, initialReserve);

        uint32 initialTimeout = 300; // 5 minutes
        flippy = Flippy(
            payable(new ERC1967Proxy(
                    flippyTemplate,
                    abi.encodeWithSelector(
                        Flippy.initialize.selector,
                        deployer,
                        provider,
                        callbackGasLimit,
                        initialDividendThreshold,
                        initialTimeout,
                        initialMinBet,
                        initialMaxBet
                    )
                ))
        );

        console2.log("Flippy actual address:", address(flippy));
        require(address(flippy) == predictedFlippy, "Address prediction mismatch!");

        vm.stopBroadcast();

        console2.log("Grimmy deployed at", address(grimmy));
        console2.log("Stimmy deployed at", address(stimmy));
        console2.log("Flippy deployed at", address(flippy));
    }

    /// DEV: Make sure to fund Flippy with 200k MON
    /// DEV: Make sure to LP 20B GRIMMY
}
