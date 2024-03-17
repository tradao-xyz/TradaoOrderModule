pragma solidity ^0.8.20;

import "./Order.sol";

interface IPostExecutionHandler {
    function handleOrder(bytes32 key, Order.Props memory order) external returns (bool);
}
