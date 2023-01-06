import hre from "hardhat";
import addr from "../shared/constants/addresses";

async function main() {
    let abi = [
        "function decreaseShortPosition(address,uint256,uint256) public payable",
        "function rescueAssets(address) external",
        "function getPosition(address,address,address,bool) public view returns (uint256, uint256, uint256, uint256, uint256, uint256, bool, uint256)"
    ];

    // const gmxVault = await hre.ethers.getContractAt(abi, "0x489ee077994B6658eAfA855C308275EAd8097C4A");
    // let res = await gmxVault.getPosition("0x81B9F11D01B6EA69A2d8660e9C3F0760E2E4230c", addr.USDC, addr.WETH, false);
    // console.log(res)
    const vault = await hre.ethers.getContractAt(abi, "0x81B9F11D01B6EA69A2d8660e9C3F0760E2E4230c");
    let tx = await vault.rescueAssets("0x82aF49447D8a07e3bd95BD0d56f35241523fBab1");
    await tx.wait();
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});