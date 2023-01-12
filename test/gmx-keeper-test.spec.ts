import hre from 'hardhat';
import addr from '../shared/constants/addresses';
import { expect, use } from 'chai';
import { solidity } from 'ethereum-waffle';
import { EXECUTION_FEE } from '../shared/constants/constant';
import { gmxProtocolFixture } from './fixtures/gmx-protocol';
import { deployContract, expandDecimals } from '../shared/utils';

use(solidity)

describe('gmx-keeper-test', () => {
    let fastPriceFeed;
    let positionRouter;
    let gmxRouter;
    let dai;
    let keeper;
    let gmxVault;

    before(async() => {
        ({fastPriceFeed, positionRouter, gmxRouter,gmxVault, dai, keeper} = await gmxProtocolFixture());
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

        const increaseIndex = await positionRouter.increasePositionRequestKeysStart();
        const decreaseIndex = await positionRouter.decreasePositionRequestKeysStart();

        const blockNum = await hre.ethers.provider.getBlockNumber();
        const block = await hre.ethers.provider.getBlock(blockNum);
        const timestamp = block.timestamp;
        
        await fastPriceFeed.connect(keeper).setPricesWithBitsAndExecute(
            "0x14b6000016430012973300ff6478",
            timestamp,
            increaseIndex + 5,
            decreaseIndex + 5,
            1,
            10000
        )

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

        const increaseIndex = await positionRouter.increasePositionRequestKeysStart();
        const decreaseIndex = await positionRouter.decreasePositionRequestKeysStart();
        
        const blockNum = await hre.ethers.provider.getBlockNumber();
        const block = await hre.ethers.provider.getBlock(blockNum);
        const timestamp = block.timestamp;

        await fastPriceFeed.connect(keeper).setPricesWithBitsAndExecute(
            "0x14b6000016430012973300ff6478",
            timestamp,
            increaseIndex + 5,
            decreaseIndex + 5,
            1,
            10000
        )
        const position = await gmxVault.getPosition(whale.address, addr.DAI, addr.WBTC, false);
        expect(position[0]).eq(expandDecimals(2000, 30));


    })
})