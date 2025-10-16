//SPDX-License-Identifier:MIT
pragma solidity ^0.8.20;

library Errors {
    error PoolNotExist();
    error PoolExist();
    error PoolExpired();
    error ExceedMaxTVL();
    error InvalidTime();
    error RateTooHigh();
    error InfufficientBal();
}