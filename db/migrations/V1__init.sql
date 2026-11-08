-- =====================================================================
-- SHL (Sussex-Huawei Locomotion) — Kanonik şema v1.6
-- PostgreSQL 13+ / TimescaleDB 2.x
-- Tek doğru kaynak budur. Tablo ve sütun adları değiştirilemez.
--
-- v1.5 → v1.6 değişiklikleri:
--   * recording_sessions.sampling_rate_hz eklendi (örnekleme hızı, Hz)
--
-- v1.4 → v1.5 değişiklikleri:
--   * Food etiketi kaldırıldı: label_food_types tablosu ve label_streams.food_label_id
--
-- v1.3 → v1.4 değişiklikleri:
--   * trips.recording_folder ve UNIQUE (user_id, recording_folder) kaldırıldı
--     (veri telefonda toplanıp toplu aktarılıyor; klasör yapısı yok)
--   * trip_id telefonda üretilir; tekrar yüklemede aynı id ile gelir
--
-- v1.2 → v1.3 değişiklikleri:
--   * recording_sessions'tan video_offset1, video_offset2, video_speedup kaldırıldı
--     (projede video kaydı alınmıyor)
--
-- v1.1 → v1.2 değişiklikleri:
--   * recording_sessions'tan user_id, recording_folder, dataset_source kaldırıldı
--     (trips'te zaten var; trip_id üzerinden JOIN ile alınır — 3NF)
--   * Bunlara bağlı composite FK ve trips'teki yardımcı UNIQUE kaldırıldı
--
-- v1.0 → v1.1 değişiklikleri:
--   * Etiket lookup tabloları SHL koduna göre 1'den başlar; ham veride 0 = Null → NULL
--   * Yeni lookup: label_coarse_types (coarse_label_id artık FK)
--   * Tüm hypertable'lara (session_id, time DESC) indeksi
--   * phone_positions id'leri sabit (1..4)
--   * PostGIS kaldırıldı (kullanılmıyordu), pgcrypto eklendi (PG < 13 uyumu)
-- =====================================================================

-- 1. Extensions
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;
CREATE EXTENSION IF NOT EXISTS pgcrypto; -- gen_random_uuid() için (PG 13+ yerleşik)

-- =====================================================================
-- 2. Temel tablolar
-- =====================================================================

CREATE TABLE users (
    user_id     VARCHAR(50) PRIMARY KEY,
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    metadata    JSONB
);

CREATE TABLE devices (
    device_id    VARCHAR(50) PRIMARY KEY,
    device_model VARCHAR(100),
    os_version   VARCHAR(50),
    sensor_specs JSONB
);

-- =====================================================================
-- 3. Lookup tabloları (id'ler sabit; ETL bu değerlere güvenir)
-- =====================================================================

CREATE TABLE phone_positions (
    position_id   SERIAL PRIMARY KEY,
    position_name VARCHAR(50) NOT NULL UNIQUE, -- 'hand', 'bag', 'hips', 'torso'
    description   TEXT
);

INSERT INTO phone_positions (position_id, position_name, description) VALUES
(1, 'hand',  'Held in hand'),
(2, 'bag',   'Carried inside a backpack/bag'),
(3, 'hips',  'Worn in front trouser pocket / on hip'),
(4, 'torso', 'Carried in chest pocket or strap');

-- Yeni pozisyonlar SERIAL ile 5'ten devam etsin
SELECT setval(pg_get_serial_sequence('phone_positions', 'position_id'),
              (SELECT MAX(position_id) FROM phone_positions));

-- SHL Label.txt kodlaması: tüm kanallarda 0 = Null.
-- 0 lookup'a yazılmaz; ETL'de ham 0 → NULL çevrilir.

CREATE TABLE label_coarse_types (
    label_id   INT PRIMARY KEY,
    label_name VARCHAR(50) NOT NULL UNIQUE
);

INSERT INTO label_coarse_types (label_id, label_name) VALUES
(1, 'Still'), (2, 'Walk'),  (3, 'Run'),   (4, 'Bike'),
(5, 'Car'),   (6, 'Bus'),   (7, 'Train'), (8, 'Subway');
-- Yeni modlar (vapur, minibüs, skuter...) 9'dan itibaren eklenir.

CREATE TABLE label_fine_types (
    label_id   INT PRIMARY KEY,
    label_name VARCHAR(50) NOT NULL UNIQUE
);

INSERT INTO label_fine_types (label_id, label_name) VALUES
(1,  'Still; Stand; Outside'), (2,  'Still; Stand; Inside'),
(3,  'Still; Sit; Outside'),   (4,  'Still; Sit; Inside'),
(5,  'Walking; Outside'),      (6,  'Walking; Inside'),
(7,  'Run'),                   (8,  'Bike'),
(9,  'Car; Driver'),           (10, 'Car; Passenger'),
(11, 'Bus; Stand'),            (12, 'Bus; Sit'),
(13, 'Bus; Up; Stand'),        (14, 'Bus; Up; Sit'),
(15, 'Train; Stand'),          (16, 'Train; Sit'),
(17, 'Subway; Stand'),         (18, 'Subway; Sit');

CREATE TABLE label_road_types (
    label_id   INT PRIMARY KEY,
    label_name VARCHAR(50) NOT NULL UNIQUE
);

INSERT INTO label_road_types (label_id, label_name) VALUES
(1, 'City'), (2, 'Motorway'), (3, 'Countryside'), (4, 'Dirt road');

-- =====================================================================
-- 4. Trips ve recording sessions
-- =====================================================================

-- Bir trip = bir kullanıcının tek bir kaydı; 4 telefonla eşzamanlı alınır
-- (hand, bag, hips, torso). trip_id kayıt başlarken telefonda üretilir ve
-- trip'in tüm telefonlarında aynıdır; toplu aktarımda bu id ile gelir.
CREATE TABLE trips (
    trip_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(), -- normalde telefondan gelir
    user_id          VARCHAR(50) NOT NULL REFERENCES users(user_id),
    dataset_source   VARCHAR(50) NOT NULL DEFAULT 'SHL_Original',
    start_time       TIMESTAMPTZ NOT NULL,
    end_time         TIMESTAMPTZ,
    CHECK (end_time IS NULL OR end_time >= start_time)
);

CREATE TABLE recording_sessions (
    session_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_id          UUID NOT NULL REFERENCES trips(trip_id),
    device_id        VARCHAR(50) REFERENCES devices(device_id),
    position_id      INT NOT NULL REFERENCES phone_positions(position_id),
    sampling_rate_hz INT NOT NULL CHECK (sampling_rate_hz > 0), -- örnekleme hızı (Hz)
    start_time       TIMESTAMPTZ NOT NULL,
    end_time         TIMESTAMPTZ,
    UNIQUE (trip_id, position_id), -- trip başına her pozisyondan bir session
    CHECK (end_time IS NULL OR end_time >= start_time)
);

CREATE INDEX idx_sessions_trip_id ON recording_sessions (trip_id);

-- =====================================================================
-- 5. IMU verisi (<Position>_Motion.txt, 100 Hz)
-- =====================================================================

CREATE TABLE imu_data (
    time        TIMESTAMPTZ NOT NULL,
    session_id  UUID NOT NULL REFERENCES recording_sessions(session_id),
    acc_x    FLOAT8, acc_y    FLOAT8, acc_z    FLOAT8,  -- m/s²
    gyro_x   FLOAT8, gyro_y   FLOAT8, gyro_z   FLOAT8,  -- rad/s
    mag_x    FLOAT8, mag_y    FLOAT8, mag_z    FLOAT8,  -- µT
    ori_w    FLOAT8, ori_x    FLOAT8, ori_y    FLOAT8, ori_z FLOAT8, -- quaternion
    grav_x   FLOAT8, grav_y   FLOAT8, grav_z   FLOAT8,  -- m/s²
    linacc_x FLOAT8, linacc_y FLOAT8, linacc_z FLOAT8,  -- m/s², yerçekimsiz
    pressure    FLOAT8, -- hPa
    altitude    FLOAT8, -- basınçtan türetilmiş
    temperature FLOAT8  -- basınç sensörü sıcaklığı
);

SELECT create_hypertable('imu_data', 'time', chunk_time_interval => INTERVAL '7 days');

-- =====================================================================
-- 6. Etiket akışı (Label.txt; trip başına tek dosya, 4 session'a ayrı ayrı yazılır)
-- =====================================================================

CREATE TABLE label_streams (
    time            TIMESTAMPTZ NOT NULL,
    session_id      UUID NOT NULL REFERENCES recording_sessions(session_id),
    coarse_label_id INT REFERENCES label_coarse_types(label_id),
    fine_label_id   INT REFERENCES label_fine_types(label_id),
    road_label_id   INT REFERENCES label_road_types(label_id),
    traffic_label   BOOLEAN, -- yoğun trafik
    tunnel_label    BOOLEAN, -- tünelde
    social_label    BOOLEAN  -- sosyal etkileşim
);

SELECT create_hypertable('label_streams', 'time', chunk_time_interval => INTERVAL '7 days');

-- =====================================================================
-- 7. Yardımcı sensör hypertable'ları
-- =====================================================================

-- <Position>_API.txt — Google Activity Recognition güven değerleri
CREATE TABLE api_activity_data (
    time                  TIMESTAMPTZ NOT NULL,
    session_id            UUID NOT NULL REFERENCES recording_sessions(session_id),
    still_confidence      INT,
    on_foot_confidence    INT,
    walking_confidence    INT,
    running_confidence    INT,
    on_bicycle_confidence INT,
    in_vehicle_confidence INT,
    tilting_confidence    INT,
    unknown_confidence    INT
);

SELECT create_hypertable('api_activity_data', 'time', chunk_time_interval => INTERVAL '7 days');

-- <Position>_Ambient.txt
CREATE TABLE ambient_data (
    time        TIMESTAMPTZ NOT NULL,
    session_id  UUID NOT NULL REFERENCES recording_sessions(session_id),
    lux         FLOAT8,
    temperature FLOAT8 -- ortam sıcaklığı
);

SELECT create_hypertable('ambient_data', 'time', chunk_time_interval => INTERVAL '7 days');

-- <Position>_Battery.txt
CREATE TABLE battery_data (
    time          TIMESTAMPTZ NOT NULL,
    session_id    UUID NOT NULL REFERENCES recording_sessions(session_id),
    battery_level INT CHECK (battery_level BETWEEN 0 AND 100),
    temperature   FLOAT8 -- batarya sıcaklığı
);

SELECT create_hypertable('battery_data', 'time', chunk_time_interval => INTERVAL '7 days');

-- <Position>_GPS.txt
CREATE TABLE gps_data (
    time               TIMESTAMPTZ NOT NULL,
    session_id         UUID NOT NULL REFERENCES recording_sessions(session_id),
    satellites_visible INT,
    satellite_info     JSONB -- [{id, snr, azimuth, elevation}, ...]
);

SELECT create_hypertable('gps_data', 'time', chunk_time_interval => INTERVAL '7 days');

-- <Position>_Location.txt
CREATE TABLE location_data (
    time       TIMESTAMPTZ NOT NULL,
    session_id UUID NOT NULL REFERENCES recording_sessions(session_id),
    accuracy   FLOAT8,
    latitude   FLOAT8 NOT NULL CHECK (latitude  BETWEEN -90  AND 90),
    longitude  FLOAT8 NOT NULL CHECK (longitude BETWEEN -180 AND 180),
    altitude   FLOAT8
);

SELECT create_hypertable('location_data', 'time', chunk_time_interval => INTERVAL '7 days');

-- <Position>_WiFi.txt
CREATE TABLE wifi_data (
    time          TIMESTAMPTZ NOT NULL,
    session_id    UUID NOT NULL REFERENCES recording_sessions(session_id),
    wifi_count    INT,
    access_points JSONB -- [{bssid, ssid, rssi, frequency, capabilities}, ...]
);

SELECT create_hypertable('wifi_data', 'time', chunk_time_interval => INTERVAL '7 days');

-- <Position>_Cells.txt
CREATE TABLE cell_data (
    time        TIMESTAMPTZ NOT NULL,
    session_id  UUID NOT NULL REFERENCES recording_sessions(session_id),
    cell_count  INT,
    lte_count   INT,
    gsm_count   INT,
    wcdma_count INT,
    cells_info  JSONB -- hücre başına {type, signal, cid, lac, mcc, mnc}
);

SELECT create_hypertable('cell_data', 'time', chunk_time_interval => INTERVAL '7 days');

-- =====================================================================
-- 8. İndeksler — her hypertable için (session_id, time DESC)
-- =====================================================================

CREATE INDEX idx_imu_session_time      ON imu_data          (session_id, time DESC);
CREATE INDEX idx_labels_session_time   ON label_streams     (session_id, time DESC);
CREATE INDEX idx_api_session_time      ON api_activity_data (session_id, time DESC);
CREATE INDEX idx_ambient_session_time  ON ambient_data      (session_id, time DESC);
CREATE INDEX idx_battery_session_time  ON battery_data      (session_id, time DESC);
CREATE INDEX idx_gps_session_time      ON gps_data          (session_id, time DESC);
CREATE INDEX idx_location_session_time ON location_data     (session_id, time DESC);
CREATE INDEX idx_wifi_session_time     ON wifi_data         (session_id, time DESC);
CREATE INDEX idx_cell_session_time     ON cell_data         (session_id, time DESC);
