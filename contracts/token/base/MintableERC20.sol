// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

abstract contract MintableERC20 is ERC20 {
    address gov;

    mapping (address => bool) public isMinter;
    mapping (address => bool) public isHandler;

    modifier onlyGov() {
        require(gov == _msgSender(), "MintalbeERC20: forbidden");
        _;
    }
    
    modifier onlyMinter() {
        require(isMinter[msg.sender], "MintalbeERC20: forbidden");
        _;
    }

    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        gov = _msgSender();
    }

    function setMinter(address _minter, bool _isActive) external onlyGov {
        isMinter[_minter] = _isActive;
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
    }

    function setHandlers(address[] memory _handler, bool[] memory _isActive) external onlyGov {
        for(uint256 i = 0; i < _handler.length; i++){
            isHandler[_handler[i]] = _isActive[i];
        }
    }

    function mint(address _account, uint256 _amount) external onlyMinter {
        _mint(_account, _amount);
    }

    function burn(address _account, uint256 _amount) external onlyMinter {
        _burn(_account, _amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        address spender = _msgSender();

        if (isHandler[spender]) {
            _transfer(from, to, amount);
            return true;
        }

        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }
}