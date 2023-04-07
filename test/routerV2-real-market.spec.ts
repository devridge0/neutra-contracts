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

describe('routerV2 real market', () => {

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
    let curPrices;

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

        curPrices = prices.map(str => Number(str));
        const gmxAdmin = await hre.ethers.getImpersonatedSigner("0xB4d2603B2494103C90B2c607261DD85484b49eF0");
        await routerV2.setCallbackTargets(executionCallbackTarget.address, repayCallbackTarget.address);
        // await positionRouter.connect(gmxAdmin).setCallbackGasLimit(7000000);
    })

    afterEach(async ()=> {
        expect((await routerV2.pendingStatus())[0]).eq(hre.ethers.constants.AddressZero);
        expect((await routerV2.pendingStatus())[1]).eq(false);
        expect((await routerV2.pendingStatus())[2]).eq(0);
        expect((await routerV2.pendingStatus())[3]).eq(0);
    })

    it('deposit / price with + 0.05% deviation', async () => {
        // wbtc
        curPrices[0] = curPrices[0] * 1.0005;
        // weth
        curPrices[1] = curPrices[1] * 1.0005;

        const priceBits = getPriceBits(curPrices);

        const depositAmount = expandDecimals(100, 18);

        console.log(`input Amount : ${depositAmount} fsGlp`);

        const snGlpBefore = (await snGlp.balanceOf(user2.address)).toBigInt();

        await stakedGlp.connect(user2).approve(routerV2.address, hre.ethers.constants.MaxUint256);
        await routerV2.connect(user2).instantDepositGlp(depositAmount, { value: EXECUTION_FEE * 2});

        await executePositionsWithBits(positionRouter, fastPriceFeed,keeper, priceBits, 2, 2);

        const snGlpAfter = BigInt(await snGlp.balanceOf(user2.address));
        console.log(`minted share : ${(snGlpAfter - snGlpBefore).toString()} snGlp`)
    })

    it('deposit / price with + 0.1% deviation', async() => {
        //wbtc 
        curPrices[0] = curPrices[0] * 1.001;
        //weth
        curPrices[1] = curPrices[1] * 1.001;

        const priceBits = getPriceBits(curPrices);
        const depositAmount = expandDecimals(100, 18);

        console.log(`input Amount : ${depositAmount} fsGlp`);

        const snGlpBefore = (await snGlp.balanceOf(user2.address)).toBigInt();

        await stakedGlp.connect(user2).approve(routerV2.address, hre.ethers.constants.MaxUint256);
        await routerV2.connect(user2).instantDepositGlp(depositAmount, { value: EXECUTION_FEE * 2});

        await executePositionsWithBits(positionRouter, fastPriceFeed,keeper, priceBits, 2, 2);

        const snGlpAfter = BigInt(await snGlp.balanceOf(user2.address));
        console.log(`minted share : ${(snGlpAfter - snGlpBefore).toString()} snGlp`)
    })

    it('deposit / price with + 0.5% deviation', async() => {
        //wbtc 
        curPrices[0] = curPrices[0] * 1.005;
        //weth
        curPrices[1] = curPrices[1] * 1.005;

        const priceBits = getPriceBits(curPrices);
        const depositAmount = expandDecimals(100, 18);

        console.log(`input Amount : ${depositAmount} fsGlp`);

        const snGlpBefore = (await snGlp.balanceOf(user2.address)).toBigInt();

        await stakedGlp.connect(user2).approve(routerV2.address, hre.ethers.constants.MaxUint256);
        await routerV2.connect(user2).instantDepositGlp(depositAmount, { value: EXECUTION_FEE * 2});

        await executePositionsWithBits(positionRouter, fastPriceFeed,keeper, priceBits, 2, 2);

        const snGlpAfter = BigInt(await snGlp.balanceOf(user2.address));
        console.log(`minted share : ${(snGlpAfter - snGlpBefore).toString()} snGlp`)
    })

    it('deposit / price with + 1% deviation', async() => {
        //wbtc 
        curPrices[0] = curPrices[0] * 1.01;
        //weth
        curPrices[1] = curPrices[1] * 1.01;

        const priceBits = getPriceBits(curPrices);
        const depositAmount = expandDecimals(100, 18);

        console.log(`input Amount : ${depositAmount} fsGlp`);

        const snGlpBefore = (await snGlp.balanceOf(user2.address)).toBigInt();

        await stakedGlp.connect(user2).approve(routerV2.address, hre.ethers.constants.MaxUint256);
        await routerV2.connect(user2).instantDepositGlp(depositAmount, { value: EXECUTION_FEE * 2});

        await executePositionsWithBits(positionRouter, fastPriceFeed,keeper, priceBits, 2, 2);

        const snGlpAfter = BigInt(await snGlp.balanceOf(user2.address));
        console.log(`minted share : ${(snGlpAfter - snGlpBefore).toString()} snGlp`)
        
    })

    it('deposit / price with - 1% deviation', async() => {
        //wbtc 
        curPrices[0] = curPrices[0] * 0.99;
        //weth
        curPrices[1] = curPrices[1] * 0.99;

        const priceBits = getPriceBits(curPrices);
        const depositAmount = expandDecimals(100, 18);

        console.log(`input Amount : ${depositAmount} fsGlp`);

        const snGlpBefore = (await snGlp.balanceOf(user2.address)).toBigInt();

        await stakedGlp.connect(user2).approve(routerV2.address, hre.ethers.constants.MaxUint256);
        await routerV2.connect(user2).instantDepositGlp(depositAmount, { value: EXECUTION_FEE * 2});

        await executePositionsWithBits(positionRouter, fastPriceFeed,keeper, priceBits, 2, 2);

        const snGlpAfter = BigInt(await snGlp.balanceOf(user2.address));
        console.log(`minted share : ${(snGlpAfter - snGlpBefore).toString()} snGlp`)
    })

    it('deposit / price with + 2.5% deviation', async() => {
        //wbtc 
        curPrices[0] = curPrices[0] * 1.025;
        //weth
        curPrices[1] = curPrices[1] * 1.025;

        const priceBits = getPriceBits(curPrices);
        const depositAmount = expandDecimals(100, 18);

        console.log(`input Amount : ${depositAmount} fsGlp`);

        const snGlpBefore = (await snGlp.balanceOf(user2.address)).toBigInt();

        await stakedGlp.connect(user2).approve(routerV2.address, hre.ethers.constants.MaxUint256);
        await routerV2.connect(user2).instantDepositGlp(depositAmount, { value: EXECUTION_FEE * 2});

        await executePositionsWithBits(positionRouter, fastPriceFeed,keeper, priceBits, 2, 2);

        const snGlpAfter = BigInt(await snGlp.balanceOf(user2.address));
        console.log(`minted share : ${(snGlpAfter - snGlpBefore).toString()} snGlp`)
    })

    it('deposit / price with - 2.5% deviation', async() => {
        //wbtc 
        curPrices[0] = curPrices[0] * 0.975;
        //weth
        curPrices[1] = curPrices[1] * 0.975;

        const priceBits = getPriceBits(curPrices);
        const depositAmount = expandDecimals(100, 18);

        console.log(`input Amount : ${depositAmount} fsGlp`);

        const snGlpBefore = (await snGlp.balanceOf(user2.address)).toBigInt();

        await stakedGlp.connect(user2).approve(routerV2.address, hre.ethers.constants.MaxUint256);
        await routerV2.connect(user2).instantDepositGlp(depositAmount, { value: EXECUTION_FEE * 2});

        await executePositionsWithBits(positionRouter, fastPriceFeed,keeper, priceBits, 2, 2);

        const snGlpAfter = BigInt(await snGlp.balanceOf(user2.address));
        console.log(`minted share : ${(snGlpAfter - snGlpBefore).toString()} snGlp`)
    })

    it('withdraw / price with + 0.05% deviation', async() => {
        // wbtc
        curPrices[0] = curPrices[0] * 1.0005;
        // weth
        curPrices[1] = curPrices[1] * 1.0005;

        const priceBits = getPriceBits(curPrices);
        const withdrawalAmount = expandDecimals(100, 18);

        console.log(`withdrawal input : ${withdrawalAmount} snGlp`);

        const daiBefore = (await dai.balanceOf(user0.address)).toBigInt();
        
        await routerV2.connect(user0).instantWithdraw(withdrawalAmount, true, false, { value: EXECUTION_FEE * 4})

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 2, 2);

        const daiAfter = (await dai.balanceOf(user0.address)).toBigInt();
        console.log(`redeemed amount : ${daiAfter - daiBefore} DAI`);    
    })

    it('withdraw / price with + 0.1% deviation', async() => {
        // wbtc
        curPrices[0] = curPrices[0] * 1.001;
        // weth
        curPrices[1] = curPrices[1] * 1.001;

        const priceBits = getPriceBits(curPrices);
        const withdrawalAmount = expandDecimals(100, 18);

        console.log(`withdrawal input : ${withdrawalAmount} snGlp`);

        const daiBefore = (await dai.balanceOf(user0.address)).toBigInt();
        
        await routerV2.connect(user0).instantWithdraw(withdrawalAmount, true, false, { value: EXECUTION_FEE * 4})

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 2, 2);

        const daiAfter = (await dai.balanceOf(user0.address)).toBigInt();
        console.log(`redeemed amount : ${daiAfter - daiBefore} DAI`);    
    })

    it('withdraw / price with + 0.5% deviation', async() => {
        // wbtc
        curPrices[0] = curPrices[0] * 1.005;
        // weth
        curPrices[1] = curPrices[1] * 1.005;

        const priceBits = getPriceBits(curPrices);
        const withdrawalAmount = expandDecimals(100, 18);

        console.log(`withdrawal input : ${withdrawalAmount} snGlp`);

        const daiBefore = (await dai.balanceOf(user0.address)).toBigInt();
        
        await routerV2.connect(user0).instantWithdraw(withdrawalAmount, true, false, { value: EXECUTION_FEE * 4})

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 2, 2);

        const daiAfter = (await dai.balanceOf(user0.address)).toBigInt();
        console.log(`redeemed amount : ${daiAfter - daiBefore} DAI`);    

    })

    it('withdraw / price with + 1% deviation', async() => {
        // wbtc
        curPrices[0] = curPrices[0] * 1.01;
        // weth
        curPrices[1] = curPrices[1] * 1.01;

        const priceBits = getPriceBits(curPrices);
        const withdrawalAmount = expandDecimals(100, 18);

        console.log(`withdrawal input : ${withdrawalAmount} snGlp`);

        const daiBefore = (await dai.balanceOf(user0.address)).toBigInt();
        
        await routerV2.connect(user0).instantWithdraw(withdrawalAmount, true, false, { value: EXECUTION_FEE * 4})

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 2, 2);

        const daiAfter = (await dai.balanceOf(user0.address)).toBigInt();
        console.log(`redeemed amount : ${daiAfter - daiBefore} DAI`);   

    })

    it('withdraw / price with - 1% deviation', async() => {
        // wbtc
        curPrices[0] = curPrices[0] * 0.99;
        // weth
        curPrices[1] = curPrices[1] * 0.99;

        const priceBits = getPriceBits(curPrices);
        const withdrawalAmount = expandDecimals(100, 18);

        console.log(`withdrawal input : ${withdrawalAmount} snGlp`);

        const daiBefore = (await dai.balanceOf(user0.address)).toBigInt();
        
        await routerV2.connect(user0).instantWithdraw(withdrawalAmount, true, false, { value: EXECUTION_FEE * 4})

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 2, 2);

        const daiAfter = (await dai.balanceOf(user0.address)).toBigInt();
        console.log(`redeemed amount : ${daiAfter - daiBefore} DAI`);    
    })

    it('withdraw / price with - 2.5% deviation', async() => {
        // wbtc
        curPrices[0] = curPrices[0] * 0.975;
        // weth
        curPrices[1] = curPrices[1] * 0.975;

        const priceBits = getPriceBits(curPrices);
        const withdrawalAmount = expandDecimals(100, 18);

        console.log(`withdrawal input : ${withdrawalAmount} snGlp`);

        const daiBefore = (await dai.balanceOf(user0.address)).toBigInt();
        
        await routerV2.connect(user0).instantWithdraw(withdrawalAmount, true, false, { value: EXECUTION_FEE * 4})

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 2, 2);

        const daiAfter = (await dai.balanceOf(user0.address)).toBigInt();
        console.log(`redeemed amount : ${daiAfter - daiBefore} DAI`);    
    })

    it('withdraw / price with + 2.5% deviation', async() => {
        // wbtc
        curPrices[0] = curPrices[0] * 1.025;
        // weth
        curPrices[1] = curPrices[1] * 1.025;

        const priceBits = getPriceBits(curPrices);
        const withdrawalAmount = expandDecimals(100, 18);

        console.log(`withdrawal input : ${withdrawalAmount} snGlp`);

        const daiBefore = (await dai.balanceOf(user0.address)).toBigInt();
        
        await routerV2.connect(user0).instantWithdraw(withdrawalAmount, true, false, { value: EXECUTION_FEE * 4})

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 2, 2);

        const daiAfter = (await dai.balanceOf(user0.address)).toBigInt();
        console.log(`redeemed amount : ${daiAfter - daiBefore} DAI`); 
    })


})