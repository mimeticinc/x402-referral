// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {X402ReferralSplitProxy} from "../src/X402ReferralSplitProxy.sol";

/**
 * @title DeployReferralSplit
 * @notice Deploys X402ReferralSplitProxy bound to the canonical Permit2.
 * @dev Base Sepolia:
 *        forge script script/DeployReferralSplit.s.sol:DeployReferralSplit \
 *          --rpc-url https://sepolia.base.org --broadcast --private-key $PRIVATE_KEY
 *
 *      The contract takes Permit2 as its only constructor arg; Permit2 is at the
 *      same canonical address on every EVM chain. Override with PERMIT2_ADDRESS
 *      for chains with a non-canonical deployment.
 */
contract DeployReferralSplit is Script {
    address constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() public {
        address permit2 = vm.envOr("PERMIT2_ADDRESS", CANONICAL_PERMIT2);

        console2.log("Network chainId:", block.chainid);
        console2.log("Permit2:", permit2);
        if (block.chainid != 31_337 && block.chainid != 1337) {
            require(permit2.code.length > 0, "Permit2 not found on this network");
        }

        vm.startBroadcast();
        X402ReferralSplitProxy splitter = new X402ReferralSplitProxy(permit2);
        vm.stopBroadcast();

        console2.log("X402ReferralSplitProxy deployed at:", address(splitter));
        require(address(splitter.PERMIT2()) == permit2, "PERMIT2 mismatch");
        console2.log("Verified PERMIT2 wiring OK");
    }
}
