// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockUsdc} from "../src/MockUsdc.sol";

contract NonMinter {
    function mint(MockUsdc token, address to, uint256 amount) external {
        token.mint(to, amount);
    }
}

contract MockUsdcTest {
    function testMetadataAndMintBurn() external {
        MockUsdc token = new MockUsdc(address(this));
        address holder = address(0xBEEF);

        require(token.decimals() == 6, "decimals");
        require(keccak256(bytes(token.symbol())) == keccak256("USDC"), "symbol");

        token.mint(holder, 10_000_000);
        require(token.balanceOf(holder) == 10_000_000, "mint balance");
        require(token.totalSupply() == 10_000_000, "mint supply");

        token.burnFrom(holder, 4_000_000);
        require(token.balanceOf(holder) == 6_000_000, "burn balance");
        require(token.totalSupply() == 6_000_000, "burn supply");
    }

    function testOnlyMinterCanIssue() external {
        MockUsdc token = new MockUsdc(address(this));
        NonMinter stranger = new NonMinter();
        bool reverted;

        try stranger.mint(token, address(stranger), 1) {
            reverted = false;
        } catch {
            reverted = true;
        }

        require(reverted, "non-minter issued tokens");
    }
}
