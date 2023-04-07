import hre from 'hardhat';
import addr from '../shared/constants/addresses';
import { expect, use } from 'chai';
import { solidity } from 'ethereum-waffle';
import { EXECUTION_FEE } from '../shared/constants/constant';
import { gmxProtocolFixture } from './fixtures/gmx-protocol';
import { deployContract, expandDecimals, getPriceBits } from '../shared/utils';
import { executePositionsWithBits } from './helper/utils';

use(solidity)

describe('gmx-keeper-test', () => {
    let fastPriceFeed;
    let positionRouter;
    let gmxRouter;
    let dai;
    let keeper;
    let gmxVault;

    let priceBits;

    before(async() => {
        ({fastPriceFeed, positionRouter, gmxRouter,gmxVault, dai, keeper} = await gmxProtocolFixture());

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
        
    })

    it('opens and executes positions', async () => {
        const whale = await hre.ethers.getImpersonatedSigner(addr.DAI_WHALE);
        await dai.connect(whale).approve(gmxRouter.address, hre.ethers.constants.MaxUint256);
        await gmxRouter.connect(whale).approvePlugin(positionRouter.address);

        await positionRouter.connect(whale).createIncreasePosition(
            [addr.DAI],
            addr.WBTC,
            expandDecimals(1000, 18),
            0,
            expandDecimals(2000, 30),
            false,
            0,
            EXECUTION_FEE,
            hre.ethers.constants.HashZero,
            hre.ethers.constants.AddressZero,
            {
                value: EXECUTION_FEE
            }
        )

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 5, 5);

        const position = await gmxVault.getPosition(whale.address, addr.DAI, addr.WBTC, false);
        expect(position[0]).eq(expandDecimals(2000, 30));
    })

    it('opens 0 sizeDelta, 0 amountIn position', async () => {
        const whale = await hre.ethers.getImpersonatedSigner(addr.DAI_WHALE);
        await positionRouter.connect(whale).createIncreasePosition(
            [addr.DAI],
            addr.WBTC,
            0,
            0,
            0,
            false,
            0,
            EXECUTION_FEE,
            hre.ethers.constants.HashZero,
            hre.ethers.constants.AddressZero,
            {
                value: EXECUTION_FEE
            }
        )

        await executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, 5, 5);

        const position = await gmxVault.getPosition(whale.address, addr.DAI, addr.WBTC, false);
        expect(position[0]).eq(expandDecimals(2000, 30));
    })
})