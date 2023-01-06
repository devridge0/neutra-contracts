// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import { Governable } from "./libraries/Governable.sol";
import { IStrategyVault } from "./interfaces/IStrategyVault.sol";
import { IRewardTracker} from "./interfaces/IRewardTracker.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { IMintable } from "./interfaces/IMintable.sol";

contract Router is ReentrancyGuard, Governable {
    bool public isSale;
    bool public initialDeposit;

    uint256 public constant PRICE_PRECISION = 1e30;
    address public strategyVault;
    uint256 public executionFee = 0.0001 ether;

    uint256 public wantBeforeCollateralIn;
    
    address public want;
    address public wbtc;
    address public weth;
    address public nGlp;

    address public feeNeuGlpTracker;
    address public stakedNeuGlpTracker;

    mapping(address => bool) public isHandler;
    mapping(address => uint256) public pendingAmounts;

    event ApproveToken(address token, address spender);
    event SetHandler(address handler, bool isActive);
    event ExecutePositionsBeforeDealGlpDeposit(uint256 amount, uint256 pendingAmountsWant);
    event ExecutePositionsBeforeDealGlpWithdraw(uint256 amount, uint256 wantBeforeCollateralIn);
    event ConfirmAndBuy(uint256 pendingAmountsWant, uint256 mintAmount);
    event ConfirmAndSell(uint256 pendingAmountsNGlp);
    event SetExecutionFee(uint256 fee);
    event SetIsSale(bool isActive);
    event SetTrackers(address feeNeuGlpTracker, address stakedNeuGlpTracker);


    modifier onlyHandler() {
        _onlyHandler();
        _;
    }

    constructor(address _vault, address _want, address _wbtc, address _weth, address _nGlp) {
        strategyVault = _vault;
        want = _want;
        wbtc = _wbtc;
        weth = _weth;
        nGlp = _nGlp;

        IERC20(want).approve(_vault, type(uint256).max);
    }

    function _onlyHandler() internal view {
        require(isHandler[msg.sender], "StrategyVault: not router");
    }

    function approveToken(address _token, address _spender) external onlyGov {
        IERC20(_token).approve(_spender, type(uint256).max);
        emit ApproveToken(_token, _spender);
    } 

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
        emit SetHandler(_handler, _isActive);
    }

    /*
    NOTE:
    GMX requires two transaction to increase or decrase positions
    therefore, router has to conduct two transactions to finish the process
    always execute positions first then confrim and handle glp
    */
    function executePositionsBeforeDealGlp(uint256 _amount, bytes[] calldata _params, bool _isWithdraw) external payable onlyHandler {
        if (!_isWithdraw) {
            require(pendingAmounts[want] == 0, "Router: pending amount exists");
            IERC20(want).transferFrom(msg.sender, address(this), _amount);

            uint256 beforeBalance = IERC20(want).balanceOf(address(this));
            IStrategyVault(strategyVault).executeIncreasePositions{value: msg.value}(_params);
            uint256 usedAmount = beforeBalance - IERC20(want).balanceOf(address(this));
            pendingAmounts[want] = _amount - usedAmount;

            emit ExecutePositionsBeforeDealGlpDeposit(_amount, pendingAmounts[want]);
        } else {
            require(wantBeforeCollateralIn == 0, "Router: pending position exists");
            require(pendingAmounts[nGlp] == 0, "Router: pending amount exists");

            IERC20(nGlp).transferFrom(msg.sender, address(this), _amount);

            pendingAmounts[nGlp] = _amount;
            IStrategyVault(strategyVault).executeDecreasePositions{value: msg.value}(_params);
            wantBeforeCollateralIn = IERC20(want).balanceOf(address(this));

            emit ExecutePositionsBeforeDealGlpWithdraw(_amount, wantBeforeCollateralIn);
        }
    }

    /*
    NOTE:
    After positions execution, requires to confirm those postiions
    If positions executed successfully, handles glp
    */
    function confirmAndBuy(address _recipient) external onlyHandler returns (uint256) {
        uint256 pendingAmountsWant = pendingAmounts[want];
        require(pendingAmountsWant > 0, "Router: no pending amounts to buy");
        IStrategyVault _vault = IStrategyVault(strategyVault);
        _vault.confirm();

        uint256 totalSupply = IERC20(nGlp).totalSupply();
        uint256 totalValue = _vault.totalValue();

        uint256 value = _vault.buyNeuGlp(pendingAmountsWant);
        pendingAmounts[want] = 0;
        uint256 decimals = IERC20(nGlp).decimals();
        uint256 mintAmount = totalSupply == 0 ? value * (10 ** decimals) / PRICE_PRECISION : value * totalSupply / totalValue;

        IMintable(nGlp).mint(_recipient, mintAmount);

        IRewardTracker(feeNeuGlpTracker).stakeForAccount(_recipient, _recipient, nGlp, mintAmount);
        IRewardTracker(stakedNeuGlpTracker).stakeForAccount(_recipient, _recipient, feeNeuGlpTracker, mintAmount);

        emit ConfirmAndBuy(pendingAmountsWant, mintAmount);

        return mintAmount;
    }
    
    /*
    NOTE:
    After positions execution, requires to confirm those postiions
    If positions executed successfully, handles glp
    */
    function confirmAndSell(address _recipient) external onlyHandler returns (uint256) {
        uint256 pendingAmount = pendingAmounts[nGlp];
        require(pendingAmount > 0, "Router: no pending amounts to sell");
        IStrategyVault _vault = IStrategyVault(strategyVault);
        
        _vault.confirm();

        uint256 collateralIn = IERC20(want).balanceOf(address(this)) - wantBeforeCollateralIn;

        uint256 amountOut = _vault.sellNeuGlp(pendingAmount, address(this));
        IMintable(nGlp).burn(address(this), pendingAmount);
        
        pendingAmounts[nGlp] = 0;

        amountOut += collateralIn;

        IERC20(want).transfer(_recipient, amountOut);
        wantBeforeCollateralIn = 0;

        emit ConfirmAndSell(pendingAmount);

        return amountOut;
    }

    // executed only if strategy exited
    function settle(uint256 _amount) external onlyGov {
        IRewardTracker(stakedNeuGlpTracker).unstakeForAccount(msg.sender, feeNeuGlpTracker, _amount, msg.sender);
        IRewardTracker(feeNeuGlpTracker).unstakeForAccount(msg.sender, nGlp, _amount, address(this));
        IStrategyVault(strategyVault).settle(_amount, msg.sender);
        IMintable(nGlp).burn(address(this), _amount);
    }
    
    function setExecutionFee(uint256 _fee) external onlyGov {
        executionFee = _fee;
        emit SetExecutionFee(_fee);
    }

    function setIsSale(bool _isActive) external onlyGov {
        isSale = _isActive;
        emit SetIsSale(_isActive);
    }

    function setTrackers(address _feeNeuGlpTracker, address _stakedNeuGlpTracker) external onlyGov {
        feeNeuGlpTracker = _feeNeuGlpTracker;
        stakedNeuGlpTracker = _stakedNeuGlpTracker;
        emit SetTrackers(_feeNeuGlpTracker, _stakedNeuGlpTracker);
    }

}