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
    ) {
        if (dispatcher_ == address(0) || feeRecipient_ == address(0)) revert GR_ZeroAddress();
        dispatcher = dispatcher_;
        feeRecipient = feeRecipient_;
        genesisBlock = block.number;
        chainTag = keccak256(
            abi.encodePacked(
                block.chainid,
                address(this),
                block.prevrandao,
                block.timestamp,
                "GogoRapido_DriveLedger_v1"
            )
        );
        maxWaypointsPerTrip = maxWaypointsPerTrip_ == 0 ? 72 : maxWaypointsPerTrip_;
        minSpeedKmh = minSpeedKmh_ == 0 ? 1 : minSpeedKmh_;
        maxSpeedKmh = maxSpeedKmh_ == 0 ? 240 : maxSpeedKmh_;
        tripCooldownBlocks = tripCooldownBlocks_ == 0 ? 8 : tripCooldownBlocks_;
        feeBasisPoints = feeBasisPoints_ > 10000 ? 0 : feeBasisPoints_;
        maxTripDurationBlocks = maxTripDurationBlocks_ == 0 ? 7200 : maxTripDurationBlocks_;
        minWaypointDistanceMeters = minWaypointDistanceMeters_ == 0 ? 50 : minWaypointDistanceMeters_;
    }

    function registerDriver() external whenNotPaused {
        DriverProfile storage profile = drivers[msg.sender];
        if (profile.registered) revert GR_AlreadyDriver();
        profile.registered = true;
        profile.joinedBlock = block.number;
        _driverList.push(msg.sender);
        totalDrivers += 1;
        emit RapidoDriverOnboarded(msg.sender, block.number);
    }

    function startTrip() external whenNotPaused nonReentrant returns (uint256 tripId) {
        DriverProfile storage profile = drivers[msg.sender];
        if (!profile.registered) revert GR_NotDriver();
        if (profile.lastTripBlock != 0 && block.number < profile.lastTripBlock + tripCooldownBlocks) {
            revert GR_CooldownActive();
        }
        totalTrips += 1;
        tripId = totalTrips;
        Trip storage t = trips[tripId];
        t.active = true;
        t.driver = msg.sender;
        t.startBlock = block.number;
        t.tripId = tripId;
        _driverTripIds[msg.sender].push(tripId);
        _tripIdToDriver[tripId] = msg.sender;
        profile.lastTripBlock = block.number;
        emit RapidoTripOpened(msg.sender, tripId, block.number);
        return tripId;
    }

    function logWaypoint(
        uint256 tripId_,
        uint256 latE6,
        uint256 lonE6,
        uint256 speedKmh,
        uint256 metersFromStart
    ) external whenNotPaused {
        Trip storage t = trips[tripId_];
        if (!t.active) revert GR_TripNotActive();
        if (t.driver != msg.sender && msg.sender != dispatcher) revert GR_NotDriver();
        if (speedKmh < minSpeedKmh || speedKmh > maxSpeedKmh) revert GR_SpeedOutOfRange();
        if (t.waypointCount >= maxWaypointsPerTrip) revert GR_ExceedsMaxWaypoints();
        if (block.number - t.startBlock > maxTripDurationBlocks) revert GR_TripDurationExceeded();
        if (t.waypointCount > 0) {
            WaypointLog storage prev = tripWaypoints[tripId_][t.waypointCount - 1];
            if (metersFromStart <= prev.metersFromStart || metersFromStart - prev.metersFromStart < minWaypointDistanceMeters) {
                revert GR_InvalidWaypointSequence();
            }
        } else if (metersFromStart != 0) {
            revert GR_InvalidWaypointSequence();
        }
        uint256 idx = t.waypointCount;
        tripWaypoints[tripId_][idx] = WaypointLog({
            blockNumber: block.number,
            timestamp: block.timestamp,
            latE6: latE6,
            lonE6: lonE6,
            speedKmh: speedKmh,
            metersFromStart: metersFromStart
        });
        t.waypointCount += 1;
        t.totalMeters = metersFromStart;
        if (speedKmh > t.maxSpeedLogged) t.maxSpeedLogged = speedKmh;
        DriverProfile storage profile = drivers[msg.sender];
        if (speedKmh > profile.bestMaxSpeedKmh) profile.bestMaxSpeedKmh = speedKmh;
        emit RapidoWaypointLogged(tripId_, idx, speedKmh, metersFromStart);
    }

    function endTrip(uint256 tripId_) external whenNotPaused nonReentrant {
        Trip storage t = trips[tripId_];
        if (!t.active) revert GR_TripNotActive();
        if (t.driver != msg.sender) revert GR_NotDriver();
        t.active = false;
        t.endBlock = block.number;
        uint256 feeWei = 0;
        if (feeBasisPoints > 0 && t.totalMeters >= minWaypointDistanceMeters) {
            feeWei = (t.totalMeters * feeBasisPoints) / 10000;
            if (feeWei > address(this).balance) feeWei = address(this).balance;
            t.feePaid = feeWei;
            if (feeWei > 0 && feeRecipient != address(0)) {
                (bool ok,) = feeRecipient.call{value: feeWei}("");
                if (!ok) revert GR_TransferFailed();
                emit RapidoFeeWithdrawn(feeRecipient, feeWei);
            }
        }
        DriverProfile storage profile = drivers[msg.sender];
        profile.tripCount += 1;
        profile.totalMetersDriven += t.totalMeters;
        emit RapidoRideFinalized(tripId_, msg.sender, t.totalMeters, feeWei);
    }

    function setPaused(bool paused_) external onlyDispatcher {
        tripRegistryPaused = paused_;
        emit RapidoRegistryPauseChanged(paused_);
    }

    function getTrip(uint256 tripId_)
        external
        view
        returns (
            bool active,
            address driver,
            uint256 startBlock,
            uint256 endBlock,
            uint256 waypointCount,
            uint256 totalMeters,
            uint256 maxSpeedLogged,
            uint256 feePaid
        )
    {
        Trip storage t = trips[tripId_];
        return (
            t.active,
            t.driver,
            t.startBlock,
            t.endBlock,
            t.waypointCount,
            t.totalMeters,
            t.maxSpeedLogged,
            t.feePaid
        );
    }

    function getWaypoint(uint256 tripId_, uint256 index)
        external
        view
        returns (
            uint256 blockNumber,
            uint256 timestamp,
            uint256 latE6,
            uint256 lonE6,
            uint256 speedKmh,
            uint256 metersFromStart
        )
    {
        WaypointLog storage w = tripWaypoints[tripId_][index];
        return (
            w.blockNumber,
            w.timestamp,
            w.latE6,
            w.lonE6,
            w.speedKmh,
            w.metersFromStart
        );
    }

    function getDriverProfile(address driver_)
        external
        view
        returns (
            bool registered,
            uint256 tripCount,
            uint256 totalMetersDriven,
            uint256 lastTripBlock,
            uint256 bestMaxSpeedKmh,
            uint256 joinedBlock
        )
    {
        DriverProfile storage p = drivers[driver_];
        return (
            p.registered,
            p.tripCount,
            p.totalMetersDriven,
            p.lastTripBlock,
            p.bestMaxSpeedKmh,
            p.joinedBlock
        );
    }

