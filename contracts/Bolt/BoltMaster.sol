// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./IStrategy.sol";
import "./IBoltMaster.sol";

contract BoltMaster is Ownable, ReentrancyGuard, IBoltMaster {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many amount tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    struct PoolInfo {
        address want; // Address of the want token.
        uint256 accumulatedYieldPerShare; // Accumulated per share, times 1e12. See below.
        address strat; // Strategy address that will compound want tokens
    }

    // BTD Address
    address public yieldToken;

    // Cake Address
    address public depositToken;
    // Dev address.
    address public devaddr;

    // Yield that came from strategy, yet to run through updatepool
    uint256 private unDistributedYield;

    address private burnAddress = 0x0000000000000000000000000000000000000000;

    PoolInfo public poolInfo;
    mapping(address => UserInfo) public userInfo; // Info of each user that stakes LP tokens.

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    constructor(address _depositToken, address _yieldToken) {
        yieldToken = _yieldToken;
        depositToken = _depositToken;
        unDistributedYield = 0;

        poolInfo = PoolInfo({
            want: _depositToken,
            accumulatedYieldPerShare: 0,
            strat: burnAddress
        });
    }

    function _pendingYield(address _user) 
        private
        view
        returns (uint256)
    {
        UserInfo storage user = userInfo[_user];
        return poolInfo.accumulatedYieldPerShare.mul(user.amount).sub(user.rewardDebt);
    }

    // View function to see pending on frontend.
    function pendingYield(address _user)
        external        
        view
        returns (uint256)
    {
        UserInfo storage user = userInfo[_user];
        return poolInfo.accumulatedYieldPerShare.mul(user.amount).sub(user.rewardDebt);
    }

    address private LastDepositor;
    uint256 private LastDepositAmount;

    function setPool(address newStrat) 
        public
        onlyOwner   
     {
        poolInfo.strat = newStrat;
    }

    function AcceptYield(uint256 _yieldAmount) override 
        nonReentrant
        external 
    {
        require(msg.sender == poolInfo.strat, "!strategy"); 
        unDistributedYield = _yieldAmount;
        IERC20(yieldToken).transferFrom(poolInfo.strat, address(this), _yieldAmount);
    }


    // Update reward variables of the given pool to be up-to-date.
    // Because yield from external pools isn't deterministic, we have to update users after the next deposit/witdraw.
    // Pay attention at test time, this could be exploitable
    function updatePool() private {
        uint256 shares = IStrategy(poolInfo.strat).DepositedLockedTotal();

        if (shares > 0) {
            UserInfo storage lastDepositor = userInfo[LastDepositor];


            if (shares != LastDepositAmount) {
                // Distribute the yield
                poolInfo.accumulatedYieldPerShare = poolInfo.accumulatedYieldPerShare.add(
                    unDistributedYield.div(shares.sub(LastDepositAmount)));
                lastDepositor.rewardDebt =
                    lastDepositor.amount.mul(poolInfo.accumulatedYieldPerShare);
            }
            unDistributedYield = 0;
        }
    }

    function deposit(uint256 _pid, uint256 _wantAmt) public nonReentrant {
        updatePool();
        UserInfo storage user = userInfo[msg.sender];

        if (user.amount > 0) {
            // Send them what we owe them.
            uint256 pending = _pendingYield(msg.sender);
            IERC20(yieldToken).safeTransfer(
                address(msg.sender),
                pending
            );
        }
        if (_wantAmt > 0) {
            // Get from user
            IERC20(poolInfo.want).safeTransferFrom(
                address(msg.sender),
                address(this),
                _wantAmt
            );
            uint256 amount = _wantAmt;



            // Send deposit to strategy.
            IERC20(poolInfo.want).safeIncreaseAllowance(poolInfo.strat, amount);
            uint256 amountDeposit = IStrategy(poolInfo.strat).deposit(amount);

            // Track user deposit
            user.amount = user.amount.add(amountDeposit);
        }

        user.rewardDebt = user.amount.mul(poolInfo.accumulatedYieldPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _wantAmt);
    }

    // Withdraw LP tokens from BoltMaster.
    function withdraw(uint256 _pid, uint256 _wantAmt) public nonReentrant {
        updatePool();
        PoolInfo storage pool = poolInfo;
        UserInfo storage user = userInfo[msg.sender];
        uint256 total = IStrategy(pool.strat).DepositedLockedTotal();
        require(user.amount > 0, "user.amount is 0");
        require(total > 0, "Total is 0");
        // // Withdraw pending yield
        uint256 pending =
            user.amount.mul(pool.accumulatedYieldPerShare).div(1e12).sub(
                user.rewardDebt
            );
        if (pending > 0) {
            safeTransfer(msg.sender, pending);
        }
        // // Withdraw want tokens
         uint256 amount = user.amount;
        if (_wantAmt > amount) {
            _wantAmt = amount;
        }
        if (_wantAmt > 0) {
            uint256 amountRemove =
                IStrategy(pool.strat).withdraw(_wantAmt);
            if (amountRemove > user.amount) {
                user.amount = 0;
            } else {
                user.amount = user.amount.sub(amountRemove);
            }
            uint256 wantBal = IERC20(pool.want).balanceOf(address(this));
            if (wantBal < _wantAmt) {
                _wantAmt = wantBal;
            }
            IERC20(pool.want).safeTransfer(address(msg.sender), _wantAmt);
        }
        user.rewardDebt = user.amount.mul(pool.accumulatedYieldPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _wantAmt);
    }

    // Safe transfer function, just in case if rounding error causes pool to not have enough
    function safeTransfer(address _to, uint256 yieldAmount) internal {
        uint256 thisYieldBalance = IERC20(yieldToken).balanceOf(address(this));
        if (yieldAmount > thisYieldBalance) {
            IERC20(yieldToken).transfer(_to, thisYieldBalance);
        } else {
            IERC20(yieldToken).transfer(_to, yieldAmount);
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo;
        UserInfo storage user = userInfo[msg.sender];

        uint256 amount = user.amount;

        IStrategy(pool.strat).withdraw(amount);

        user.amount = 0;
        user.rewardDebt = 0;
        IERC20(pool.want).safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function inCaseTokensGetStuck(address _token, uint256 _amount)
        public
        onlyOwner
    {
        require(_token != depositToken, "!safe");
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }
}
