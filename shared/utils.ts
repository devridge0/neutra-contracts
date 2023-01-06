import { ethers } from "hardhat";
import { BN } from "bn.js";

async function deployContract(name, args) {
    const contractFactory = await ethers.getContractFactory(name)
    return await contractFactory.deploy(...args)
}

function bigNumberify(n) {
    return ethers.BigNumber.from(n)
}

function expandDecimals(n, decimals) {
    return bigNumberify(n).mul(bigNumberify(10).pow(decimals))
}

function getPriceBits(prices) {
    if (prices.length > 8) {
      throw new Error("max prices.length exceeded")
    }
  
    let priceBits = new BN('0')
  
    for (let j = 0; j < 8; j++) {
      let index = j
      if (index >= prices.length) {
        break
      }
  
      const price = new BN(prices[index])
      if (price.gt(new BN("2147483648"))) { // 2^31
        throw new Error(`price exceeds bit limit ${price.toString()}`)
      }
  
      priceBits = priceBits.or(price.shln(j * 32))
    }
  
    return priceBits.toString()
}

function getExpandedPrice(price, precision) {
    return bigNumberify(price).mul(expandDecimals(1, 30)).div(precision)
}

async function getBlockTime(provider) {
    const blockNumber = await provider.getBlockNumber()
    const block = await provider.getBlock(blockNumber)
    return block.timestamp
}

function toUsd(value : number) {
    const normalizedValue = Math.floor(value * Math.pow(10, 10))
    return ethers.BigNumber.from(normalizedValue).mul(ethers.BigNumber.from(10).pow(20))
}

async function send(provider, method, params = []) {
    await provider.send(method, params)
}
  
async function mineBlock(provider) {
    await send(provider, "evm_mine")
}
  
async function increaseTime(provider, seconds) {
    await send(provider, "evm_increaseTime", [seconds])
}


async function priceUpdateAndExcute(provider, positionRouter, fastPriceFeed, keeper, wethPrice, wbtcPrice, opPrice, usdcPrice) {
    let blockTime = await getBlockTime(provider);

    let priceBits = getPriceBits([wethPrice, wbtcPrice, opPrice, usdcPrice]);

    let requestQue = await positionRouter.getRequestQueueLengths();
    // console.log(requestQue[1]);
    await fastPriceFeed.connect(keeper).setPricesWithBitsAndExecute(priceBits, blockTime, 0,requestQue[3]);
    await fastPriceFeed.connect(keeper).setPricesWithBitsAndExecute(priceBits, blockTime, requestQue[1],0);
}

function encode(types: string[], params: string[]) {
    const iface = new ethers.utils.AbiCoder();
    const bytes = iface.encode(types, params);
    return bytes;
}

export { deployContract, expandDecimals, bigNumberify, getPriceBits, getExpandedPrice, getBlockTime, toUsd, mineBlock, increaseTime, priceUpdateAndExcute, encode}