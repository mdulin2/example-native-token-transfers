// SPDX-License-Identifier: Apache 2
pragma solidity 0.8.19;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../src/ManagerStandalone.sol";
import "../src/EndpointAndManager.sol";
import "../src/EndpointStandalone.sol";
import "../src/interfaces/IManager.sol";
import "../src/interfaces/IRateLimiter.sol";
import "../src/interfaces/IManagerEvents.sol";
import "../src/interfaces/IRateLimiterEvents.sol";
import {Utils} from "./libraries/Utils.sol";
import {DummyToken} from "./Manager.t.sol";
import {WormholeEndpointStandalone} from "../src/WormholeEndpointStandalone.sol";

import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "wormhole-solidity-sdk/interfaces/IWormhole.sol";
import "wormhole-solidity-sdk/testing/helpers/WormholeSimulator.sol";
import "wormhole-solidity-sdk/Utils.sol";
import {WormholeRelayerBasicTest} from "wormhole-solidity-sdk/testing/WormholeRelayerTest.sol";


contract TestEndToEndRelayer is Test, IManagerEvents, IRateLimiterEvents, WormholeRelayerBasicTest{
    ManagerStandalone managerChain1;
    ManagerStandalone managerChain2;

    using NormalizedAmountLib for uint256;
    using NormalizedAmountLib for NormalizedAmount;

    uint16 constant chainId1 = 23;
    uint16 constant chainId2 = 24;

    WormholeSimulator guardian;
    uint256 initialBlockTimestamp;

    WormholeEndpointStandalone wormholeEndpointChain1; 
    WormholeEndpointStandalone wormholeEndpointChain2; 
    address userA = address(0x123); 
    address userB = address(0x456); 
    address userC = address(0x789);
    address userD = address(0xABC);

    constructor(){
        setTestnetForkChains(chainId1, chainId2);
    }

    // https://github.com/wormhole-foundation/hello-wormhole/blob/main/test/HelloWormhole.t.sol#L14C1-L20C6
    // Setup the starting point of the network
    function setUpSource() public override {
        vm.deal(userA, 1 ether);
        DummyToken t1 = new DummyToken();

        ManagerStandalone implementation =
            new ManagerStandalone(address(t1), Manager.Mode.LOCKING, chainId1, 1 days);

        managerChain1 = ManagerStandalone(address(new ERC1967Proxy(address(implementation), "")));
        managerChain1.initialize();

        wormholeEndpointChain1 = new WormholeEndpointStandalone(
            address(managerChain1), 
            address(chainInfosTestnet[chainId1].wormhole),
            address(relayerSource)
        );

        managerChain1.setEndpoint(address(wormholeEndpointChain1));
        managerChain1.setOutboundLimit(NormalizedAmount.wrap(type(uint64).max).denormalize(18));
        managerChain1.setInboundLimit(NormalizedAmount.wrap(type(uint64).max).denormalize(18), chainId2);
    }

    // Setup the chain to relay to of the network
    function setUpTarget() public override {
        vm.deal(userC, 1 ether);

        // Chain 2 setup
        DummyToken t2 = new DummyToken();
        ManagerStandalone implementationChain2 =
            new ManagerStandalone(address(t2), Manager.Mode.BURNING, chainId2, 1 days);

        managerChain2 = ManagerStandalone(address(new ERC1967Proxy(address(implementationChain2), "")));
        managerChain2.initialize();
        wormholeEndpointChain2 = new WormholeEndpointStandalone(
            address(managerChain2), 
            address(chainInfosTestnet[chainId2].wormhole),
            address(relayerTarget) 
        );
    }

    function test_chain_to_chain() public{

        // record all of the logs for all of the occuring events
        vm.recordLogs();

        // Setup the information for interacting with the chains
        vm.selectFork(targetFork);
        managerChain2.setEndpoint(address(wormholeEndpointChain2));
        managerChain2.setOutboundLimit(NormalizedAmount.wrap(type(uint64).max).denormalize(18));
        managerChain2.setInboundLimit(NormalizedAmount.wrap(type(uint64).max).denormalize(18), chainId1);
        wormholeEndpointChain2.setWormholeSibling(chainId1, bytes32(uint256(uint160(address(wormholeEndpointChain1)))));
        managerChain2.setSibling(chainId1, bytes32(uint256(uint160(address(managerChain1)))));  
        DummyToken token2 = DummyToken(managerChain2.token());
        wormholeEndpointChain2.setIsWormholeRelayingEnabled(chainId1, true); 
        wormholeEndpointChain2.setIsWormholeEvmChain(chainId1);

        // Register sibling contracts for the manager and endpoint. Endpoints and manager each have the concept of siblings here.
        vm.selectFork(sourceFork);
        managerChain1.setSibling(chainId2, bytes32(uint256(uint160(address(managerChain2)))));
        wormholeEndpointChain1.setWormholeSibling(chainId2, bytes32(uint256(uint160((address(wormholeEndpointChain2))))));
        DummyToken token1 = DummyToken(managerChain1.token());

        // Enable general relaying on the chain to transfer for the funds.
        wormholeEndpointChain1.setIsWormholeRelayingEnabled(chainId2, true); 
        wormholeEndpointChain1.setIsWormholeEvmChain(chainId2);

        // Setting up the transfer
        uint8 decimals = token1.decimals();
        uint256 sendingAmount = 5 * 10 ** decimals; 
        token1.mintDummy(address(userA), 5 * 10 ** decimals);
        vm.startPrank(userA);
        token1.approve(
            address(managerChain1),
            sendingAmount
        );

        // Send token through standard means (not relayer) 
        {
            uint256 managerBalanceBefore = token1.balanceOf(address(managerChain1));
            uint256 userBalanceBefore = token1.balanceOf(address(userA));

            managerChain1.transfer{value: wormholeEndpointChain1.quoteDeliveryPrice(chainId2)}(
                sendingAmount,
                chainId2,
                bytes32(uint256(uint160(userB))),
                false
            );

            // Balance check on funds going in and out working as expected
            uint256 managerBalanceAfter = token1.balanceOf(address(managerChain1));
            uint256 userBalanceAfter = token1.balanceOf(address(userB));
            require(managerBalanceBefore + sendingAmount == managerBalanceAfter, "Should be locking the tokens");
            require(userBalanceBefore - sendingAmount == userBalanceAfter, "User should have sent tokens");
        }

        vm.stopPrank();

        vm.selectFork(targetFork); // Move to the target chain briefly to get the total supply
        uint256 supplyBefore = token2.totalSupply();

        console.logAddress(address(managerChain1));
        console.logAddress(address(managerChain2));
        console.logAddress(address(wormholeEndpointChain1));
        console.logAddress(address(wormholeEndpointChain2));

        // Deliver the TX via the relayer mechanism. That's pretty fly!
        vm.selectFork(sourceFork); // Move to back to the source chain for things to be processed
        // Turn on the log recording because we want the test framework to pick up the events.
        performDelivery();

        vm.selectFork(targetFork); // Move to back to the target chain to look at how things were processed

        uint256 supplyAfter = token2.totalSupply();
        console.log(supplyBefore, supplyAfter);

        require(sendingAmount + supplyBefore == supplyAfter, "Supplies dont match");
        require(token2.balanceOf(userB) == sendingAmount, "User didn't receive tokens");
        require(token2.balanceOf(address(managerChain2)) == 0, "Manager has unintended funds");
    /*
        0x7b0AA1e6Fcd181d45C94ac62901722231074d8d4
        0x24c20C0B0F62358b3C857A62Dc3730f2dAA352B6
        0x87B2d08110B7D50861141D7bBDd49326af3Ecb31
        0x7F1f3E02E4B20b47e5E6b3b54893F335D3A41dc1
    */

        // Go back the other way from a THIRD user
        vm.prank(userB);
        token2.transfer(userC, sendingAmount);

        vm.startPrank(userC);
        token2.approve(address(managerChain2), sendingAmount);

        {
            uint256 supplyBefore = token2.totalSupply();
            managerChain2.transfer{value: wormholeEndpointChain2.quoteDeliveryPrice(chainId1)}(
                sendingAmount,
                chainId1,
                bytes32(uint256(uint160(userD))),
                false
            );
            
            uint256 supplyAfter = token2.totalSupply();
            console.log(supplyBefore, sendingAmount, supplyAfter);

            require(sendingAmount - supplyBefore == supplyAfter, "Supplies don't match");
            require(token2.balanceOf(userB) == 0, "OG user receive tokens");
            require(token2.balanceOf(userC) == 0, "Sending user didn't receive tokens");
            require(token2.balanceOf(address(managerChain2)) == 0, "Manager didn't receive unintended funds");
        }

        // Receive the transfer
        vm.selectFork(sourceFork); // Move to the source chain briefly to get the total supply
        supplyBefore = token1.totalSupply();

        vm.selectFork(targetFork); // Move to the target chain for log processing

        // Deliver the TX via the relayer mechanism. That's pretty fly!
        performDelivery();

        vm.selectFork(sourceFork); // Move back to the source chain to check out the balances

        require(supplyBefore == supplyAfter, "Supplies dont match on way out");
        require(token1.balanceOf(userD) == sendingAmount, "User didn't receive tokens going back");
        require(token1.balanceOf(address(managerChain1)) == 0, "Manager has unintended funds going back");
    }

    function copyBytes(bytes memory _bytes) private pure returns (bytes memory)
    {
        bytes memory copy = new bytes(_bytes.length);
        uint256 max = _bytes.length + 31;
        for (uint256 i=32; i<=max; i+=32)
        {
            assembly { mstore(add(copy, i), mload(add(_bytes, i))) }
        }
        return copy;
    }
}