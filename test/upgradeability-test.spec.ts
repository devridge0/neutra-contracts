import hre from 'hardhat';
import { expect, use } from 'chai';
import {solidity} from 'ethereum-waffle';
import { strategyVaultConfig } from './fixtures/neutra-protocols';
import addr from '../shared/constants/addresses';
import { neutraProtocolFixture } from './fixtures/neutra-protocols';

use(solidity)

describe('upgradability test', () => {
    let strategyVault;
    let strategyVaultV2;
    let strategyVaultV3;

    let batchRouter;
    let batchRouterV2;

    before(async() => {
        ({strategyVault, batchRouter} = await neutraProtocolFixture());
    })

    it(`checks upgradeability to nGLP v2`, async() => {
        const deployer = await hre.ethers.getImpersonatedSigner(addr.DEPLOYER);
        const Vault = await hre.ethers.getContractFactory("StrategyVault", deployer)
        let vault = await hre.upgrades.forceImport(addr.NEUTRA.StrategyVault, Vault, { kind : 'uups'});
        const VaultV2 = await hre.ethers.getContractFactory("contracts/StrategyVaultV2.sol:StrategyVaultV2", deployer);
        vault = await hre.upgrades.upgradeProxy(vault, VaultV2);
        await expect(vault.initialize(strategyVaultConfig)).to.be.revertedWith('Initializable: contract is already initialized');
    })

    it('should reverts if initialize function called again', async() => {
        await expect(strategyVault.initialize(strategyVaultConfig)).to.be.revertedWith('Initializable: contract is already initialized');
    })  

    it('should reverts if unathourized user try to upgrade contract', async() => {
        const whale = await hre.ethers.getImpersonatedSigner(addr.DAI_WHALE);
        const StrategyVaultV2 = await hre.ethers.getContractFactory("contracts/test/StrategyVaultV2.sol:StrategyVaultV2", whale);
        await expect(hre.upgrades.upgradeProxy(strategyVault, StrategyVaultV2)).to.be.reverted;
    }) 

    it('upgrades with additional function', async() => {
        const StrategyVaultV2 = await hre.ethers.getContractFactory("contracts/test/StrategyVaultV2.sol:StrategyVaultV2");
        strategyVaultV2 = await hre.upgrades.upgradeProxy(strategyVault, StrategyVaultV2);
        expect(await strategyVaultV2.upgradeableTest()).eq(1);
    })

    it('upgrades with different logic & additinal state', async() => {
        const StrategyVaultV3 = await hre.ethers.getContractFactory("contracts/test/StrategyVaultV3.sol:StrategyVaultV3");
        strategyVaultV3 = await hre.upgrades.upgradeProxy(strategyVaultV2, StrategyVaultV3);
        expect(await strategyVaultV3.upgradeableTest()).eq(2);
        expect(await strategyVaultV3.testMappings(hre.ethers.constants.AddressZero)).eq(0)
        expect(await strategyVaultV3.testBytes8()).eq(hre.ethers.constants.HashZero.substring(0, 18));
        expect(await strategyVaultV3.testUint256()).eq(0);
    })
})