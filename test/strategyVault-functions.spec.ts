import hre from 'hardhat';
import addr from '../shared/constants/addresses';
import { expect, use } from 'chai';
import { solidity } from 'ethereum-waffle';
import { EXECUTION_FEE } from '../shared/constants/constant';
import { gmxProtocolFixture } from './fixtures/gmx-protocol';
import { neutraProtocolFixture } from './fixtures/neutra-protocols';
import { expandDecimals, getPriceBits, increaseTime, mineBlock } from '../shared/utils';

use(solidity)

// only works for 50303054 block
const WBTC_PARAMS = "0x0000000000000000000000002f2a2543b76a4166549f7aab2e75bef0aefc5b0f0000000000000000000000000000000000000000000001ef569ffe8fd645956a000000000000000000000000000000000009a3a2bb59c8e41401f34640949cc3"
const WETH_PARAMS = "0x00000000000000000000000082af49447d8a07e3bd95bd0d56f35241523fbab100000000000000000000000000000000000000000000031cb71f1c045b2f6fae00000000000000000000000000000000000f8101c25fe85e411d5afeaa1e029b"
const DEAL_AMOUNT = "276165816117100427279080";

describe('strategy-vault-test', () => {
    let nGlp;
    let esNEU;
    let feeNeuGlpTracker;
    let stakedNeuGlpTracker;
    let positionRouter;
    let fastPriceFeed;
    let keeper;
    let batchRouter;
    let dai;
    let deployer;
    let user0;
    let user1;
    let gmxVault;
    let strategyVault;
    let router;
    let gmxHelper

    let whale;

    let wbtcPrice;
    let wethPrice;
    let uniPrice;
    let linkPrice;
    
    before(async() => {
        ({nGlp, esNEU, feeNeuGlpTracker, stakedNeuGlpTracker, batchRouter, strategyVault, router, gmxHelper} = await neutraProtocolFixture());
        ({dai, keeper, positionRouter, fastPriceFeed, gmxVault } = await gmxProtocolFixture());
        [deployer, user0, user1] = await hre.ethers.getSigners();
        whale = await hre.ethers.getImpersonatedSigner(addr.DAI_WHALE);
        await dai.connect(whale).transfer(deployer.address, expandDecimals(3000, 18));

        await batchRouter.setSale(true, true);

        await dai.approve(strategyVault.address, hre.ethers.constants.MaxUint256);
        await strategyVault.depositInsuranceFund(expandDecimals(3000, 18));

        wbtcPrice = (await gmxVault.getMinPrice(addr.WBTC)).toString();
        wethPrice = (await gmxVault.getMinPrice(addr.WETH)).toString();
        linkPrice = (await gmxVault.getMinPrice(addr.LINK)).toString();
        uniPrice = (await gmxVault.getMinPrice(addr.UNI)).toString();

        await dai.connect(whale).approve(batchRouter.address, hre.ethers.constants.MaxUint256);
        await batchRouter.connect(whale).reserveDeposit(expandDecimals(300000, 18));
        await batchRouter.executeBatchPositions(false, [WBTC_PARAMS, WETH_PARAMS], DEAL_AMOUNT, {value :EXECUTION_FEE *2});

        const prices = [
            wbtcPrice.substring(0,wbtcPrice.length-27), 
            wethPrice.substring(0, wethPrice.length-27), 
            linkPrice.substring(0, linkPrice.length-27), 
            uniPrice.substring(0, uniPrice.length-27)
        ];

        const blockNum = await hre.ethers.provider.getBlockNumber();
        const block = await hre.ethers.provider.getBlock(blockNum);
        const timestamp = block.timestamp;

        const increaseIndex = await positionRouter.increasePositionRequestKeysStart();
        const decreaseIndex = await positionRouter.decreasePositionRequestKeysStart();

        const priceBits =  getPriceBits(prices);

        await fastPriceFeed.connect(keeper).setPricesWithBitsAndExecute(
            priceBits,
            timestamp,
            increaseIndex +5,
            decreaseIndex +5,
            5,
            5
        );
        
        await batchRouter.confirmAndDealGlp();
        
        await batchRouter.connect(whale).claimStakedNeuGlp();
    })

    it('checks prepaidGmxFee increasement', async() => {
        expect(await gmxHelper.getFundingFee(strategyVault.address, addr.WBTC)).eq(0);
        expect(await gmxHelper.getFundingFee(strategyVault.address, addr.WETH)).eq(0);

        increaseTime(hre.ethers.provider, 60 * 60 * 24);
        mineBlock(hre.ethers.provider);

        await gmxVault.updateCumulativeFundingRate(addr.DAI);

        let wbtcFundingFee = await gmxHelper.getFundingFee(strategyVault.address, addr.WBTC);
        let wethFundingFee = await gmxHelper.getFundingFee(strategyVault.address, addr.WETH);

        await strategyVault.repayFundingFee({value: EXECUTION_FEE * 2});

        expect(await strategyVault.prepaidGmxFee()).gte((wbtcFundingFee.toBigInt() + wethFundingFee.toBigInt()) / (expandDecimals(1,12)).toBigInt())
        
    })

    it('checks harvest calculation', async() => {
        await strategyVault.harvest();
        let feeReserves = await strategyVault.feeReserves();
        let prepaidGmxFee = await strategyVault.prepaidGmxFee();

        await strategyVault.withdrawFees(deployer.address);
        expect(await strategyVault.prepaidGmxFee()).eq(0);
        expect(await strategyVault.feeReserves()).eq(0);

        expect(await dai.balanceOf(deployer.address)).gte(feeReserves.toBigInt() - prepaidGmxFee.toBigInt());
    })

    it('checks exitStrategy function', async() => {
        await strategyVault.exitStrategy({value: EXECUTION_FEE * 2});
        let balance = await stakedNeuGlpTracker.balanceOf(whale.address);
        await router.connect(whale).settle(balance);
        expect(await nGlp.totalSupply()).eq(0);
    })
})
