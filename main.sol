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

    struct Trip {
        bool active;
        address driver;
        uint256 startBlock;
        uint256 endBlock;
        uint256 waypointCount;
        uint256 totalMeters;
        uint256 maxSpeedLogged;
        uint256 feePaid;
        uint256 tripId;
    }

    struct WaypointLog {
        uint256 blockNumber;
        uint256 timestamp;
        uint256 latE6;
        uint256 lonE6;
        uint256 speedKmh;
        uint256 metersFromStart;
    }

    struct DriverProfile {
        bool registered;
        uint256 tripCount;
        uint256 totalMetersDriven;
        uint256 lastTripBlock;
        uint256 bestMaxSpeedKmh;
        uint256 joinedBlock;
    }

    struct RouteSummary {
        uint256 tripId;
        uint256 waypoints;
        uint256 meters;
        uint256 durationBlocks;
    }

    mapping(uint256 => Trip) public trips;
    mapping(uint256 => mapping(uint256 => WaypointLog)) public tripWaypoints;
    mapping(address => DriverProfile) public drivers;
    mapping(address => uint256[]) private _driverTripIds;
    mapping(uint256 => address) private _tripIdToDriver;
    address[] private _driverList;

    event RapidoTripOpened(address indexed driver, uint256 indexed tripId, uint256 startBlock);
    event RapidoWaypointLogged(uint256 indexed tripId, uint256 waypointIndex, uint256 speedKmh, uint256 metersCumul);
    event RapidoRideFinalized(uint256 indexed tripId, address indexed driver, uint256 totalMeters, uint256 feeWei);
    event RapidoDriverOnboarded(address indexed driver, uint256 joinedBlock);
    event RapidoRegistryPauseChanged(bool paused);
    event RapidoFeeWithdrawn(address indexed recipient, uint256 amountWei);
    event RapidoDispatcherUpdated(address indexed previousDispatcher, address indexed newDispatcher);

    error GR_OnlyDispatcher();
    error GR_TripNotActive();
    error GR_TripAlreadyEnded();
    error GR_InvalidWaypointSequence();
    error GR_SpeedOutOfRange();
    error GR_ZeroAddress();
    error GR_RegistryPaused();
    error GR_CooldownActive();
    error GR_AlreadyDriver();
    error GR_NotDriver();
    error GR_Reentrancy();
    error GR_ExceedsMaxWaypoints();
    error GR_TripDurationExceeded();
    error GR_DistanceTooShort();
    error GR_TransferFailed();

    modifier onlyDispatcher() {
        if (msg.sender != dispatcher) revert GR_OnlyDispatcher();
        _;
    }

    modifier whenNotPaused() {
        if (tripRegistryPaused) revert GR_RegistryPaused();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock != 0) revert GR_Reentrancy();
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    constructor(
        address dispatcher_,
        address feeRecipient_,
        uint256 maxWaypointsPerTrip_,
        uint256 minSpeedKmh_,
        uint256 maxSpeedKmh_,
        uint256 tripCooldownBlocks_,
        uint256 feeBasisPoints_,
        uint256 maxTripDurationBlocks_,
        uint256 minWaypointDistanceMeters_
