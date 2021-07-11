// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./libs/reentrancy-guard.sol";
import "./libs/pausable.sol";
import "./libs/bep20.sol";
import "./libs/safe-math.sol";

import "./interfaces/wbnb.sol";

contract WsgDepositHub is Pausable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    address constant internal _wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address constant internal _wsg = address(0xA58950F05FeA2277d2608748412bf9F802eA4901);
    address constant internal _cake = address(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82);
    address constant internal _doge = address(0xbA2aE424d960c26247Dd6c32edC70B295c744C43);
    address constant internal _shiba = address(0x2859e4544C4bB03966803b044A93563Bd2D0DD4D);
    address constant internal _busd = address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    address constant internal _bake = address(0xE02dF9e3e622DeBdD69fb838bB799E3F168902c5);
    address constant internal _juld = address(0x5A41F637C3f7553dBa6dDC2D3cA92641096577ea);
    address constant internal _twt = address(0x4B0F1812e5Df2A09796481Ff14017e6005508003);
    address constant internal _sfp = address(0xD41FDb03Ba84762dD66a0af1a6C8540FF1ba5dfb);

    address private _treasury;
    mapping(address => bool) private _operators;

    uint256 public depositFee = 10;
    uint256 public depositFeeMax = 30;
    uint256 internal depositFeeBase = 1000;

    struct SupportedToken {
        address implementation;
        bool active;
    }

    enum MatchStatus {
        Pending,
        Started,
        Cancelled,
        Finished
    }

    struct Match {
        bool exists;
        MatchStatus status;
    }

    SupportedToken[] public supportedTokens;
    mapping(address => mapping (address => uint256)) internal _balances;
    mapping(address => mapping (address => uint256)) internal _reserves;
    mapping(address => uint256) internal _treasuries;
    mapping(uint256 => Match) public _matches;

    event Deposit(address indexed account, address token, uint256 amount);
    event Withdraw(address indexed account, address token, uint256 amount);
    event TokensReserved(uint256 matchId, address indexed account, address token, uint256 amount);
    event TokensReleased(uint256 matchId, address indexed account, address token, uint256 amount);
    event Declare(
        uint256 matchId,
        address indexed winner,
        address indexed loser,
        address winner_referrer,
        address loser_referrer,
        address winner_token,
        address loser_token,
        uint256 winner_amount,
        uint256 loser_amount,
        uint256 winner_treasury_amount,
        uint256 loser_treasury_amount,
        uint256 winner_referral_amount,
        uint256 loser_referral_amount
    );

    constructor(
        address treasury,
        address operator
    ) public {
        _treasury = treasury;
        _operators[operator] = true;

        addSupportedToken(_wbnb);
        addSupportedToken(_wsg);
        addSupportedToken(_cake);
        addSupportedToken(_doge);
        addSupportedToken(_shiba);
        addSupportedToken(_busd);
        addSupportedToken(_bake);
        addSupportedToken(_juld);
        addSupportedToken(_twt);
        addSupportedToken(_sfp);
    }

    receive() external payable {
        require(msg.sender == address(_wbnb));
    }

    // *** VIEWS ***

    function balanceOf(address account, address token) external view returns (uint256) {
        return _balances[account][token];
    }

    function reserveOf(address account, address token) external view returns (uint256) {
        return _reserves[account][token];
    }

    function getTreasuryAmount(address token) external view returns (uint256) {
        return _treasuries[token];
    }

    /**
     * @dev Returns the address of the current treasury.
     */
    function treasury() public view returns (address) {
        return _treasury;
    }

    /**
     * @dev Check whether the address is an operator
     */
    function isOperator(address operator) public view returns (bool) {
        return _operators[operator];
    }

    // *** PUBLIC ***

    function deposit(address token, uint256 amount) external nonReentrant notPaused {
        require(isSupportedToken(token), '!token');

        uint256 balBefore = IBEP20(token).balanceOf(address(this));
        IBEP20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 balAfter = IBEP20(token).balanceOf(address(this));
        uint256 actualReceived = balAfter.sub(balBefore);

        uint256 depositFeeAmount = actualReceived.mul(depositFee).div(depositFeeBase); 
        _balances[msg.sender][token] = _balances[msg.sender][token].add(actualReceived.sub(depositFeeAmount));
        _treasuries[token] = _treasuries[token].add(depositFeeAmount);

        emit Deposit(msg.sender, token, actualReceived);
    }

    function depositBNB(uint256 amount) external payable nonReentrant notPaused {
        require(msg.value == amount, '!amount');

        uint256 depositFeeAmount = amount.mul(depositFee).div(depositFeeBase); 
        _balances[msg.sender][_wbnb] = _balances[msg.sender][_wbnb].add(amount.sub(depositFeeAmount));
        _treasuries[_wbnb] = _treasuries[_wbnb].add(depositFeeAmount);

        wrap(amount);
        emit Deposit(msg.sender, _wbnb, amount);
    }

    function withdraw(address token, uint256 amount) external nonReentrant {
        require(_balances[msg.sender][token] >= amount, '!amount');

        _balances[msg.sender][token] = _balances[msg.sender][token].sub(amount);

        IBEP20(token).safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, token, amount);
    }

    function withdrawBNB(uint256 amount) external nonReentrant {
        require(_balances[msg.sender][_wbnb] >= amount, '!amount');

        _balances[msg.sender][_wbnb] = _balances[msg.sender][_wbnb].sub(amount);

        unwrap(amount);
        msg.sender.transfer(amount);
        emit Withdraw(msg.sender, _wbnb, amount);
    }

    // *** INTERNAL ***
    
    function isSupportedToken(address token) public view returns (bool tokenImplemented) {
        tokenImplemented = false;
        
        for (uint i = 0; i < supportedTokens.length; i++) {
            if (supportedTokens[i].implementation == token && supportedTokens[i].active) {
                tokenImplemented = true;
            }
        }
    }

    function wrap(uint256 amount) internal {
        IWBNB(_wbnb).deposit{value: amount}();
    }

    function unwrap(uint256 amount) internal {
        IWBNB(_wbnb).withdraw(amount);
    }

    // *** OPERATOR ***

    function reserve(uint256 matchId, address[] memory players, address[] memory tokens, uint256[] memory amounts) external onlyOperator notPaused {
        require(players.length == tokens.length && tokens.length == amounts.length, "Hub: invalid parameters");
        require(!_matches[matchId].exists, "Hub: match already started");

        for (uint256 index = 0; index < players.length; index++) {
            require(isSupportedToken(tokens[index]), '!token');
            address token = tokens[index];
            uint256 amount = amounts[index];

            require(_balances[players[index]][token] >= amount, '!amount');
            _balances[players[index]][token] = _balances[players[index]][token].sub(amount);
            _reserves[players[index]][token] = _reserves[players[index]][token].add(amount);
            emit TokensReserved(matchId, players[index], token, amount);
        }

        _matches[matchId].exists = true;
        _matches[matchId].status = MatchStatus.Started;
    }

    function release(uint256 matchId, address[] memory players, address[] memory tokens, uint256[] memory amounts) external onlyOperator notPaused {
        require(players.length == tokens.length && tokens.length == amounts.length, "Hub: invalid parameters");
        require(_matches[matchId].status == MatchStatus.Started, "Hub: match not started");
        
        for (uint256 index = 0; index < players.length; index++) {
            address token = tokens[index];
            uint256 amount = amounts[index];

            require(_reserves[players[index]][token] >= amount, '!amount');

            _reserves[players[index]][token] = _reserves[players[index]][token].sub(amount);
            _balances[players[index]][token] = _balances[players[index]][token].add(amount);
            emit TokensReleased(matchId, players[index], token, amount);
        }

        _matches[matchId].status = MatchStatus.Cancelled;
    }

    function declare(uint256 matchId, address[] memory players, address[] memory tokens, uint256[] memory amounts) external onlyOperator {
        require(_matches[matchId].status == MatchStatus.Started, "Hub: match not started");
        require(_reserves[players[0]][tokens[0]] >= amounts[0], 'Hub: winner amount');
        require(_reserves[players[1]][tokens[1]] >= amounts[1], 'Hub: loser amount');

        // remove loser's amount from reserve balance and credit referral & treasury
        _reserves[players[1]][tokens[1]] = _reserves[players[1]][tokens[1]].sub(amounts[1]);
        _treasuries[tokens[1]] = _treasuries[tokens[1]].add(amounts[5]);
        if (amounts[3] > 0) {
            _balances[players[3]][tokens[1]] = _balances[players[3]][tokens[1]].add(amounts[3]);
        }

        uint256 loser_payout = amounts[1]
            .sub(amounts[5])
            .sub(amounts[3]);

        uint256 winner_payout = amounts[0]
            .sub(amounts[4])
            .sub(amounts[2]);
        
        // remove winner's amount from reserve balance, credit referral & treasury
        _reserves[players[0]][tokens[0]] = _reserves[players[0]][tokens[0]].sub(amounts[0]);
        _balances[players[0]][tokens[0]] = _balances[players[0]][tokens[0]].add(winner_payout);
        _treasuries[tokens[0]] = _treasuries[tokens[0]].add(amounts[4]);
        if (amounts[2] > 0) {
            _balances[players[2]][tokens[0]] = _balances[players[2]][tokens[0]].add(amounts[2]);
        }

        // add what he won from the other player
        _balances[players[0]][tokens[1]] = _balances[players[0]][tokens[1]].add(loser_payout);

        emit Declare(
            matchId,
            players[0], 
            players[1], 
            players[2], 
            players[3], 
            tokens[0], 
            tokens[1], 
            amounts[0], 
            amounts[1], 
            amounts[4], 
            amounts[5], 
            amounts[2], 
            amounts[3]
        );

        _matches[matchId].status = MatchStatus.Finished;
    }

    // *** RESTRICTED ***

    function claimFromTreasury(address token, uint256 amount) external onlyTreasury {
        require(_treasury != address(0), "Hub: treasury zero address");
        require(amount > 0, "Hub: zero amount");
        uint256 balance = IBEP20(token).balanceOf(address(this));

        if (_treasuries[token] >= amount && balance >= amount) {
            _treasuries[token] = _treasuries[token].sub(amount);
            IBEP20(token).safeTransfer(_treasury, amount);
        }
    }

    function setDepositFee(uint256 newDepositFee) external onlyOwner {
        require(newDepositFee <= depositFeeMax, '!depositFeeMax');
        depositFee = newDepositFee;
    }

    function setTreasury(address treasury_) external onlyOwner {
        require(treasury_ != address(0), "Hub: treasury zero address");
        _treasury = treasury_;
    }

    function addOperator(address operator_) external onlyOwner notPaused {
        require(operator_ != address(0), "Hub: operator zero address");
        _operators[operator_] = true;
    }

    function removeOperator(address operator_) external onlyOwner {
        _operators[operator_] = false;
    }

    function addSupportedToken(address implementation) public onlyOwner notPaused {
        supportedTokens.push(SupportedToken(implementation, true));
    }

    function updateTokenImplementation(uint256 index, address newImplementation) external onlyOwner {
        supportedTokens[index].implementation = newImplementation;
    }

    function enableToken(uint256 index) external onlyOwner notPaused {
        supportedTokens[index].active = true;
    }

    function disableToken(uint256 index) external onlyOwner {
        supportedTokens[index].active = false;
    }

    // *** MODIFIERS ***

    modifier onlyTreasury() {
        require(_treasury == _msgSender(), "Hub: caller is not the treasury");
        _;
    }

    modifier onlyOperator() {
        require(_operators[_msgSender()] == true, "Hub: caller is not an operator");
        _;
    }
}