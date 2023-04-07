import { deployments } from "hardhat"
import addr from "../../shared/constants/addresses";

export const gmxProtocolFixture = deployments.createFixture(async hre => {
    const weth = await hre.ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", addr.WETH);
    const wbtc = await hre.ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", addr.WBTC);
    const usdc = await hre.ethers.getContractAt("MintableERC20", addr.USDC);
    const dai = await hre.ethers.getContractAt("MintableERC20", addr.DAI);

    const glp = await hre.ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", addr.GMX.glp);
    const fsGlp = await hre.ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", addr.GMX.fsGlp);
    const usdg = await hre.ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", addr.GMX.usdg);

    const gmxVault = await hre.ethers.getContractAt("IVault", addr.GMX.Vault);
    const fastPriceFeed = await hre.ethers.getContractAt("IFastPriceFeed", addr.GMX.FastPriceFeed);
    const positionRouter = await hre.ethers.getContractAt("IPositionRouter", addr.GMX.PositionRouter);
    const gmxRouter = await hre.ethers.getContractAt("contracts/interfaces/gmx/IRouter.sol:IRouter", addr.GMX.Router)
    const glpManager = await hre.ethers.getContractAt("IGlpManager", addr.GMX.GlpManager);
    const shortsTracker = await hre.ethers.getContractAt("IShortsTracker", addr.GMX.ShortsTracker);
    const keeper = await hre.ethers.getImpersonatedSigner(addr.GMX.keeper);
    const stakedGlp = await hre.ethers.getContractAt("IStakedGlp", addr.GMX.StakedGlp);

    return {
        weth,
        wbtc,
        usdc,
        dai,
        glp,
        fsGlp,
        usdg,
        gmxVault,
        fastPriceFeed,
        positionRouter,
        glpManager,
        gmxRouter,
        shortsTracker,
        stakedGlp,
        keeper
    }
})