import * as dotenv from "dotenv";
import hre from "hardhat";
import addr from "../shared/constants/addresses";
import { expandDecimals } from "../shared/utils";

dotenv.config();

const gmxHelperConfig = [
    addr.GMX.Vault,
    addr.GMX.glp,
    addr.GMX.fsGlp,
    addr.GMX.GlpManager,
    addr.GMX.usdg
]

const strategyVaultConfig = [
    addr.GMX.GlpManager,
    addr.GMX.PositionRouter,
    addr.GMX.RewardRouter,
    addr.GMX.GlpRewardRouter,
    addr.GMX.Router,
    addr.GMX.ReferralStorage,
    addr.GMX.fsGlp,
    addr.GMX.gmx,
    addr.GMX.sGmx,

    addr.DAI,
    addr.WBTC,
    addr.WETH,
]

async function main() {
    // 0. NEU
    const NEU = await hre.ethers.getContractFactory("NEU");
    const neu = await NEU.deploy();
    await neu.deployed();
    console.log(`neu address : ${neu.address}`);

    // 1. nGLP
    const NeuGlp = await hre.ethers.getContractFactory("nGLP");
    const nGlp = await NeuGlp.deploy();
    await nGlp.deployed();
    console.log(`nGlp address : ${nGlp.address}`);

    // 2. esNEU
    const EsNEU = await hre.ethers.getContractFactory("EsNEU");
    const esNEU = await EsNEU.deploy();
    await esNEU.deployed();
    console.log(`esNEU address : ${esNEU.address}`);

    // 3. bnNEU
    const BnNEU = await hre.ethers.getContractFactory("BnNEU");
    const bnNEU = await BnNEU.deploy();
    await bnNEU.deployed();
    console.log(`bnNEU address : ${bnNEU.address}`);

    // 4. RewardRouter
    const RewardRouter = await hre.ethers.getContractFactory("RewardRouter");
    const rewardRouter = await RewardRouter.deploy();
    await rewardRouter.deployed();
    console.log(`rewardRouter address : ${rewardRouter.address}`);

    // 5. BonusNeuTracker
    const BonusNeuTracker = await hre.ethers.getContractFactory("BonusNeuTracker");
    const bonusNeuTracker = await BonusNeuTracker.deploy();
    await bonusNeuTracker.deployed();
    console.log(`bonusNeuTracker address : ${bonusNeuTracker.address}`);

    // 6. FeeNeuTracker
    const FeeNeuTracker = await hre.ethers.getContractFactory("FeeNeuTracker");
    const feeNeuTracker = await FeeNeuTracker.deploy();
    await feeNeuTracker.deployed();
    console.log(`feeNeuTracker address : ${feeNeuTracker.address}`);

    // 7. FeeNeuGlpTracker
    const FeeNeuGlpTracker = await hre.ethers.getContractFactory("FeeNeuGlpTracker");
    const feeNeuGlpTracker = await FeeNeuGlpTracker.deploy();
    await feeNeuGlpTracker.deployed();
    console.log(`fnGlp address : ${feeNeuGlpTracker.address}`);

    // 8. StakedNeuTracker
    const StakedNeuTracker = await hre.ethers.getContractFactory("StakedNeuTracker");
    const stakedNeuTracker = await StakedNeuTracker.deploy();
    await stakedNeuTracker.deployed();
    console.log(`stakedNeuTracker address : ${stakedNeuTracker.address}`);

    // 9. StakedNeuGlpTracker
    const StakedNeuGlpTracker = await hre.ethers.getContractFactory("StakedNeuGlpTracker");
    const stakedNeuGlpTracker = await StakedNeuGlpTracker.deploy();
    await stakedNeuGlpTracker.deployed();
    console.log(`snGlp address : ${stakedNeuGlpTracker.address}`)

    // 10. BonusDistributor
    const BonusDistributor = await hre.ethers.getContractFactory("BonusDistributor");
    const bonusDistributor = await BonusDistributor.deploy(
        bnNEU.address,
        bonusNeuTracker.address
    );
    await bonusDistributor.deployed();
    console.log(`bonusDistributor address : ${bonusDistributor.address}`);

    // 11. FeeNeuDistributor
    const FeeNeuDistributor = await hre.ethers.getContractFactory("RewardDistributor");
    const feeNeuDistributor = await FeeNeuDistributor.deploy(
        esNEU.address,
        stakedNeuTracker.address
    );
    await feeNeuDistributor.deployed();
    console.log(`esNeuRewardDistributor address : ${feeNeuDistributor.address}`);

    // 12. FeeNeuGlpDistributor
    const FeeNeuGlpDistributor = await hre.ethers.getContractFactory("RewardDistributor");
    const feeNeuGlpDistributor = await FeeNeuGlpDistributor.deploy(addr.DAI, feeNeuGlpTracker.address);
    await feeNeuGlpDistributor.deployed();
    console.log(`feeNeuGlpDistributor address : ${feeNeuGlpDistributor.address}`);

    // 13. StakedNeuDistributor (DAI - NEU)
    const StakedNeuDistributor = await hre.ethers.getContractFactory("RewardDistributor");
    const stakedNeuDistributor = await StakedNeuDistributor.deploy(
        addr.DAI,
        feeNeuTracker.address
    );
    await stakedNeuDistributor.deployed();
    console.log(`stakedNeuDistributor address : ${stakedNeuDistributor.address}`);

    // 14. StakedNeuGlpDistributor (DAI - nGLP)
    const StakedNeuGlpDistributor = await hre.ethers.getContractFactory("RewardDistributor");
    const stakedNeuGlpDistributor = await StakedNeuGlpDistributor.deploy(esNEU.address, stakedNeuGlpTracker.address);
    await stakedNeuGlpDistributor.deployed();
    console.log(`snGlpDistributor address : ${stakedNeuGlpDistributor.address}`);

    // 15. Vester (NEU)
    const VesterNeu = await hre.ethers.getContractFactory("Vester");
    const vesterNeu = await VesterNeu.deploy(
        "Vested NEU",
        "vNEU",
        "31536000",
        esNEU.address,
        feeNeuTracker.address,
        neu.address,
        stakedNeuTracker.address
    );
    await vesterNeu.deployed();
    console.log(`vesterNeu address : ${vesterNeu.address}`);

    // 16. Vester (nGLP)
    const VesterNGlp = await hre.ethers.getContractFactory("Vester");
    const vesterNGlp = await VesterNGlp.deploy(
        "Vested nGLP",
        "vnGLP",
        "31536000",
        esNEU.address,
        stakedNeuGlpTracker.address,
        neu.address,
        stakedNeuGlpTracker.address
    );
    await vesterNGlp.deployed();
    console.log(`vesterNGlp address : ${vesterNGlp.address}`);

    // 17. Reader
    const Reader = await hre.ethers.getContractFactory("Reader");
    const reader = await Reader.deploy();
    await reader.deployed();
    console.log(`reader address : ${reader.address}`);

    // 18. StrategyVault
    strategyVaultConfig.push(nGlp.address);
    const StrategyVault = await hre.ethers.getContractFactory("StrategyVault");
    const strategyVault = await hre.upgrades.deployProxy(StrategyVault, [strategyVaultConfig], { kind: "uups" });
    console.log(`strategyVault address : ${strategyVault.address}`);

    // 19. GmxHelper
    const GmxHelper = await hre.ethers.getContractFactory("GmxHelper");
    const gmxHelper = await GmxHelper.deploy(gmxHelperConfig, nGlp.address, addr.DAI, addr.WBTC, addr.WETH);
    await gmxHelper.deployed();
    console.log(`gmxHelper address : ${gmxHelper.address}`);

    // 20. Router
    const Router = await hre.ethers.getContractFactory("Router");
    const router = await Router.deploy(strategyVault.address, addr.DAI, addr.WBTC, addr.WETH, nGlp.address);
    await router.deployed();
    console.log(`router address : ${router.address}`);

    // 21. BatchRouter
    const BatchRouter = await hre.ethers.getContractFactory("BatchRouter");
    const batchRouter = await BatchRouter.deploy(addr.DAI, nGlp.address, esNEU.address);
    await batchRouter.deployed();
    console.log(`batchRouter address : ${batchRouter.address}`);

    // initialize tracker
    let tx = await feeNeuGlpTracker.initialize([nGlp.address], feeNeuGlpDistributor.address);
    await tx.wait();

    tx = await stakedNeuGlpTracker.initialize([feeNeuGlpTracker.address], stakedNeuGlpDistributor.address);
    await tx.wait();

    tx = await stakedNeuTracker.initialize([neu.address, esNEU.address], stakedNeuDistributor.address);
    await tx.wait();

    tx = await bonusNeuTracker.initialize([stakedNeuTracker.address], bonusDistributor.address);
    await tx.wait();

    tx = await feeNeuTracker.initialize([bonusNeuTracker.address, bnNEU.address], feeNeuDistributor.address);
    await tx.wait();

    // initialize rewardRouter
    tx = await rewardRouter.initialize(
        addr.WETH,
        neu.address,
        esNEU.address,
        bnNEU.address,
        nGlp.address,
        stakedNeuTracker.address,
        bonusNeuTracker.address,
        feeNeuTracker.address,
        feeNeuGlpTracker.address,
        stakedNeuGlpTracker.address,
        vesterNeu.address,
        vesterNGlp.address
    );
    await tx.wait();

    /* ##################################################################
                            vester settings
    ################################################################## */
    tx = await vesterNeu.setHandler(rewardRouter.address, true);
    await tx.wait();

    tx = await vesterNGlp.setHandler(rewardRouter.address, true);
    await tx.wait();

    /* ##################################################################
                            NEU settings
    ################################################################## */
    tx = await bnNEU.setHandler(feeNeuTracker.address, true);
    await tx.wait();

    tx = await bnNEU.setMinter(rewardRouter.address, true);
    await tx.wait();

    tx = await nGlp.setHandler(feeNeuGlpTracker.address, true);
    await tx.wait();

    tx = await nGlp.setMinter(router.address, true);
    await tx.wait();
    
    tx = await nGlp.setHandler(router.address, true);
    await tx.wait();
    
    tx = await nGlp.setHandler(batchRouter.address, true);
    await tx.wait();

    tx = await nGlp.setMinter(strategyVault.address, true);
    await tx.wait();

    tx = await esNEU.setInPrivateTransferMode(true);
    await tx.wait();

    tx = await esNEU.setHandler(batchRouter.address, true);
    await tx.wait();

    tx = await esNEU.setHandler(rewardRouter.address, true);
    await tx.wait();

    tx = await esNEU.setHandler(stakedNeuDistributor.address, true);
    await tx.wait();

    tx = await esNEU.setHandler(stakedNeuGlpDistributor.address, true);
    await tx.wait();

    tx = await esNEU.setHandler(stakedNeuGlpTracker.address, true);
    await tx.wait();

    tx = await esNEU.setHandler(stakedNeuTracker.address, true);
    await tx.wait();

    tx = await esNEU.setHandler(vesterNGlp.address, true);
    await tx.wait();

    tx = await esNEU.setHandler(vesterNeu.address, true);
    await tx.wait();

    tx = await esNEU.setMinter(vesterNGlp.address, true);
    await tx.wait();

    tx = await esNEU.setMinter(vesterNeu.address, true);
    await tx.wait();


    /* ##################################################################
                            tracker settings
    ################################################################## */
    tx = await stakedNeuTracker.setInPrivateStakingMode(true);
    await tx.wait();

    tx = await stakedNeuTracker.setInPrivateTransferMode(true);
    await tx.wait();

    tx = await bonusNeuTracker.setInPrivateStakingMode(true);
    await tx.wait();

    tx = await bonusNeuTracker.setInPrivateTransferMode(true);
    await tx.wait();

    tx = await bonusNeuTracker.setInPrivateClaimingMode(true);
    await tx.wait();

    tx = await feeNeuTracker.setInPrivateStakingMode(true);
    await tx.wait();

    tx = await feeNeuTracker.setInPrivateTransferMode(true);
    await tx.wait();

    tx = await feeNeuGlpTracker.setInPrivateStakingMode(true);
    await tx.wait();

    tx = await feeNeuGlpTracker.setInPrivateTransferMode(true);
    await tx.wait();

    tx = await stakedNeuGlpTracker.setInPrivateStakingMode(true);
    await tx.wait();

    tx = await stakedNeuGlpTracker.setInPrivateTransferMode(true);
    await tx.wait();

    tx = await bonusDistributor.updateLastDistributionTime();
    await tx.wait();
    
    tx = await bonusDistributor.setBonusMultiplier(10000);
    await tx.wait();
    
    // stakedNeuTracker handler
    tx = await stakedNeuTracker.setHandler(rewardRouter.address, true);
    await tx.wait();

    tx = await stakedNeuTracker.setHandler(bonusNeuTracker.address, true);
    await tx.wait();

    // bonusNeuTracker handler
    tx = await bonusNeuTracker.setHandler(rewardRouter.address, true);
    await tx.wait();

    tx = await bonusNeuTracker.setHandler(feeNeuTracker.address, true);
    await tx.wait();

    // feeNeuGlpTracker handler
    tx = await feeNeuGlpTracker.setHandler(stakedNeuGlpTracker.address, true);
    await tx.wait();

    tx = await feeNeuGlpTracker.setHandler(rewardRouter.address, true);
    await tx.wait();

    tx = await feeNeuGlpTracker.setHandler(router.address, true);
    await tx.wait();

    tx = await feeNeuGlpTracker.setHandler(batchRouter.address, true);
    await tx.wait();

    // feeNeuTracker handler
    tx = await feeNeuTracker.setHandler(vesterNeu.address, true);
    await tx.wait();

    tx = await feeNeuTracker.setHandler(rewardRouter.address, true);
    await tx.wait();

    // stakedNeuGlpTracker handler
    tx = await stakedNeuGlpTracker.setHandler(rewardRouter.address, true);
    await tx.wait();

    tx = await stakedNeuGlpTracker.setHandler(vesterNGlp.address, true);
    await tx.wait();

    tx = await stakedNeuGlpTracker.setHandler(router.address, true);
    await tx.wait();

    tx = await stakedNeuGlpTracker.setHandler(batchRouter.address, true);
    await tx.wait();

    /* ##################################################################
                            strategyVault settings
    ################################################################## */
    tx = await strategyVault.setGmxHelper(gmxHelper.address);
    await tx.wait();

    tx = await strategyVault.setRouter(router.address, true);
    await tx.wait();

    /* ##################################################################
                                router settings
    ################################################################## */

    tx = await router.setTrackers(feeNeuGlpTracker.address, stakedNeuGlpTracker.address);
    await tx.wait();

    tx = await router.setHandler(batchRouter.address, true);
    await tx.wait();

    tx = await router.setIsSale(true);
    await tx.wait();

    /* ##################################################################
                             batchRouter settings
     ################################################################## */

    tx = await batchRouter.setRouter(router.address);
    await tx.wait();

    tx = await batchRouter.approveToken(addr.DAI, router.address);
    await tx.wait();

    tx = await batchRouter.setDepositLimit(expandDecimals(2000000, 18));
    await tx.wait();

    tx = await batchRouter.setTrackers(feeNeuGlpTracker.address, stakedNeuGlpTracker.address);
    await tx.wait();
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});