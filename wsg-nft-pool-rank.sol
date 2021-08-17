// SPDX-License-Identifier: MIT
pragma experimental ABIEncoderV2;
pragma solidity 0.6.12;

import "./libs/pausable.sol";
import "./libs/reentrancy-guard.sol";
import "./libs/bep20.sol";
import "./libs/safe-math.sol";

import "./interfaces/ierc1155mintable.sol";

contract NFTPoolWithLockRank is ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // STATE VARIABLES

    IBEP20 public immutable stakingToken;
    IERC1155Mintable public nftContract;
    uint256 public tokenId;

    uint256 public lockingPeriod = 3 weeks; // 2 weeks
    uint256 public maxDepositsPerUser = 25; // user can stake a total of 25 times
    uint256 public maxCountPerDeposit = 100; // 100 cards max purchased per deposit
    uint256 public pricePerCard = 2500000000 * 10**18; // cost in wsg per card
    uint256 public immutable rankTokenId;

    address private constant wsg = address(0xA58950F05FeA2277d2608748412bf9F802eA4901);

    struct DepositInfo {
        address account;
        uint256 count;
        uint256 deposit;
        uint256 unlockedAt;
        bool withdrawn;
    }

    // tracks total amount of wsg tokens deposited (for frontend)
    uint256 private _totalSupply;
    uint256 private _totalDeposits;
    mapping(address => uint256) private _balances;

    // tracks user deposits
    mapping(address => uint256[]) private _userDeposits;
    mapping(address => uint256[]) private _userWithdrawals;
    mapping(address => uint256) private _userDepositCounts;
    mapping(uint256 => DepositInfo) private _deposits;

    // CONSTRUCTOR

    constructor() public {
        stakingToken = IBEP20(wsg);
        nftContract = IERC1155Mintable(0xe86E4b3bB1846a017153CedCD0458dc9Ad835D9b);
        tokenId = 2;
        rankTokenId = 1;
    }

    // VIEWS

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function totalDeposits() external view returns (uint256) {
        return _totalDeposits;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function depositAtId(uint256 depositId) external view returns (DepositInfo memory) {
        return _deposits[depositId];
    }

    function getDepositIds(address account) external view returns (uint256[] memory) {
        return _userDeposits[account];
    }

    function getWithdrawnIds(address account) external view returns (uint256[] memory) {
        return _userWithdrawals[account];
    }

    function getCountOfDeposits(address account) public view returns (uint256) {
        return _userDepositCounts[account];
    }

    // PUBLIC FUNCTIONS

    function stake(uint256 count)
        external
        nonReentrant
        notPaused
    {
        require(count > 0, "Cannot stake 0");
        require(count <= maxCountPerDeposit, '!maxCountPerDeposit');
        require(getCountOfDeposits(msg.sender).add(1) <= maxDepositsPerUser, '!maxDepositsPerUser');
        require(nftContract.balanceOf(msg.sender, rankTokenId) >= count, '!rankTokenId');

        uint256 amount = count.mul(pricePerCard);
        uint256 balBefore = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balAfter = stakingToken.balanceOf(address(this));
        uint256 actualReceived = balAfter.sub(balBefore);

        nftContract.burn(msg.sender, rankTokenId, count);

        _totalSupply = _totalSupply.add(actualReceived);
        _balances[msg.sender] = _balances[msg.sender].add(actualReceived);

        _totalDeposits = _totalDeposits.add(1);
        _userDepositCounts[msg.sender] = _userDepositCounts[msg.sender].add(1);
        uint256 depositId = _totalDeposits;

        _userDeposits[msg.sender].push(depositId);
        _deposits[depositId] = DepositInfo(msg.sender, count, actualReceived, block.timestamp.add(lockingPeriod), false);
        
        emit Staked(msg.sender, actualReceived, depositId);
    }

    function claimAndExit(uint256 depositId)
        external
        notPaused
    {
        exit(depositId);
        bytes memory data = new bytes(0);
        nftContract.mint(msg.sender, tokenId, _deposits[depositId].count, data);
    }

    function exit(uint256 depositId) 
        public
        nonReentrant 
    {
        require(_deposits[depositId].account == msg.sender, 'not owner');
        require(_deposits[depositId].unlockedAt <= block.timestamp, 'still locked');
        require(!_deposits[depositId].withdrawn, 'already withdrawn');

        uint256 amount = _deposits[depositId].deposit;

        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        _deposits[depositId].withdrawn = true;
        _userWithdrawals[msg.sender].push(depositId);

        stakingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, depositId);
    }

    // RESTRICTED FUNCTIONS

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverBEP20(address tokenAddress, uint256 tokenAmount)
        external
        restricted
    {
        // Cannot recover the staking token or the rewards token
        require(
            tokenAddress != address(stakingToken),
            "Cannot withdraw the staking tokens"
        );
        IBEP20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setLockingPeriod(uint256 _lockingPeriod) external restricted {
        lockingPeriod = _lockingPeriod;
        emit LockingPeriodUpdated(_lockingPeriod);
    }

    function setMaxDepositsPerUser(uint256 _maxDepositsPerUser) external restricted {
        require(_maxDepositsPerUser > maxDepositsPerUser, '!lower');
        maxDepositsPerUser = _maxDepositsPerUser;
        emit MaxDepositsPerUserUpdated(_maxDepositsPerUser);
    }

    function setMaxCountPerDeposit(uint256 _maxCountPerDeposit) external restricted {
        maxCountPerDeposit = _maxCountPerDeposit;
        emit MaxCountPerDepositUpdated(_maxCountPerDeposit);
    }

    function setPricePerCard(uint256 _pricePerCard) external restricted {
        pricePerCard = _pricePerCard * 10**18;
        emit PricePerCardUpdated(_pricePerCard * 10**18);
    }

    function setTokenId(uint256 _tokenId) external restricted {
        tokenId = _tokenId;
        emit TokenIdUpdated(_tokenId);
    }

    function setNftContract(address _nftContract) external restricted {
        require(_nftContract != address(0), '!null');
        nftContract = IERC1155Mintable(_nftContract);
        emit NftContractUpdated(_nftContract);
    }

    // *** MODIFIERS ***

    modifier restricted {
        require(
            msg.sender == owner(),
            '!restricted'
        );

        _;
    }

    // EVENTS

    event Staked(address indexed user, uint256 amount, uint256 depositId);
    event Withdrawn(address indexed user, uint256 amount, uint256 depositId);
    event NFTClaimed(address indexed user, uint256 tokenId, uint256 count);
    event LockingPeriodUpdated(uint256 lockingPeriod);
    event MaxDepositsPerUserUpdated(uint256 maxDepositsPerUser);
    event MaxCountPerDepositUpdated(uint256 maxCountPerDeposit);
    event PricePerCardUpdated(uint256 pricePerCard);
    event TokenIdUpdated(uint256 tokenId);
    event NftContractUpdated(address nftContract);
    event Recovered(address token, uint256 amount);
}