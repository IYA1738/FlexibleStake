//SPDX-License-Identifier:MIT
pragma solidity 0.8.22;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "./libraries/Errors.sol";
import "./libraries/Constants.sol";
contract FlexibleStake is AccessControl, Pausable{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using Math for uint256;
    struct Pool{
        //------pack to slot 1
        address token;
        uint48 lastUpdateTime;
        uint48 periodEnd;
        //------
        uint256 totalStaked;
        uint256 rewardPerToken; 
        uint256 rptWithPlatformToken; //platform token
        uint256 maxTVL;
        //------ pack to last slot of the struct
        uint128 rate;
        uint128 rateWithPlatformToken; //platform token
        //------
    }

    struct User{
        uint256 amount;
        uint256 lastRPT;
        uint256 lastRPTWithPlatformToken;
        uint256 accrued;
        uint256 accruedWithPlatformToken;
    }

    Pool[] public pools; //index is poolId
    mapping(uint256=>mapping(address=>User)) public users; //poolId  => user address => User info
    mapping(address=>uint256) public pidOfToken; // token address => poolId + 1
    mapping(uint256=>address) public pidToToken; // poolId => token address

    address public platformToken;

    uint256 public constant SCALE = 10 ** 18; 
    uint8 private _unLocked = 1;

    event AddedPool(address indexed token);
    event Deposited(address indexed user, uint256 indexed pid, uint256 amount);
    event Claimed(address indexed user, uint256 indexed pid, uint256 amount, uint256 amountWithPlatformToken);
    event Withdrawn(address indexed user, uint256 indexed pid, uint256 amount);
    event NotifiedPool(uint256 indexed pid, uint256 newRate, uint256 newRateWithPlatformToken, uint256 newMaxTVL, uint48 newPeriodEnd);


    //The pid is real pid, it does not plus 1
    function deposit(uint256 pid, uint256 amount) external lock whenNotPaused{
        if(amount == 0){
            revert Errors.AmountZero();
        }
        if(pidToToken[pid + 1] == address(0)){
            revert Errors.PoolNotExist();
        }
        Pool storage pool = pools[pid];
        User storage user = users[pid][msg.sender];

        
        _updatePool(pid); //update pool state first

        //For supporting fee on transfer token
        uint256 before = IERC20(pool.token).balanceOf(address(this));
        IERC20(pool.token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(pool.token).balanceOf(address(this)) - before;

        if(pool.totalStaked + received > pool.maxTVL){
            revert Errors.ExceedMaxTVL();
        }
        // I settle rewards before adding new amount.
        // This way we don’t need an extra `if (user.amount > 0)` check.
        // On first deposit user.amount == 0, so even if Δrpt > 0,
        // the math gives 0 , no “free” rewards from before staking.
        _updateUser(pid, msg.sender);
        // accrued here is still in “scaled precision” (amount[wei] × rpt[ACC]).
        // skip dividing by ACC here to keep the hot path cheaper.
        // The real token amount will be `accrued / ACC` when claiming or previewing.
        user.amount += received;
        pool.totalStaked += received;
        emit Deposited(msg.sender,pid,received);
    }

    // Withdraw remains allowed while the contract is paused. Pausing is intended
    // to stop new deposits and standalone claims, but MUST NOT prevent users from
    // recovering their principal. For user fairness and funds safety, withdraw()
    // still settles and pays accrued rewards (up to the last update) and returns
    // the staked tokens, even during pause. This design choice avoids trapping user
    // funds while still letting the team halt new inflows or reward-only cashouts.
    function withdraw(uint256 pid, uint256 withdrawAmount) external lock{
        _claim(pid,false);
         //_claim will check pool exist
        User storage user = users[pid][msg.sender];
        Pool storage pool = pools[pid];
        if(withdrawAmount > user.amount){
            revert Errors.InfufficientBal();
        }
        if(uint48(block.timestamp) < pool.periodEnd){
            revert Errors.InvalidTime();
        }
        user.amount -= withdrawAmount;
        pool.totalStaked -= withdrawAmount;
        IERC20(pool.token).safeTransfer(msg.sender, withdrawAmount);
        emit Withdrawn(msg.sender, pid, withdrawAmount);
    }

    function claim(uint256 pid) external lock whenNotPaused{
        _claim(pid, true);
    }

    function _claim(uint256 pid, bool revertOnZero) internal{
        if(pidToToken[pid + 1] == address(0)){
            revert Errors.PoolNotExist();
        }
        Pool storage pool = pools[pid];
        User storage user = users[pid][msg.sender];

        _updatePool(pid);
        _updateUser(pid,msg.sender);
        uint256 claimable = user.accrued / SCALE;
        if(claimable == 0 && revertOnZero){
            revert Errors.InfufficientBal();
        }
        user.accrued = 0;

        //   `claimable` is the nominal reward amount (theoretical entitlement).
        //   If the reward token (pool.token) is fee-on-transfer, the user's
        //   actual received amount may be < `claimable`. This contract sends the
        //   nominal amount and does NOT gross-up for transfer taxes.
        if(claimable > 0)
            IERC20(pool.token).safeTransfer(msg.sender, claimable);

        uint256 claimableWithPlatformToken = user.accruedWithPlatformToken / SCALE;
        if(claimableWithPlatformToken > 0){
            user.accruedWithPlatformToken = 0;
            IERC20(platformToken).safeTransfer(msg.sender, claimableWithPlatformToken);
        }
        emit Claimed(msg.sender, pid, claimable, claimableWithPlatformToken);
    }

    //All units are in wei or seconds
    function notifyPool(uint256 pid, uint128 newRate, uint128 newRateWithPlatformToken, uint256 newMaxTVL, uint48 newPeriodEnd) external onlyRole(Constants.ROLE_TEAM){
        if(!_hasPool(pidToToken[pid + 1])){
            revert Errors.PoolNotExist();
        } //check pool exist
        if(newMaxTVL < pools[pid].totalStaked){
            revert Errors.ExceedMaxTVL();
        }
        // Guard against uint128 truncation when storing scaled rates (×1e18).
        if(newRate >= 3e20 || newRateWithPlatformToken >= 3e20){
            revert Errors.RateTooHigh();
        }
        uint48 now48=  block.timestamp.toUint48();
        if(newPeriodEnd <= now48){
            revert Errors.InvalidTime();
        }
        _updatePool(pid);
        Pool storage pool = pools[pid];
        
        uint48 leftoverSec  = (now48 >= pool.periodEnd ? 0 : pool.periodEnd - now48);

        uint256 leftoverRewardsScaled = uint256(pool.rate) * uint256(leftoverSec);
        uint256 leftoverRewardsWithPlatformTokenScaled = uint256(pool.rateWithPlatformToken) * uint256(leftoverSec);
        uint48 newDuration = newPeriodEnd - now48;

        uint256 newRateScaled = uint256(newRate) * SCALE + (newDuration > 0 ? leftoverRewardsScaled / uint256(newDuration) : 0);
        uint256 newRateWithPlatformTokenScaled = uint256(newRateWithPlatformToken) * SCALE + (newDuration > 0 ? leftoverRewardsWithPlatformTokenScaled / uint256(newDuration) : 0);

        pool.rate = uint128(newRateScaled) ;
        pool.rateWithPlatformToken = uint128(newRateWithPlatformTokenScaled);
        pool.maxTVL = newMaxTVL;
        pool.periodEnd = newPeriodEnd;
        pool.lastUpdateTime = now48;
        emit NotifiedPool(pid, pool.rate, pool.rateWithPlatformToken, newMaxTVL, newPeriodEnd);
    }

    function _updatePool(uint256 pid) internal{
        Pool storage pool = pools[pid];
        uint48 now48 =  block.timestamp.toUint48();
        uint48 end  = pool.periodEnd < now48 ? pool.periodEnd : now48;
        uint timeDiff = end - pool.lastUpdateTime;
        if(pool.totalStaked  > 0 && timeDiff > 0){
            pool.rewardPerToken += Math.mulDiv(uint256(pool.rate), timeDiff, pool.totalStaked, Math.Rounding.Down);
            pool.rptWithPlatformToken += Math.mulDiv(uint256(pool.rateWithPlatformToken), timeDiff, pool.totalStaked, Math.Rounding.Down);
        }
        pool.lastUpdateTime = end;
    }

   function _updateUser(uint256 pid, address account) internal{
        Pool memory pool = pools[pid];
        User storage user = users[pid][account];

        user.accrued += Math.mulDiv((pool.rewardPerToken - user.lastRPT) , user.amount, 1, Math.Rounding.Down); //For precision
        user.accruedWithPlatformToken += Math.mulDiv((pool.rptWithPlatformToken - user.lastRPTWithPlatformToken) , user.amount,1 ,Math.Rounding.Down);
        user.lastRPT = pool.rewardPerToken;
        user.lastRPTWithPlatformToken = pool.rptWithPlatformToken;
   }
    function addPool(address _token, uint256 _maxTVL,uint128 _rate, uint128 _rateWithPlatformToken, uint48 _periodEnd ) external onlyRole(Constants.ROLE_TEAM){
        if(_token == address(0)){
            revert Errors.ZeroAddress();
        }
        if (_rate >= 3e20 || _rateWithPlatformToken >= 3e20) {
            revert Errors.RateTooHigh();
        }
        uint48 now48=  block.timestamp.toUint48();
        if(_periodEnd <= now48){
            revert Errors.InvalidTime();
        }
        if(_maxTVL == 0){
            revert Errors.AmountZero();
        }
        if(_hasPool(_token)){
            revert Errors.PoolExist();
        }

        uint256 pid = pools.length;
        pools.push();
        Pool storage p = pools[pid];

        p.token = _token;
        p.rate = uint128(uint256(_rate) * SCALE);
        p.rateWithPlatformToken = uint128(uint256(_rateWithPlatformToken) * SCALE);
        p.periodEnd = _periodEnd;
        p.lastUpdateTime = now48;
        p.maxTVL = _maxTVL;
        //The other variables are initialized to zero by default

        pidOfToken[_token] = pid + 1; // Avoid pid 0 means not exist
        pidToToken[pid + 1] = _token; //Sync with pidOfToken
        
        emit AddedPool(_token);
    }

    function _hasPool(address token) internal view returns(bool){
        return pidOfToken[token] != 0;
    }

    function _pid(address token) internal view returns(uint256){
        uint256 pid = pidOfToken[token];
        if(pid == 0){
            revert Errors.PoolNotExist();
        }
        return pid - 1;
    }

    constructor(address _platformToken, address _pauseController){
        if(_platformToken == address(0) || _pauseController == address(0)){
            revert Errors.ZeroAddress();
        }
        platformToken = _platformToken;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.ROLE_TEAM, msg.sender);
        _grantRole(Constants.ROLE_PAUSE_CONTROLLER, _pauseController);
    }

    //Pause
    function pause() external onlyRole(Constants.ROLE_PAUSE_CONTROLLER){
        _pause();
    }

    function unpause() external onlyRole(Constants.ROLE_PAUSE_CONTROLLER){
        _unpause();
    }

    //Modifier
    //A minimum lock
    modifier lock(){
        require(_unLocked == 1, "Pool Locked");
        _unLocked = 2;
        _;
        _unLocked = 1;
    }

    fallback() external payable{
        revert("Not ETH");
    }

    receive() external payable{
        revert("Not ETH");
    }
}
