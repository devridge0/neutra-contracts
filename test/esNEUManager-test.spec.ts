import hre from 'hardhat';
import { expect, use } from 'chai';
import { solidity } from 'ethereum-waffle';
import { neutraProtocolFixture } from './fixtures/neutra-protocols';
import { expandDecimals, increaseTime, mineBlock } from '../shared/utils';

use(solidity)

describe('EsNEUManager', () => {
    const provider = waffle.provider;

    let esNEU;
    let neu;
    let vesterNeu;
    let esNEUManager;
    let deployer;
    let user0;
    let user1;
    
    before(async() => {
        ({esNEU, neu, vesterNeu, esNEUManager} = await neutraProtocolFixture());
        [deployer, user0, user1] = await hre.ethers.getSigners();
    })

    it('deposit esNEU in manager', async () => {
        await esNEUManager.depositForAccount(deployer.address, expandDecimals(10, 18));

        expect(await esNEU.balanceOf(esNEUManager.address)).eq(String(expandDecimals(10, 18)));
    })

    it("fail transfer esNEU", async () => {
        await esNEU.setMinter(deployer.address, true);
        await esNEU.mint(deployer.address, expandDecimals(10, 18));

        await expect(esNEU.transfer(user1.address, expandDecimals(10, 18)))
        .to.be.revertedWith("BaseToken: msg.sender not whitelisted");
    })

    it("success transfer esNEU by manager", async () => {
        await esNEUManager.transfer(user1.address, expandDecimals(10, 18));

        expect(await esNEU.balanceOf(user1.address)).eq(String(expandDecimals(10, 18)));
    })

    it("success vesting esNEU with bonus rewards", async () => {
        await vesterNeu.connect(user1).deposit(String(expandDecimals(10, 18)));

        expect(await vesterNeu.balanceOf(user1.address)).eq(String(expandDecimals(10, 18)));
    })

    it("success claim NEU", async () => {
        await neu.setMinter(deployer.address, true);
        await neu.mint(vesterNeu.address, expandDecimals(10, 18));

        await increaseTime(provider, 31536000);
        await mineBlock(provider);

        await vesterNeu.connect(user1).claim();

        expect(await vesterNeu.balanceOf(user1.address)).eq("0");
        expect(await neu.balanceOf(user1.address)).eq(String(expandDecimals(10, 18)));
    })
})
