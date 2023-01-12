import hre from 'hardhat';
import { expect, use } from 'chai';
import {solidity} from 'ethereum-waffle';
import { strategyVaultConfig } from './fixtures/neutra-protocols';

use(solidity)

describe('upgradability test', () => {
    let strategyVault;
    let strategyVaultV2;
    let strategyVaultV3;

    before(async() => {
        const StrategyVault = await hre.ethers.getContractFactory("StrategyVault"); 
        strategyVault = await hre.upgrades.deployProxy(StrategyVault, [strategyVaultConfig], {kind : 'uups'});
    })

    it('upgrades with additional function', async() => {
        const StrategyVaultV2 = await hre.ethers.getContractFactory("StrategyVaultV2");
        strategyVaultV2 = await hre.upgrades.upgradeProxy(strategyVault, StrategyVaultV2);
        expect(await strategyVaultV2.upgradeableTest()).eq(1);
    })

    it('upgrades with different logic & additinal state', async() => {
        const StrategyVaultV3 = await hre.ethers.getContractFactory("StrategyVaultV3");
        strategyVaultV3 = await hre.upgrades.upgradeProxy(strategyVaultV2, StrategyVaultV3);
        expect(await strategyVaultV3.upgradeableTest()).eq(2);
        expect(await strategyVaultV3.testMappings(hre.ethers.constants.AddressZero)).eq(0)
        expect(await strategyVaultV3.testBytes8()).eq(hre.ethers.constants.HashZero.substring(0, 18));
        expect(await strategyVaultV3.testUint256()).eq(0);
    })
})