-- Gold dimension: dim_weather_classification (issue #36).
--
-- Grain: one row per (weather_code, precipitation_band) combination.
--
-- SCD: Type 0 / full rebuild.
--
-- Built from the approved WMO weather-code mapping and
-- precipitation-band rules documented in:
--
--   - docs/data_model.md
--   - docs/data_dictionary.md
--   - docs/source_to_target_mapping.md
--
-- Deterministic rebuild per D12.
--
-- The dimension contains the complete approved WMO enumeration
-- combined with every approved precipitation band:
--
--   dry
--   light
--   moderate
--   heavy
--
-- Natural key:
--   (weather_code, precipitation_band)
--
-- weather_classification_key is generated deterministically from
-- weather_code and precipitation_band.
--
-- Precipitation bands:
--
--   dry      : precipitation_mm = 0
--   light    : 0 < precipitation_mm <= 2.5
--   moderate : 2.5 < precipitation_mm <= 7.5
--   heavy    : precipitation_mm > 7.5

CREATE OR REPLACE TABLE `ftw-week-08`.`05-gold`.dim_weather_classification AS

WITH known_codes AS (

    SELECT * FROM VALUES
        (0,  'clear_sky'),
        (1,  'mainly_clear'),
        (2,  'partly_cloudy'),
        (3,  'overcast'),

        (45, 'fog'),
        (48, 'fog'),

        (51, 'drizzle'),
        (53, 'drizzle'),
        (55, 'drizzle'),

        (56, 'freezing_drizzle'),
        (57, 'freezing_drizzle'),

        (61, 'rain'),
        (63, 'rain'),
        (65, 'rain'),

        (66, 'freezing_rain'),
        (67, 'freezing_rain'),

        (71, 'snow'),
        (73, 'snow'),
        (75, 'snow'),

        (77, 'snow_grains'),

        (80, 'rain_showers'),
        (81, 'rain_showers'),
        (82, 'rain_showers'),

        (85, 'snow_showers'),
        (86, 'snow_showers'),

        (95, 'thunderstorm'),

        (96, 'thunderstorm_with_hail'),
        (99, 'thunderstorm_with_hail')

    AS t(weather_code, weather_condition)

),

precipitation_bands AS (

    SELECT * FROM VALUES
        ('dry'),
        ('light'),
        ('moderate'),
        ('heavy')
    AS t(precipitation_band)

)

SELECT

    sha2(
        to_json(
            named_struct(
                'weather_code', weather_code,
                'precipitation_band', precipitation_band
            )
        ),
        256
    ) AS weather_classification_key,

    weather_code,

    weather_condition,

    precipitation_band

FROM known_codes
CROSS JOIN precipitation_bands;