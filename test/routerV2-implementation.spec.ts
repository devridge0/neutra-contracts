import hre from 'hardhat';
import addr from '../shared/constants/addresses';
import { expect , use } from 'chai';
import { solidity } from 'ethereum-waffle';
import {deployContract, expandDecimals, getPriceBits} from "../shared/utils";
import { gmxProtocolFixture } from './fixtures/gmx-protocol';
import { EXECUTION_FEE } from '../shared/constants/constant';
import { gmxHelperConfig } from './fixtures/neutra-protocols';
import { executePositionsWithBits } from './helper/utils';

use(solidity);

describe('routerV2 implementation', () => {

    let deployer;
    let management;

    let strategyVault;
    let gmxHelper;
    let batchRouter;
    let nGlp;
    let fnGlp;
    let snGlp;
    let routerV2;    
    let dai;

    let repayCallbackTarget;
    let executionCallbackTarget;


    let user0; // withdrawer snGlp
    let user1; // depositer dai
    let user2; // depositer fsGlp

    // gmx contracts
    let fastPriceFeed;
    let positionRouter;
    let gmxVault;
    let glpManager;
    let shortsTracker
    let fsGlp;
    let stakedGlp;

    let gmxAdmin;
    let keeper;
    let priceBits;

    let routerInitialConfig = [
        addr.GMX.fsGlp,
        addr.NEUTRA.nGlp,
        addr.NEUTRA.fnGlp,
        addr.NEUTRA.snGlp,
        addr.GMX.Vault,
        addr.GMX.StakedGlp,
        addr.GMX.GlpRewardRouter,
        addr.GMX.GlpManager,
        
        addr.NEUTRA.StrategyVault,
        addr.NEUTRA.GmxHelper,

        addr.DAI,
        addr.WBTC,
        addr.WETH
    ]

    beforeEach(async() => {
        ({keeper, gmxVault, positionRouter, fastPriceFeed, dai, glpManager, shortsTracker, fsGlp, stakedGlp} = await gmxProtocolFixture());
        deployer = await hre.ethers.getImpersonatedSigner(addr.DEPLOYER);
        management = await hre.ethers.getImpersonatedSigner(addr.NEUTRA.management);

        const StrategyVault = await hre.ethers.getContractFactory('StrategyVault', deployer);
        strategyVault = await hre.upgrades.forceImport(addr.NEUTRA.StrategyVault, StrategyVault, { kind : 'uups'});
        const StrategyVaultV2 = await hre.ethers.getContractFactory("contracts/StrategyVaultV2.sol:StrategyVaultV2",deployer);
        strategyVault = await hre.upgrades.upgradeProxy(strategyVault, StrategyVaultV2);

        gmxHelper = await deployContract("GmxHelper", [gmxHelperConfig, addr.NEUTRA.nGlp, addr.DAI, addr.WBTC, addr.WETH]);
        batchRouter = await hre.ethers.getContractAt("BatchRouter", addr.NEUTRA.BatchRouter);
        nGlp = await hre.ethers.getContractAt("nGLP", addr.NEUTRA.nGlp);
        fnGlp = await hre.ethers.getContractAt("FeeNeuGlpTracker", addr.NEUTRA.fnGlp);
        snGlp = await hre.ethers.getContractAt("StakedNeuGlpTracker", addr.NEUTRA.snGlp);

        routerInitialConfig[9] = gmxHelper.address;
        routerV2 = await deployContract("RouterV2", [routerInitialConfig]);
        await nGlp.connect(deployer).setHandlers([routerV2.address], [true]);
        await nGlp.connect(deployer).setMinter(routerV2.address, true);

        await fnGlp.connect(deployer).setHandlers([routerV2.address], [true]);

        await snGlp.connect(deployer).setHandlers([routerV2.address], [true]);

        await strategyVault.connect(deployer).setRouter(routerV2.address, true);

        repayCallbackTarget = await deployContract("RepayCallbackTarget", [routerV2.address, addr.GMX.PositionRouter]);
        executionCallbackTarget = await deployContract("ExecutionCallbackTarget", [routerV2.address, addr.GMX.PositionRouter]);

        user0 = await hre.ethers.getImpersonatedSigner(addr.SNGLP_WAHLE);
        user1 = await hre.ethers.getImpersonatedSigner(addr.DAI_WHALE);
        user2 = await hre.ethers.getImpersonatedSigner(addr.FSGLP_WHALE);

        // gmx price
        const wbtcPrice = (await gmxVault.getMinPrice(addr.WBTC)).toString();
        const wethPrice = (await gmxVault.getMinPrice(addr.WETH)).toString();
        const linkPrice = (await gmxVault.getMinPrice(addr.LINK)).toString();
        const uniPrice = (await gmxVault.getMinPrice(addr.UNI)).toString();

        const prices = [
            wbtcPrice.substring(0,wbtcPrice.length-27), 
            wethPrice.substring(0, wethPrice.length-27), 
            linkPrice.substring(0, linkPrice.length-27), 
            uniPrice.substring(0, uniPrice.length-27)
        ];

        priceBits = getPriceBits(prices);

        // await positionRouter.connect(gmxAdmin).setCallbackGasLimit(2200000);
    })

    it("calls instantDeposit", async() => {
        await routerV2.setCallbackTargets(executionCallbackTarget.address, repayCallbackTarget.address);

        const depositAmount = expandDecimals(500, 18);
        const snGlpBefore : bigint = BigInt(await snGlp.balanceOf(user1.address));

        await expect(routerV2.connect(user1).instantDeposit(depositAmount, { value: EXECUTION_FEE * 2})).to.be.reverted;
        
        await dai.connect(user1).approve(routerV2.address, hre.ethers.constants.MaxUint256);
        await routerV2.connect(user1).instantDeposit(depositAmount, { value : EXECUTION_FEE * 2});
        
        console.log(`input Amount : ${depositAmount} DAI`);

        let totalValue = BigInt(await strategyVault.totalValue());
        let totalSupply = BigInt(await nGlp.totalSupply());
        let nGlpPrice = totalValue / totalSupply; 

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 1, 0);

        expect((await routerV2.pendingStatus())[4]).eq(true);

        totalValue = BigInt(await strategyVault.totalValue());
        totalSupply = BigInt(await nGlp.totalSupply());
        expect(nGlpPrice).eq(totalValue / totalSupply);

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 1, 0);

        expect((await routerV2.pendingStatus())[4]).eq(false);

        totalValue = BigInt(await strategyVault.totalValue());
        totalSupply = BigInt(await nGlp.totalSupply());
        expect(nGlpPrice).eq(totalValue / totalSupply);
        
        expect((await routerV2.pendingStatus())[0]).eq(hre.ethers.constants.AddressZero);
        expect((await routerV2.pendingStatus())[1]).eq(false);
        expect((await routerV2.pendingStatus())[2]).eq(0);
        expect((await routerV2.pendingStatus())[3]).eq(0);
        expect(await routerV2.cumulativeMintAmount()).eq(0);

        const snGlpAfter = BigInt(await snGlp.balanceOf(user1.address));
        console.log(`minted share : ${(snGlpAfter - snGlpBefore).toString()} snGlp`)
    })

    it("calls instantDepositGlp", async() => {
        await routerV2.setCallbackTargets(executionCallbackTarget.address, repayCallbackTarget.address);

        //fsGlp
        const depositAmount = expandDecimals(500, 18);
        const snGlpBefore : bigint = BigInt(await snGlp.balanceOf(user2.address));

        await expect(routerV2.connect(user2).instantDepositGlp(depositAmount, { value: EXECUTION_FEE *2})).to.be.reverted;

        console.log(`input Amount : ${depositAmount} fsGlp`);
        
        await stakedGlp.connect(user2).approve(routerV2.address, hre.ethers.constants.MaxUint256);
        await routerV2.connect(user2).instantDepositGlp(depositAmount, { value: EXECUTION_FEE * 2});

        let totalValue = BigInt(await strategyVault.totalValue());
        let totalSupply = BigInt(await nGlp.totalSupply());
        let nGlpPrice = totalValue / totalSupply; 

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 1, 0);

        expect((await routerV2.pendingStatus())[4]).eq(true);
        
        totalValue = BigInt(await strategyVault.totalValue());
        totalSupply = BigInt(await nGlp.totalSupply());
        expect(nGlpPrice).eq(totalValue / totalSupply);

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 1, 0);

        expect((await routerV2.pendingStatus())[4]).eq(false);

        totalValue = BigInt(await strategyVault.totalValue());
        totalSupply = BigInt(await nGlp.totalSupply());
        expect(nGlpPrice).eq(totalValue / totalSupply);
        
        const snGlpAfter = BigInt(await snGlp.balanceOf(user2.address));
        console.log(`minted share : ${(snGlpAfter - snGlpBefore).toString()} snGlp`)
    })

    it("calls instantWithdraw for DAI", async() => {
        await routerV2.setCallbackTargets(executionCallbackTarget.address, repayCallbackTarget.address);

        const withdrawalAmount = expandDecimals(5000, 18);
        const daiBefore : bigint = (await dai.balanceOf(user0.address)).toBigInt();

        await routerV2.connect(user0).instantWithdraw(withdrawalAmount, true, false, { value: EXECUTION_FEE * 4})
        
        console.log(`withdrawal input : ${withdrawalAmount} snGlp`);

        let totalValue = BigInt(await strategyVault.totalValue());
        let totalSupply = BigInt(await nGlp.totalSupply());

        console.log(`nGlp price : ${totalValue / totalSupply}`)

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 0, 2);

        totalValue = BigInt(await strategyVault.totalValue());
        totalSupply = BigInt(await nGlp.totalSupply());
        
        console.log(`nGlp price : ${totalValue / totalSupply}`)
        
        expect(await routerV2.cumulativeBurnAmount()).eq(0);

        // console.log('confirm : ', (await strategyVault.confirmed()).toString());
        expect((await routerV2.pendingStatus())[0]).eq(hre.ethers.constants.AddressZero);
        expect((await routerV2.pendingStatus())[1]).eq(false);
        expect((await routerV2.pendingStatus())[2]).eq(0);
        expect((await routerV2.pendingStatus())[3]).eq(0);
        expect(await routerV2.cumulativeBurnAmount()).eq(0);

        const daiAfter = (await dai.balanceOf(user0.address)).toBigInt();
        console.log(`redeemed amount : ${daiAfter - daiBefore} DAI`);
    })

    it("calls instantWithdraw for fsGlp & DAI", async() => {
        await routerV2.setCallbackTargets(executionCallbackTarget.address, repayCallbackTarget.address);
        
        const withdrawalAmount = expandDecimals(5000, 18);
        const daiBefore = (await dai.balanceOf(user0.address)).toBigInt();
        const fsGlpBefore = (await fsGlp.balanceOf(user0.address)).toBigInt();

        await expect(routerV2.connect(user0).instantWithdraw(withdrawalAmount, true, true, { value: EXECUTION_FEE * 4})).to.be.reverted;
        
        await strategyVault.connect(deployer).approveToken(addr.GMX.StakedGlp, routerV2.address);
        await routerV2.connect(user0).instantWithdraw(withdrawalAmount, true, true, {value :EXECUTION_FEE *4});

        console.log(`withdrawal input : ${withdrawalAmount} snGlp`);

        let totalValue = BigInt(await strategyVault.totalValue());
        let totalSupply = BigInt(await nGlp.totalSupply());
        let nGlpPrice = totalValue / totalSupply; 


        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 0, 1);

        expect((await routerV2.pendingStatus())[4]).eq(true);
        
        totalValue = BigInt(await strategyVault.totalValue());
        totalSupply = BigInt(await nGlp.totalSupply());
        expect(nGlpPrice).eq(totalValue / totalSupply);

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 0, 1);

        expect((await routerV2.pendingStatus())[4]).eq(false);

        totalValue = BigInt(await strategyVault.totalValue());
        totalSupply = BigInt(await nGlp.totalSupply());

        expect(nGlpPrice).eq(totalValue / totalSupply);

        expect((await routerV2.pendingStatus())[0]).eq(hre.ethers.constants.AddressZero);
        expect((await routerV2.pendingStatus())[1]).eq(false);
        expect((await routerV2.pendingStatus())[2]).eq(0);
        expect((await routerV2.pendingStatus())[3]).eq(0);
        expect(await routerV2.cumulativeBurnAmount()).eq(0);

        const daiAfter = (await dai.balanceOf(user0.address)).toBigInt();
        const fsGlpAfter = (await fsGlp.balanceOf(user0.address)).toBigInt();
        console.log(`redeemed amount : ${daiAfter - daiBefore} DAI`);
        console.log(`redeemed amount : ${fsGlpAfter - fsGlpBefore} fsGlp`);
    })

    it("checks fisrt callback - withdrawal in DAI", async() => {
        const withdrawAmount = expandDecimals(500 , 18)

        await routerV2.setCallbackTargets(executionCallbackTarget.address, repayCallbackTarget.address);
        await routerV2.connect(user0).instantWithdraw(withdrawAmount, true, false, { value: EXECUTION_FEE * 4});

        expect((await routerV2.pendingStatus())[0]).eq(user0.address);
        expect((await routerV2.pendingStatus())[1]).eq(true);

        let totalValue = BigInt(await strategyVault.totalValue());
        let totalSupply = BigInt(await nGlp.totalSupply());

        console.log(`nGlp price : ${totalValue / totalSupply}`)

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 0, 1);

        expect((await routerV2.pendingStatus())[4]).eq(true);
        expect(await executionCallbackTarget.status()).eq(1);
        
        totalValue = BigInt(await strategyVault.totalValue());
        totalSupply = BigInt(await nGlp.totalSupply());
        
        console.log(`nGlp price : ${totalValue / totalSupply}`)
    });

    it("checks minimum withdrawal amounts", async() => {
        await expect(routerV2.connect(user0).instantWithdraw(expandDecimals(500 , 18), true, false, { value: EXECUTION_FEE * 4})).to.be.reverted;
        await routerV2.setCallbackTargets(executionCallbackTarget.address, repayCallbackTarget.address);

        await expect(routerV2.connect(user0).instantWithdraw(expandDecimals(1, 15), true, false, { value: EXECUTION_FEE * 4})).to.be.reverted;
        await routerV2.connect(user0).instantWithdraw(expandDecimals(1,16), true, false, { value: EXECUTION_FEE * 4});

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 0, 2);

    })

    it('withdraws with nGlp for DAI (management)', async () => {
        await routerV2.setCallbackTargets(executionCallbackTarget.address, repayCallbackTarget.address);

        const balance = await nGlp.balanceOf(management.address);

        await routerV2.connect(management).instantWithdraw(balance, false, false, { value: EXECUTION_FEE * 4});
        
        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 2, 2);

        // console.log((await routerV2.pendingStatus())[4]);
        // expect((await routerV2.pendingStatus())[1]).eq(false);
        
        // const balanceAfter = await dai.balanceOf(management.address);
        // console.log(balanceAfter);
    })

    it('checks continuous execution', async() => {
        await routerV2.setCallbackTargets(executionCallbackTarget.address, repayCallbackTarget.address);

        const depositAmount = expandDecimals(500, 18);
        const withdrawAmount = expandDecimals(5000, 18);

        await dai.connect(user1).approve(routerV2.address, hre.ethers.constants.MaxUint256);
        await routerV2.connect(user1).instantDeposit(depositAmount, { value : EXECUTION_FEE * 2});

        await expect(routerV2.connect(user0).instantWithdraw(withdrawAmount, true, true, { value: EXECUTION_FEE * 4})).to.be.revertedWith("in the middle of progress");
        
        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 1, 2);
        await expect(routerV2.connect(user0).instantWithdraw(withdrawAmount, true, true, { value: EXECUTION_FEE * 4})).to.be.revertedWith("in the middle of progress");
        expect((await routerV2.pendingStatus())[4]).eq(true);

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 1, 2);

        expect((await routerV2.pendingStatus())[0]).eq(hre.ethers.constants.AddressZero);
        expect((await routerV2.pendingStatus())[1]).eq(false);
        expect((await routerV2.pendingStatus())[2]).eq(0);
        expect((await routerV2.pendingStatus())[3]).eq(0);
        expect(await routerV2.cumulativeMintAmount()).eq(0);

        await strategyVault.connect(deployer).approveToken(addr.GMX.StakedGlp, routerV2.address);
        await routerV2.connect(user0).instantWithdraw(withdrawAmount, true, true, { value: EXECUTION_FEE * 4});

        await expect(routerV2.connect(user1).instantDeposit(depositAmount, { value : EXECUTION_FEE * 2})).to.be.revertedWith("in the middle of progress");

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 2, 1);
        await expect(routerV2.connect(user1).instantDeposit(depositAmount, { value : EXECUTION_FEE * 2})).to.be.revertedWith("in the middle of progress");
        expect((await routerV2.pendingStatus())[4]).eq(true);

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 2, 1);

        expect((await routerV2.pendingStatus())[0]).eq(hre.ethers.constants.AddressZero);
        expect((await routerV2.pendingStatus())[1]).eq(false);
        expect((await routerV2.pendingStatus())[2]).eq(0);
        expect((await routerV2.pendingStatus())[3]).eq(0);
        expect(await routerV2.cumulativeMintAmount()).eq(0);
    })

    it('validates max global short size', async () => {
        const availableWbtcShortSize = BigInt(await gmxHelper.getAvailableShortSize(addr.WBTC));
        const availableWethShortSize = BigInt(await gmxHelper.getAvailableShortSize(addr.WETH));

        await routerV2.setCallbackTargets(executionCallbackTarget.address, repayCallbackTarget.address);
        await routerV2.setShortBuffers(availableWbtcShortSize, availableWethShortSize);

        await dai.connect(user1).approve(routerV2.address, hre.ethers.constants.MaxUint256);

        const depositAmount = expandDecimals(500, 18);

        await expect(routerV2.connect(user1).instantDeposit(depositAmount, { value : EXECUTION_FEE * 2})).to.be.revertedWith("OI limit exceeded");

        await routerV2.setShortBuffers(availableWbtcShortSize - expandDecimals(500, 30).toBigInt(), availableWethShortSize - expandDecimals(500, 30).toBigInt());

        await routerV2.connect(user1).instantDeposit(depositAmount, { value : EXECUTION_FEE * 2})
    })

})