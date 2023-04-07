import hre from "hardhat"
import addr from "../shared/constants/addresses"
import { expect, use } from "chai"
import { solidity } from "ethereum-waffle"
import { deployContract, expandDecimals, getPriceBits } from "../shared/utils"
import { gmxProtocolFixture } from "./fixtures/gmx-protocol"
import { EXECUTION_FEE } from "../shared/constants/constant"
import { gmxHelperConfig } from "./fixtures/neutra-protocols"
import { executePositionsWithBits } from "./helper/utils"

use(solidity)

describe("nGlpVaultReader implementation", () => {
  let deployer
  let management

  let strategyVault
  let gmxHelper
  let batchRouter
  let nGlp
  let fnGlp
  let snGlp
  let routerV2
  let dai

  let repayCallbackTarget
  let executionCallbackTarget

  let user0 // withdrawer snGlp
  let user1 // depositer dai
  let user2 // depositer fsGlp

  // gmx contracts
  let fastPriceFeed
  let positionRouter
  let gmxVault
  let glpManager
  let shortsTracker
  let fsGlp
  let stakedGlp

  let gmxAdmin
  let keeper
  let priceBits

  let nGlpVaultReader

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
    addr.WETH,
  ]

  beforeEach(async () => {
    ({ keeper, gmxVault, positionRouter, fastPriceFeed, dai, glpManager, shortsTracker, fsGlp, stakedGlp } =
      await gmxProtocolFixture());
    deployer = await hre.ethers.getImpersonatedSigner(addr.DEPLOYER)
    management = await hre.ethers.getImpersonatedSigner(addr.NEUTRA.management)

    const StrategyVault = await hre.ethers.getContractFactory("StrategyVault", deployer)
    strategyVault = await hre.upgrades.forceImport(addr.NEUTRA.StrategyVault, StrategyVault, { kind: "uups" })
    const StrategyVaultV2 = await hre.ethers.getContractFactory(
      "contracts/StrategyVaultV2.sol:StrategyVaultV2",
      deployer
    )
    strategyVault = await hre.upgrades.upgradeProxy(strategyVault, StrategyVaultV2)

    gmxHelper = await deployContract("GmxHelper", [gmxHelperConfig, addr.NEUTRA.nGlp, addr.DAI, addr.WBTC, addr.WETH])
    batchRouter = await hre.ethers.getContractAt("BatchRouter", addr.NEUTRA.BatchRouter)
    nGlp = await hre.ethers.getContractAt("nGLP", addr.NEUTRA.nGlp)
    fnGlp = await hre.ethers.getContractAt("FeeNeuGlpTracker", addr.NEUTRA.fnGlp)
    snGlp = await hre.ethers.getContractAt("StakedNeuGlpTracker", addr.NEUTRA.snGlp)

    routerInitialConfig[9] = gmxHelper.address
    routerV2 = await deployContract("RouterV2", [routerInitialConfig])

    let nGlpVaultReaderConfig = [
      addr.GMX.Vault,
      addr.GMX.PositionRouter,
      addr.GMX.GlpManager,
      routerV2.address,
      gmxHelper.address,
      addr.NEUTRA.StrategyVault,
      addr.DAI,
      addr.WBTC,
      addr.WETH,
      addr.GMX.glp,
      addr.GMX.fsGlp,
      addr.NEUTRA.nGlp,
    ]
    nGlpVaultReader = await deployContract("NeutraGlpVaultReader", [nGlpVaultReaderConfig])

    await nGlp.connect(deployer).setHandlers([routerV2.address], [true])
    await nGlp.connect(deployer).setMinter(routerV2.address, true)

    await fnGlp.connect(deployer).setHandlers([routerV2.address], [true])

    await snGlp.connect(deployer).setHandlers([routerV2.address], [true])

    await strategyVault.connect(deployer).setRouter(routerV2.address, true)

    repayCallbackTarget = await deployContract("RepayCallbackTarget", [routerV2.address, addr.GMX.PositionRouter])
    executionCallbackTarget = await deployContract("ExecutionCallbackTarget", [routerV2.address, addr.GMX.PositionRouter])

    user0 = await hre.ethers.getImpersonatedSigner(addr.SNGLP_WAHLE)
    user1 = await hre.ethers.getImpersonatedSigner(addr.DAI_WHALE)
    user2 = await hre.ethers.getImpersonatedSigner(addr.FSGLP_WHALE)

    // gmx price
    const wbtcPrice = (await gmxVault.getMinPrice(addr.WBTC)).toString()
    const wethPrice = (await gmxVault.getMinPrice(addr.WETH)).toString()
    const linkPrice = (await gmxVault.getMinPrice(addr.LINK)).toString()
    const uniPrice = (await gmxVault.getMinPrice(addr.UNI)).toString()

    const prices = [
      wbtcPrice.substring(0, wbtcPrice.length - 27),
      wethPrice.substring(0, wethPrice.length - 27),
      linkPrice.substring(0, linkPrice.length - 27),
      uniPrice.substring(0, uniPrice.length - 27),
    ]

    priceBits = getPriceBits(prices)
  })

  it("nGlpVaultReader depositWantFee test", async () => {
    let num = 100
    let amountIn = expandDecimals(num, 18)
    let totalValue = BigInt(await gmxHelper.totalValue(addr.NEUTRA.StrategyVault))
    let nGlpTotalSupply = BigInt(await nGlp.totalSupply())
    let nGlpPrice =
      Number((totalValue * BigInt("1000000000000000000")) / nGlpTotalSupply) / Number(expandDecimals(1, 30))

    let glpPrice = Number(await nGlpVaultReader.glpPrice(false)) / Number(expandDecimals(1, 30))

    let depositWantInfo = await nGlpVaultReader.getWantDepositMintAndFee(amountIn)
    let mintAmount = Number(depositWantInfo[0]) / Number(expandDecimals(1, 18))
    let glpFeeUsd = Number(depositWantInfo[1]) / Number(expandDecimals(1, 30))
    let positionFee = Number(depositWantInfo[2]) / Number(expandDecimals(1, 30))

    let outTotal = mintAmount * nGlpPrice + glpFeeUsd + positionFee

    expect(num).gte((outTotal * 9999) / 10000)
    expect(num).lte((outTotal * 10001) / 10000)
  })

  it("nGlpVaultReader depositGlpFee test", async () => {
    let num = 100
    let amountIn = expandDecimals(num, 18)
    let totalValue = BigInt(await gmxHelper.totalValue(addr.NEUTRA.StrategyVault))
    let nGlpTotalSupply = BigInt(await nGlp.totalSupply())
    let nGlpPrice =
      Number((totalValue * BigInt("1000000000000000000")) / nGlpTotalSupply) / Number(expandDecimals(1, 30))

    let glpPrice = Number(await nGlpVaultReader.glpPrice(false)) / Number(expandDecimals(1, 30))

    let depositGlpInfo = await nGlpVaultReader.getGlpDepositMintAndFee(amountIn)
    let mintAmount = Number(depositGlpInfo[0]) / Number(expandDecimals(1, 18))
    let glpFeeUsd = Number(depositGlpInfo[1]) / Number(expandDecimals(1, 30))
    let positionFee = Number(depositGlpInfo[2]) / Number(expandDecimals(1, 30))

    let outTotal = mintAmount * nGlpPrice + glpFeeUsd + positionFee

    expect(num * glpPrice).gte((outTotal * 9999) / 10000)
    expect(num * glpPrice).lte((outTotal * 10001) / 10000)
  })

  it("nGlpVaultReader withdrawWantFee test", async () => {
    let num = 100
    let amountIn = expandDecimals(num, 18)
    let totalValue = BigInt(await gmxHelper.totalValue(addr.NEUTRA.StrategyVault))
    let nGlpTotalSupply = BigInt(await nGlp.totalSupply())
    let nGlpPrice =
      Number((totalValue * BigInt("1000000000000000000")) / nGlpTotalSupply) / Number(expandDecimals(1, 30))

    let glpPrice = Number(await nGlpVaultReader.glpPrice(false)) / Number(expandDecimals(1, 30))

    let withdrawWantInfo = await nGlpVaultReader.getWithdrawWantOutAndFee(amountIn)
    let wantOut = Number(withdrawWantInfo[0]) / Number(expandDecimals(1, 18))
    let glpFeeUsd = Number(withdrawWantInfo[1]) / Number(expandDecimals(1, 30))
    let positionFee = Number(withdrawWantInfo[2]) / Number(expandDecimals(1, 30))

    let outTotal = wantOut + glpFeeUsd + positionFee

    expect(num * nGlpPrice).gte((outTotal * 9999) / 10000)
    expect(num * nGlpPrice).lte((outTotal * 10001) / 10000)
  })

  it("nGlpVaultReader Test", async () => {
    let capList = await nGlpVaultReader.getCaps()
    console.log("BuyWantCap:", Number(capList[0]) / Number(expandDecimals(1, 18)))
    console.log("BuyGlpCap:", Number(capList[1]) / Number(expandDecimals(1, 18)))
    console.log("SellWantCap:", Number(capList[2]) / Number(expandDecimals(1, 18)))
  })
})
