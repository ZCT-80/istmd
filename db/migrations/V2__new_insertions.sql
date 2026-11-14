INSERT INTO
    label_coarse_types (label_id, label_name)
VALUES
    (9, 'Ferry'),
    (10, 'Tram'),
    (11, 'Metrobus'),
    (12, 'Motorcycle'),
    (13, 'Minibus'),
    (14, 'E-Scooter'),
    (15, 'Taxi');

INSERT INTO
    label_fine_types (label_id, label_name)
VALUES
    -- Novelty
    (19, 'Tram; Stand'),
    (20, 'Tram; Sit'),
    (21, 'Metrobus; Stand'),
    (22, 'Metrobus; Sit'),
    (23, 'Motorcycle'),
    (24, 'Ferry; Sit; Inside'),
    (25, 'Ferry; Sit; Outside'),
    (26, 'Ferry; Stand; Inside'),
    (27, 'Ferry; Stand; Outside'),
    (28, 'Minibus; Sit'),
    (29, 'Minibus; Stand'),
    (30, 'E-Scooter; Stand'),
    (31, 'Taxi');

INSERT INTO
    label_road_types (label_id, label_name)
VALUES
    (5, 'Sea');

ALTER TABLE
    imu_data
SET
    (
        timescaledb.compress,
        timescaledb.compress_segmentby = 'session_id',
        timescaledb.compress_orderby = 'time DESC'
    );

SELECT
    add_compression_policy(
        'imu_data',
        INTERVAL '30 days',
        if_not_exists => TRUE
    );

-- label_streams
ALTER TABLE
    label_streams
SET
    (
        timescaledb.compress,
        timescaledb.compress_segmentby = 'session_id',
        timescaledb.compress_orderby = 'time DESC'
    );

SELECT
    add_compression_policy(
        'label_streams',
        INTERVAL '30 days',
        if_not_exists => TRUE
    );

-- api_activity_data
ALTER TABLE
    api_activity_data
SET
    (
        timescaledb.compress,
        timescaledb.compress_segmentby = 'session_id',
        timescaledb.compress_orderby = 'time DESC'
    );

SELECT
    add_compression_policy(
        'api_activity_data',
        INTERVAL '30 days',
        if_not_exists => TRUE
    );

-- location_data
ALTER TABLE
    location_data
SET
    (
        timescaledb.compress,
        timescaledb.compress_segmentby = 'session_id',
        timescaledb.compress_orderby = 'time DESC'
    );

SELECT
    add_compression_policy(
        'location_data',
        INTERVAL '30 days',
        if_not_exists => TRUE
    );