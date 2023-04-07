import hre from 'hardhat'

export async function executePositionsWithBits(positionRouter, fastPriceFeed, keeper, priceBits, increaseCount, decreaseCount) {
    const blockNum = await hre.ethers.provider.getBlockNumber();
    const blcok = await hre.ethers.provider.getBlock(blockNum);
    const timestamp = blcok.timestamp;

    const increaseIndex = BigInt(await positionRouter.increasePositionRequestKeysStart());
    const decreaseIndex = BigInt(await positionRouter.decreasePositionRequestKeysStart());

    await fastPriceFeed.connect(keeper).setPricesWithBitsAndExecute(
        priceBits,
        timestamp,
        increaseIndex + BigInt(increaseCount),
        decreaseIndex + BigInt(decreaseCount),
        2000,
        5,
        {gasLimit : 10000000}
    );

}