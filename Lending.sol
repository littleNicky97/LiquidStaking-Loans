// SPDX-License-Identifier: MIT
pragma solidity ^0.8.1;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../Token/CitadelToken.sol";
import "./CreditScore.sol";

contract TestLendingNFT is ERC721, Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;
    using SafeMath for uint256;

    Counters.Counter private _tokenIdTracker;

    CitadelToken public rewardToken;
    TestCreditScoreNFT public CreditScore;

    uint256 private constant SECONDS_IN_YEAR = 31536000;
    uint256 public constant REWARD_MULTIPLIER = 20;
    uint256 private constant INTEREST_RATE = 5; // 5% interest rate
    uint256 private constant LOAN_DURATION = 1 weeks;
    uint256 private constant LOAN_PERCENTAGE = 90; // 90% of staked amount
    uint256 private _totalStaked; // New variable to keep track of the total staked amount
    uint256 private _totalLoaned; // New variable to keep track of the total loaned amount

    string private _defaultTokenURI; // New state variable for the default tokenURI

    event Staked(address indexed account, uint256 amount, uint256 tokenId);
    event Unstaked(address indexed account, uint256 amount);
    event RewardsClaimed(address indexed account, uint256 rewardAmount);
    event LoanTaken(address indexed account, uint256 amount);
    event LoanPaidBack(address indexed account, uint256 amount);

    mapping(address => uint256) private _stakes;
    mapping(address => uint256) private _unstakes; // New mapping for unstaked ETH
    mapping(address => uint256) private _userTokenId;
    mapping(address => uint256) private _lastClaimed;
    mapping(address => uint256) private _loanBalances;
    mapping(address => uint256) private _loanTimestamps;

    constructor(CitadelToken _rewardToken, TestCreditScoreNFT _creditScoreNFT, string memory _uri) ERC721("CitadelLoans", "CTLN") {
        rewardToken = _rewardToken;
        CreditScore = _creditScoreNFT;
        _defaultTokenURI = _uri;
    }

    function setDefaultTokenURI(string memory uri) public onlyOwner {
        _defaultTokenURI = uri;
    }

    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(_exists(tokenId), "Token ID does not exist");
        return _defaultTokenURI;
    }

    function stake() public payable {
        require(msg.value > 0, "Must stake a positive amount of ETH");
        _stakes[msg.sender] += msg.value;
        _totalStaked += msg.value; // Update the total staked amount

        if (!_exists(_userTokenId[msg.sender])) {
            _tokenIdTracker.increment();
            uint256 newTokenId = _tokenIdTracker.current();
            _safeMint(msg.sender, newTokenId);
            _userTokenId[msg.sender] = newTokenId;
        }

        if (_lastClaimed[msg.sender] == 0) {
            _lastClaimed[msg.sender] = block.timestamp;
        }

        emit Staked(msg.sender, msg.value, _userTokenId[msg.sender]);
    }

    function unstake(uint256 amount) public nonReentrant {
        require(amount > 0, "Must unstake a positive amount of ETH");
        require(_stakes[msg.sender] >= amount, "Insufficient staked balance");

        // Prevent unstaking if the user has an active loan or if the loan is overdue
        int256 loanStatus = checkLoanStatus(msg.sender);
        if (_loanBalances[msg.sender] > 0 && loanStatus <= 0) {
            if (loanStatus == 0) {
                // If the loan is overdue, terminate the user's NFT and stake
                terminateLoan(msg.sender);
            }
            revert("Cannot unstake while having an active or overdue loan");
        }

        _stakes[msg.sender] -= amount;
        _unstakes[msg.sender] += amount; // Update the unstakes mapping

        // Automatically claim rewards if the user unstakes their full amount
        if (_stakes[msg.sender] == 0) {
            // Call claimRewards function if there are pending rewards
            if (getPendingRewards(msg.sender) > 0) {
                claimRewards();
            }
            if (_exists(_userTokenId[msg.sender])) {
                _burn(_userTokenId[msg.sender]);
                delete _userTokenId[msg.sender];
            }
        }

        payable(msg.sender).transfer(amount);
        emit Unstaked(msg.sender, amount);
    }


    function claimRewards() public nonReentrant {
        require(_loanBalances[msg.sender] == 0, "Cannot claim rewards while having an active loan");
        uint256 pendingRewards = getPendingRewards(msg.sender);
        require(pendingRewards > 0, "No pending rewards");

        rewardToken.mint(msg.sender, pendingRewards);
        _lastClaimed[msg.sender] = block.timestamp;

        emit RewardsClaimed(msg.sender, pendingRewards);
    }


    function getPendingRewards(address account) public view returns (uint256) {
        if (_stakes[account] == 0) {
            return 0;
        }

        uint256 timeDifference = block.timestamp - _lastClaimed[account];
        uint256 pendingRewards = (_stakes[account] * timeDifference * REWARD_MULTIPLIER) / SECONDS_IN_YEAR;

        return pendingRewards;
    }

    function canTakeLoan(address user) public view returns (bool) {
        return _stakes[user] > 0
            && _loanBalances[user] == 0
            && _exists(_userTokenId[user])
            && CreditScore.balanceOf(user) > 0;
    }

    function takeLoan() public {
        require(canTakeLoan(msg.sender), "Must meet the requirements to take a loan");

        uint256 loanAmount = _stakes[msg.sender].mul(LOAN_PERCENTAGE).div(100);
        _loanBalances[msg.sender] = loanAmount.add(loanAmount.mul(INTEREST_RATE).div(100));
        _totalLoaned += _loanBalances[msg.sender];
        _loanTimestamps[msg.sender] = block.timestamp;

        CreditScore.lockNFT(_userTokenId[msg.sender], msg.sender); // Lock the user's CreditScoreNFT

        payable(msg.sender).transfer(loanAmount);

        emit LoanTaken(msg.sender, loanAmount);
    }

    function payBackLoan() public payable nonReentrant {
        require(_loanBalances[msg.sender] > 0, "No active loan to repay");
        require(msg.value > 0, "Must send a positive amount of ETH");

        // Check if the loan is overdue
        int256 loanStatus = checkLoanStatus(msg.sender);
        if (loanStatus == 0) {
            // If the loan is overdue, terminate the user's NFT and stake
            terminateLoan(msg.sender);
            // Refund the amount paid in excess of the overdue loan
            if (msg.value > 0) {
                payable(msg.sender).transfer(msg.value);
            }
            return;
        }

        // Update the user's credit score
        if (loanStatus > 0) {
            CreditScore.unlockNFT(_userTokenId[msg.sender]); // Unlock the user's CreditScoreNFT
            CreditScore.updateCreditScore(_userTokenId[msg.sender], 2);
        } else {
            CreditScore.updateCreditScore(_userTokenId[msg.sender], -2);
            CreditScore.unlockNFT(_userTokenId[msg.sender]);
        }

        require(msg.value >= _loanBalances[msg.sender], "Insufficient repayment amount");

        uint256 repaymentAmount = _loanBalances[msg.sender];
        uint256 interestAmount = repaymentAmount.mul(INTEREST_RATE).div(100 + INTEREST_RATE); // Calculate the 5% interest

        _totalLoaned -= _loanBalances[msg.sender]; // Update the total loaned amount
        _loanBalances[msg.sender] = 0;
        _loanTimestamps[msg.sender] = 0;

        if (msg.value > repaymentAmount) {
            // Refund excess amount
            payable(msg.sender).transfer(msg.value - repaymentAmount);
        } else {
            // Send the principal amount back to the user
            payable(msg.sender).transfer(msg.value - interestAmount);
        }

        emit LoanPaidBack(msg.sender, repaymentAmount);
    }

    function checkLoanStatus(address account) public view returns (int256) {
        if (_loanBalances[account] == 0) {
            return -1; // No active loan
        }

        uint256 deadline = _loanTimestamps[account].add(LOAN_DURATION);
    
        if (block.timestamp > deadline) {
            return 0; // Loan is overdue
        }

        return int256(deadline - block.timestamp); // Time left for the loan
    }

    function terminateLoan(address account) internal {
        _loanBalances[account] = 0;
        _loanTimestamps[account] = 0;

        // Burn NFT and set the user's stake amount to 0
        if (_exists(_userTokenId[account])) {
            _burn(_userTokenId[account]);
            delete _userTokenId[account];
        }
        _stakes[account] = 0;
    }

    function stakedBalanceOf(address account) public view returns (uint256) {
        return _stakes[account];
    }

    function loanBalanceOf(address account) public view returns (uint256) {
        return _loanBalances[account];
    }

    function getLastClaimed(address account) public view returns (uint256) {
        return _lastClaimed[account];
    }

    function getUserTokenId(address account) public view returns (uint256) {
        require(_exists(_userTokenId[account]), "User does not have a tokenID");
        return _userTokenId[account];
    }

    function withdrawExcessETH(uint256 amount) public onlyOwner {
        require(amount > 0, "Must withdraw a positive amount of ETH");

        uint256 contractBalance = address(this).balance;
        uint256 totalStakedAndLoaned = getTotalStakedAndLoaned();

        require(contractBalance > totalStakedAndLoaned, "No excess ETH balance in the contract");
        uint256 excessBalance = contractBalance.sub(totalStakedAndLoaned);

        require(excessBalance >= amount, "Insufficient excess ETH balance in the contract");

        payable(msg.sender).transfer(amount);
    }

    function getTotalStakedAndLoaned() internal view returns (uint256) {
        return _totalStaked.add(_totalLoaned);
    }

    function totalStaked() public view returns (uint256) {
        return _totalStaked;
    }

    function withdrawOverdueLoans(uint256 startTokenId, uint256 endTokenId) public onlyOwner {
        require(startTokenId > 0, "Start token ID must be greater than 0");
        require(endTokenId >= startTokenId, "End token ID must be greater than or equal to the start token ID");
        require(endTokenId <= _tokenIdTracker.current(), "End token ID must not exceed the highest token ID");

        uint256 overdueLoansTotal = 0;

        for (uint256 i = startTokenId; i <= endTokenId; i++) {
            if (!_exists(i)) {
                continue;
            }

            address account = ownerOf(i);
            if (checkLoanStatus(account) == 0) { // Check if the loan is overdue
                overdueLoansTotal += _loanBalances[account];
                terminateLoan(account);
            }
        }

        require(overdueLoansTotal > 0, "No overdue loans to withdraw in the specified range");
        payable(msg.sender).transfer(overdueLoansTotal);
    }

}
