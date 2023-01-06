import { deployments } from "hardhat";
import addr from "../../shared/constants/addresses";
import { deployContract, expandDecimals } from "../../shared/utils";

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

export const neutraProtocolFixture = deployments.createFixture(async hre => {
    // Deploy
    const neu = await deployContract("NEU", []);
    const nGlp = await deployContract("nGLP", []);
    const esNEU = await deployContract("EsNEU", []);
    const bnNEU = await deployContract("BnNEU", []);
    const rewardRouter = await deployContract("RewardRouter", []);
    const bonusNeuTracker = await deployContract("BonusNeuTracker", []);
    const feeNeuTracker = await deployContract("FeeNeuTracker", []);
    const feeNeuGlpTracker = await deployContract("FeeNeuGlpTracker", []);
    const stakedNeuTracker = await deployContract("StakedNeuTracker", []);
    const stakedNeuGlpTracker = await deployContract("StakedNeuGlpTracker", []);
    const bonusDistributor = await deployContract("BonusDistributor", [bnNEU.address, bonusNeuTracker.address]);
    const feeNeuDistributor = await deployContract("RewardDistributor", [esNEU.address, stakedNeuTracker.address]);
    const feeNeuGlpDistributor = await deployContract("RewardDistributor", [addr.DAI, feeNeuGlpTracker.address]);
    const stakedNeuDistributor = await deployContract("RewardDistributor", [addr.DAI, feeNeuTracker.address]);
    const stakedNeuGlpDistributor = await deployContract("RewardDistributor", [esNEU.address, stakedNeuGlpTracker.address]);
    const vesterNeu = await deployContract(
        "Vester",
        ["Vested NEU",
            "vNEU",
            "31536000",
            esNEU.address,
            feeNeuTracker.address,
            neu.address,
            stakedNeuTracker.address
        ]
    );

    const vesterNGlp = await deployContract(
        "Vester",
        ["Vested nGLP",
            "vnGLP",
            "31536000",
            esNEU.address,
            stakedNeuGlpTracker.address,
            neu.address,
            stakedNeuGlpTracker.address
        ]
    );
    const reader = await deployContract("Reader", []);
    strategyVaultConfig.push(nGlp.address);
    const StrategyVault = await hre.ethers.getContractFactory("StrategyVault");
    const strategyVault = await hre.upgrades.deployProxy(StrategyVault, [strategyVaultConfig], { kind: "uups" });
    const gmxHelper = await deployContract("GmxHelper", [gmxHelperConfig, nGlp.address, addr.DAI, addr.WBTC, addr.WETH]);
    const router = await deployContract("Router", [strategyVault.address, addr.DAI, addr.WBTC, addr.WETH, nGlp.address]);
    const batchRouter = await deployContract("BatchRouter", [addr.DAI, nGlp.address, esNEU.address]);


    // initialize tracker
    await feeNeuGlpTracker.initialize([nGlp.address], feeNeuGlpDistributor.address);
    await stakedNeuGlpTracker.initialize([feeNeuGlpTracker.address], stakedNeuGlpDistributor.address);
    await stakedNeuTracker.initialize([neu.address, esNEU.address], stakedNeuDistributor.address);
    await bonusNeuTracker.initialize([stakedNeuTracker.address], bonusDistributor.address);
    await feeNeuTracker.initialize([bonusNeuTracker.address, bnNEU.address], feeNeuDistributor.address);
    
    // initialize rewardRouter
    await rewardRouter.initialize(
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

    /* ##################################################################
                            vester settings
    ################################################################## */
    await vesterNeu.setHandler(rewardRouter.address, true);
    await vesterNGlp.setHandler(rewardRouter.address, true);

    /* ##################################################################
                            NEU settings
    ################################################################## */
    await bnNEU.setHandler(feeNeuTracker.address, true);
    await bnNEU.setMinter(rewardRouter.address, true);
    await nGlp.setHandler(feeNeuGlpTracker.address, true);
    await nGlp.setMinter(router.address, true);
    await nGlp.setHandler(router.address, true);
    await nGlp.setHandler(batchRouter.address, true);
    await nGlp.setMinter(strategyVault.address, true);
    await esNEU.setInPrivateTransferMode(true);
    await esNEU.setHandler(batchRouter.address, true);
    await esNEU.setHandler(rewardRouter.address, true);
    await esNEU.setHandler(stakedNeuDistributor.address, true);
    await esNEU.setHandler(stakedNeuGlpDistributor.address, true);
    await esNEU.setHandler(stakedNeuGlpTracker.address, true);
    await esNEU.setHandler(stakedNeuTracker.address, true);
    await esNEU.setHandler(vesterNGlp.address, true);
    await esNEU.setHandler(vesterNeu.address, true);
    await esNEU.setMinter(vesterNGlp.address, true);
    await esNEU.setMinter(vesterNeu.address, true);

    /* ##################################################################
                            tracker settings
    ################################################################## */
    await stakedNeuTracker.setInPrivateStakingMode(true);
    await stakedNeuTracker.setInPrivateTransferMode(true);
    await bonusNeuTracker.setInPrivateStakingMode(true);
    await bonusNeuTracker.setInPrivateTransferMode(true);
    await bonusNeuTracker.setInPrivateClaimingMode(true);
    await feeNeuTracker.setInPrivateStakingMode(true);
    await feeNeuTracker.setInPrivateTransferMode(true);
    await feeNeuGlpTracker.setInPrivateStakingMode(true);
    await feeNeuGlpTracker.setInPrivateTransferMode(true);
    await stakedNeuGlpTracker.setInPrivateStakingMode(true);
    await stakedNeuGlpTracker.setInPrivateTransferMode(true);
    await bonusDistributor.updateLastDistributionTime();
    await bonusDistributor.setBonusMultiplier(10000);
    // stakedNeuTracker handler
    await stakedNeuTracker.setHandler(rewardRouter.address, true);
    await stakedNeuTracker.setHandler(bonusNeuTracker.address, true);
    // bonusNeuTracker handler
    await bonusNeuTracker.setHandler(rewardRouter.address, true);
    await bonusNeuTracker.setHandler(feeNeuTracker.address, true);
    // feeNeuGlpTracker handler
    await feeNeuGlpTracker.setHandler(stakedNeuGlpTracker.address, true);
    await feeNeuGlpTracker.setHandler(rewardRouter.address, true);
    await feeNeuGlpTracker.setHandler(router.address, true);
    await feeNeuGlpTracker.setHandler(batchRouter.address, true);
    // feeNeuTracker handler
    await feeNeuTracker.setHandler(vesterNeu.address, true);
    await feeNeuTracker.setHandler(rewardRouter.address, true);
    // stakedNeuGlpTracker handler
    await stakedNeuGlpTracker.setHandler(rewardRouter.address, true);
    await stakedNeuGlpTracker.setHandler(vesterNGlp.address, true);
    await stakedNeuGlpTracker.setHandler(router.address, true);
    await stakedNeuGlpTracker.setHandler(batchRouter.address, true);
    
    /* ##################################################################
                            strategyVault settings
    ################################################################## */
    await strategyVault.setGmxHelper(gmxHelper.address);
    await strategyVault.setRouter(router.address, true);

    /* ##################################################################
                                router settings
    ################################################################## */
    await router.setTrackers(feeNeuGlpTracker.address, stakedNeuGlpTracker.address);
    await router.setHandler(batchRouter.address, true);
    await router.setIsSale(true);

    /* ##################################################################
                             batchRouter settings
     ################################################################## */
    await batchRouter.setRouter(router.address);
    await batchRouter.approveToken(addr.DAI, router.address);
    await batchRouter.setDepositLimit(expandDecimals(2000000, 18));
    await batchRouter.setTrackers(feeNeuGlpTracker.address, stakedNeuGlpTracker.address);

    return {
        neu,
        nGlp,
        esNEU,
        bnNEU,
        rewardRouter,
        bonusNeuTracker,
        feeNeuTracker,
        feeNeuGlpTracker,
        stakedNeuTracker,
        stakedNeuGlpTracker,
        bonusDistributor,
        feeNeuDistributor,
        feeNeuGlpDistributor,
        stakedNeuDistributor,
        stakedNeuGlpDistributor,
        vesterNeu,
        vesterNGlp,
        reader,
        strategyVault,
        gmxHelper,
        router,
        batchRouter
    }
})