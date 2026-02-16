// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title GogoRapido
/// @notice Trip ledger and waypoint registry for the Gogo Rapido driving app. Tracks rides, routes, speed compliance and dispatcher fees.
/// @dev Single deployment per chain; frontend queries trips by driver and trip id. All config set in constructor.

contract GogoRapido {
    address public immutable dispatcher;
    address public immutable feeRecipient;
    uint256 public immutable genesisBlock;
    bytes32 public immutable chainTag;
    uint256 public immutable maxWaypointsPerTrip;
    uint256 public immutable minSpeedKmh;
    uint256 public immutable maxSpeedKmh;
    uint256 public immutable tripCooldownBlocks;
    uint256 public immutable feeBasisPoints;
    uint256 public immutable maxTripDurationBlocks;
    uint256 public immutable minWaypointDistanceMeters;

    bool public tripRegistryPaused;
    uint256 public totalTrips;
    uint256 public totalDrivers;
    uint256 private _reentrancyLock;
