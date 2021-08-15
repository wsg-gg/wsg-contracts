// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./libs/pausable.sol";
import "./libs/reentrancy-guard.sol";
import "./libs/bep20.sol";
import "./libs/safe-math.sol";

import "./interfaces/ierc1155mintable.sol";

contract WSGPoolV2WithNFT is ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 pendingRewards;
        uint256 startTime;
        bool nftClaimed;
    }

    struct PoolInfo {
        IBEP20 stakingToken;
        uint256 lastRewardBlock;
        uint256 accTokenPerShare;
        uint256 minimumStakeAmount;
    }

    IBEP20 public rewardToken;
    uint256 public rewardPerBlock;

    IERC1155Mintable public nftContract;
    uint256 public tokenId;

    PoolInfo public pool;
    mapping(address => UserInfo) public userInfo;

    uint256 public nftClaimPeriod = 3 weeks;

    uint256 private _totalSupply;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Claim(address indexed user, uint256 amount);
    event NftClaimed(address indexed user, uint256 tokenId);
    event Recovered(address indexed token, uint256 amount);

    event MinimumStakeAmountUpdated(uint256 stakeAmount);
    event NftClaimPeriodUpdated(uint256 claimPeriod);
    event NftContractUpdated(address nftContract);
    event TokenIdUpdated(uint256 tokenId);

    constructor() public {
        nftContract = IERC1155Mintable(0xe86E4b3bB1846a017153CedCD0458dc9Ad835D9b);
        tokenId = 10;
    }

    /** VIEWS **/

    function totalSupply() 
        external 
        view 
        returns (uint256) 
    {
        return _totalSupply;
    }

    function pendingRewards(address _user) 
        external 
        view 
        returns (uint256) 
    {
        require(pool.lastRewardBlock > 0 && block.number >= pool.lastRewardBlock, 'Pool not yet started');
        UserInfo storage user = userInfo[_user];
        uint256 accTokenPerShare = pool.accTokenPerShare;
        uint256 supply = pool.stakingToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && supply != 0) {
            uint256 multiplier = block.number.sub(pool.lastRewardBlock);
            uint256 tokenReward = multiplier.mul(rewardPerBlock);
            accTokenPerShare = pool.accTokenPerShare.add(tokenReward.mul(1e24).div(supply));
        }
        return user.amount.mul(accTokenPerShare).div(1e24).sub(user.rewardDebt).add(user.pendingRewards);
    }

    /** PUBLIC FUNCTION **/

    function stake(uint256 amount) 
        external 
        nonReentrant 
    {
        require (amount >= pool.minimumStakeAmount, "Below minimum stake amount!");
        UserInfo storage user = userInfo[msg.sender];
        require (!user.nftClaimed, "You already claimed your NFT card!");
        updatePool();
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accTokenPerShare).div(1e24).sub(user.rewardDebt);
            if (pending > 0) {
                user.pendingRewards = user.pendingRewards.add(pending);
            }
        }
        uint256 actualReceived;
        if (amount > 0) {
            uint256 balBefore = pool.stakingToken.balanceOf(address(this));
            pool.stakingToken.safeTransferFrom(msg.sender, address(this), amount);
            uint256 balAfter = pool.stakingToken.balanceOf(address(this));
            actualReceived = balAfter.sub(balBefore);
            user.amount = user.amount.add(actualReceived);
            _totalSupply = _totalSupply.add(actualReceived);
            if (user.startTime == 0 && !user.nftClaimed) {
                user.startTime = block.timestamp;
            }
        }
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e24);
        emit Deposit(msg.sender, actualReceived);
    }

    function withdraw(uint256 amount) 
        public 
        nonReentrant 
    {
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= amount, "Withdrawing more than you have!");
        updatePool();
        uint256 pending = user.amount.mul(pool.accTokenPerShare).div(1e24).sub(user.rewardDebt);
        if (pending > 0) {
            user.pendingRewards = user.pendingRewards.add(pending);
        }
        if (amount > 0) {
            user.amount = user.amount.sub(amount);
            _totalSupply = _totalSupply.sub(amount);
            pool.stakingToken.safeTransfer(address(msg.sender), amount);
            if (user.amount < pool.minimumStakeAmount || user.nftClaimed) {
                user.startTime = 0;
            } else {
                user.startTime = block.timestamp;
            }
        }
        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e24);
        emit Withdraw(msg.sender, amount);
    }

    function getReward() 
        public 
    {
        UserInfo storage user = userInfo[msg.sender];
        updatePool();
        uint256 pending = user.amount.mul(pool.accTokenPerShare).div(1e24).sub(user.rewardDebt);
        if (pending > 0 || user.pendingRewards > 0) {
            user.pendingRewards = user.pendingRewards.add(pending);
            uint256 claimedAmount = safeTokenTransfer(msg.sender, user.pendingRewards);
            emit Claim(msg.sender, claimedAmount);
            user.pendingRewards = user.pendingRewards.sub(claimedAmount);
        }
        
        if (user.startTime != 0 &&
                block.timestamp >= user.startTime.add(nftClaimPeriod) &&
                    !user.nftClaimed) {
            user.nftClaimed = true;
            user.startTime = 0;

            uint256 amount = user.amount;
            if (amount > 0) {
                user.amount = user.amount.sub(amount);
                _totalSupply = _totalSupply.sub(amount);
                pool.stakingToken.safeTransfer(address(msg.sender), amount);
                emit Withdraw(msg.sender, amount);
            }
            
            bytes memory data = new bytes(0);
            nftContract.mint(msg.sender, tokenId, 1, data);
            emit NftClaimed(msg.sender, tokenId);
        }

        user.rewardDebt = user.amount.mul(pool.accTokenPerShare).div(1e24);
    }

    function exit() 
        external 
    {
        UserInfo storage user = userInfo[msg.sender];
        withdraw(user.amount);
        getReward();
    }

    /** INTERNAL FUNCTIONS **/

    function updatePool() 
        internal 
    {
        require(pool.lastRewardBlock > 0 && block.number >= pool.lastRewardBlock, 'Pool not yet started');
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 supply = pool.stakingToken.balanceOf(address(this));
        if (supply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = block.number.sub(pool.lastRewardBlock);
        uint256 tokenReward = multiplier.mul(rewardPerBlock);
        pool.accTokenPerShare = pool.accTokenPerShare.add(tokenReward.mul(1e24).div(supply));
        pool.lastRewardBlock = block.number;
    }

    function safeTokenTransfer(address to, uint256 amount) 
        internal 
        returns (uint256) 
    {
        uint256 tokenBalance = rewardToken.balanceOf(address(this));
        if (amount > tokenBalance) {
            rewardToken.safeTransfer(to, tokenBalance);
            return tokenBalance;
        } else {
            rewardToken.safeTransfer(to, amount);
            return amount;
        }
    }

    /** RESTRICTED FUNCTIONS **/

    function initPool(
            address _stakingToken, 
            address _rewardToken, 
            uint256 _minimumStakeAmount,
            uint256 _rewardPerBlock
        ) 
        external 
        onlyOwner 
    {
        require(
            address(rewardToken) == address(0) && 
                address(pool.stakingToken) == address(0), 
            'Tokens already set!'
        );

        pool =
            PoolInfo({
                stakingToken: IBEP20(_stakingToken),
                lastRewardBlock: 0,
                accTokenPerShare: 0,
                minimumStakeAmount: _minimumStakeAmount
        });

        rewardToken = IBEP20(_rewardToken);
        rewardPerBlock = _rewardPerBlock;
    }
    
    function startPool(uint256 startBlock) 
        external 
        onlyOwner 
    {
        require(pool.lastRewardBlock == 0, 'Pool already started');
        pool.lastRewardBlock = startBlock;
    }
    
    function setRewardPerBlock(uint256 _rewardPerBlock) 
        external 
        onlyOwner 
    {
        require(_rewardPerBlock > 0, "Reward per block should be greater than 0!");
        rewardPerBlock = _rewardPerBlock;
    }

    function setMinimumStakeAmount(uint256 _stakeAmount) 
        external 
        onlyOwner 
    {
        pool.minimumStakeAmount = _stakeAmount;
        emit MinimumStakeAmountUpdated(_stakeAmount);
    }

    function setClaimPeriod(uint256 _claimPeriod) 
        external 
        onlyOwner 
    {
        nftClaimPeriod = _claimPeriod;
        emit NftClaimPeriodUpdated(_claimPeriod);
    }

    function setTokenId(uint256 _tokenId) 
        external 
        onlyOwner 
    {
        tokenId = _tokenId;
        emit TokenIdUpdated(_tokenId);
    }

    function setNftContract(address _nftContract) 
        external 
        onlyOwner 
    {
        require(_nftContract != address(0), '!null');
        nftContract = IERC1155Mintable(_nftContract);
        emit NftContractUpdated(_nftContract);
    }

    function recoverBEP20(address tokenAddress, uint256 tokenAmount)
        external
        onlyOwner
    {
        // Cannot recover the staking token or the rewards token
        require(
            tokenAddress != address(pool.stakingToken) && tokenAddress != address(rewardToken),
            "Cannot withdraw the staking or reward tokens"
        );
        IBEP20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }
}