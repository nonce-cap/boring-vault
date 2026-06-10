// SPDX-License-Identifier: SEL-1.0
// Copyright © 2025 Veda Tech Labs
// Derived from Boring Vault Software © 2025 Veda Tech Labs (TEST ONLY – NO COMMERCIAL USE)
// Licensed under Software Evaluation License, Version 1.0
pragma solidity 0.8.21;

import {BaseTestIntegration} from "test/integrations/BaseTestIntegration.t.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {MidasVaultDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/MidasVaultDecoderAndSanitizer.sol";
import {BaseDecoderAndSanitizer} from "src/base/DecodersAndSanitizers/BaseDecoderAndSanitizer.sol";
import {Test, stdStorage, StdStorage, stdError, console} from "@forge-std/Test.sol";

contract FullMidasVaultDecoderAndSanitizer is MidasVaultDecoderAndSanitizer, BaseDecoderAndSanitizer {}

contract MidasVaultIntegrationTest is BaseTestIntegration {

    function _setUpOptimism() internal {
        super.setUp();
        _setupChain("optimism", 152760000);

        address midasVaultDecoder = address(new FullMidasVaultDecoderAndSanitizer());

        _overrideDecoder(midasVaultDecoder);
    }

    function _getMidasLeafs() internal returns (ManageLeaf[] memory leafs) {
        leafs = new ManageLeaf[](8);

        ERC20[] memory depositAssets = new ERC20[](2);
        depositAssets[0] = getERC20(sourceChain, "USDC");
        depositAssets[1] = getERC20(sourceChain, "USDT");

        ERC20[] memory redeemAssets = new ERC20[](1);
        redeemAssets[0] = getERC20(sourceChain, "USDC");

        _addMidasVaultLeafs(leafs, depositAssets, redeemAssets, getAddress(sourceChain, "liquidRWA"), getAddress(sourceChain, "liquidRWA_DepositAdapter"), getAddress(sourceChain, "liquidRWA_RedemptionVault"));

        // leafs[0] approve USDC -> liquidRWA_DepositAdapter
        // leafs[1] depositInstant(USDC)
        // leafs[2] approve USDT -> liquidRWA_DepositAdapter
        // leafs[3] depositInstant(USDT)
        // leafs[4] approve liquidRWA -> liquidRWA_RedemptionVault
        // leafs[5] redeemInstant(USDC)
        // leafs[6] redeemRequest(USDC)
    }

    function _depositInstant(ManageLeaf[] memory leafs, bytes32[][] memory manageTree, string memory asset) internal {
        bool isUsdc = keccak256(bytes(asset)) == keccak256(bytes("USDC"));

        Tx memory tx_ = _getTxArrays(2);

        tx_.manageLeafs[0] = isUsdc ? leafs[0] : leafs[2]; //approve asset
        tx_.manageLeafs[1] = isUsdc ? leafs[1] : leafs[3]; //depositInstant(asset)

        bytes32[][] memory manageProofs = _getProofsUsingTree(tx_.manageLeafs, manageTree);

        tx_.targets[0] = getAddress(sourceChain, asset); //approve
        tx_.targets[1] = getAddress(sourceChain, "liquidRWA_DepositAdapter");

        tx_.targetData[0] = abi.encodeWithSignature(
            "approve(address,uint256)", getAddress(sourceChain, "liquidRWA_DepositAdapter"), type(uint256).max
        );
        tx_.targetData[1] = abi.encodeWithSignature(
            "depositInstant(address,uint256,uint256,bytes32)",
            getAddress(sourceChain, asset),
            10_000e18, //amounts are in base 18 regardless of token decimals
            0,
            bytes32(0)
        );

        tx_.decodersAndSanitizers[0] = rawDataDecoderAndSanitizer;
        tx_.decodersAndSanitizers[1] = rawDataDecoderAndSanitizer;

        _submitManagerCall(manageProofs, tx_);
    }

    function testDepositInstantUSDC() external {
        _setUpOptimism();

        deal(getAddress(sourceChain, "USDC"), address(boringVault), 100_000e6);

        ManageLeaf[] memory leafs = _getMidasLeafs();
        bytes32[][] memory manageTree = _generateMerkleTree(leafs);

        //_generateTestLeafs(leafs, manageTree);

        manager.setManageRoot(address(this), manageTree[manageTree.length - 1][0]);

        _depositInstant(leafs, manageTree, "USDC");

        uint256 mTokenBal = getERC20(sourceChain, "liquidRWA").balanceOf(address(boringVault));
    }

    function testDepositInstantUSDT() external {
        _setUpOptimism();

        deal(getAddress(sourceChain, "USDT"), address(boringVault), 100_000e6);

        ManageLeaf[] memory leafs = _getMidasLeafs();
        bytes32[][] memory manageTree = _generateMerkleTree(leafs);

        manager.setManageRoot(address(this), manageTree[manageTree.length - 1][0]);

        _depositInstant(leafs, manageTree, "USDT");

        uint256 mTokenBal = getERC20(sourceChain, "liquidRWA").balanceOf(address(boringVault));
        assertGt(mTokenBal, 0);
    }

    function testRedeemInstant() external {
        _setUpOptimism();

        deal(getAddress(sourceChain, "USDC"), address(boringVault), 100_000e6);
        //the redemption vault only holds ~0.4 USDC at this block, so seed it with liquidity to take the direct payout path
        deal(getAddress(sourceChain, "USDC"), getAddress(sourceChain, "liquidRWA_RedemptionVault"), 100_000e6);

        ManageLeaf[] memory leafs = _getMidasLeafs();
        bytes32[][] memory manageTree = _generateMerkleTree(leafs);

        manager.setManageRoot(address(this), manageTree[manageTree.length - 1][0]);

        _depositInstant(leafs, manageTree, "USDC");

        uint256 redemptionAmount = 1 ether;
        assertGt(redemptionAmount, 0);

        Tx memory tx_ = _getTxArrays(2);

        tx_.manageLeafs[0] = leafs[4]; //approve liquidRWA
        tx_.manageLeafs[1] = leafs[5]; //redeemInstant(USDC)

        bytes32[][] memory manageProofs = _getProofsUsingTree(tx_.manageLeafs, manageTree);

        tx_.targets[0] = getAddress(sourceChain, "liquidRWA"); //approve
        tx_.targets[1] = getAddress(sourceChain, "liquidRWA_RedemptionVault");

        tx_.targetData[0] = abi.encodeWithSignature(
            "approve(address,uint256)", getAddress(sourceChain, "liquidRWA_RedemptionVault"), type(uint256).max
        );
        tx_.targetData[1] = abi.encodeWithSignature(
            "redeemInstant(address,uint256,uint256)",
            getAddress(sourceChain, "USDC"),
            redemptionAmount,
            0
        );

        tx_.decodersAndSanitizers[0] = rawDataDecoderAndSanitizer;
        tx_.decodersAndSanitizers[1] = rawDataDecoderAndSanitizer;

        _submitManagerCall(manageProofs, tx_);

        uint256 usdcBal = getERC20(sourceChain, "USDC").balanceOf(address(boringVault));
        assertGt(usdcBal, 0);
    }

    function testRedeemRequest() external {
        _setUpOptimism();

        deal(getAddress(sourceChain, "USDC"), address(boringVault), 100_000e6);

        ManageLeaf[] memory leafs = _getMidasLeafs();
        bytes32[][] memory manageTree = _generateMerkleTree(leafs);

        manager.setManageRoot(address(this), manageTree[manageTree.length - 1][0]);

        _depositInstant(leafs, manageTree, "USDC");

        uint256 mTokenBal = getERC20(sourceChain, "liquidRWA").balanceOf(address(boringVault));
        assertGt(mTokenBal, 0);

        Tx memory tx_ = _getTxArrays(2);

        tx_.manageLeafs[0] = leafs[4]; //approve liquidRWA
        tx_.manageLeafs[1] = leafs[6]; //redeemRequest(USDC)

        bytes32[][] memory manageProofs = _getProofsUsingTree(tx_.manageLeafs, manageTree);

        tx_.targets[0] = getAddress(sourceChain, "liquidRWA"); //approve
        tx_.targets[1] = getAddress(sourceChain, "liquidRWA_RedemptionVault");

        tx_.targetData[0] = abi.encodeWithSignature(
            "approve(address,uint256)", getAddress(sourceChain, "liquidRWA_RedemptionVault"), type(uint256).max
        );
        tx_.targetData[1] = abi.encodeWithSignature(
            "redeemRequest(address,uint256)",
            getAddress(sourceChain, "USDC"),
            mTokenBal
        );

        tx_.decodersAndSanitizers[0] = rawDataDecoderAndSanitizer;
        tx_.decodersAndSanitizers[1] = rawDataDecoderAndSanitizer;

        _submitManagerCall(manageProofs, tx_);

        uint256 mTokenBalAfter = getERC20(sourceChain, "liquidRWA").balanceOf(address(boringVault));
        assertEq(mTokenBalAfter, 0);
    }
}
