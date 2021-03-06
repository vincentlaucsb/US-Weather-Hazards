-- Reminder:
-- Longitude = West and East (x)
-- Latitude = North and South (y)

CREATE VIEW ibtracs_hurricane_names2 AS
SELECT *, jsonb_object_keys(names) FROM ibtracs_hurricane_names

-- Allow PostGIS queries on NOAA Storm Events Database
DROP MATERIALIZED VIEW storm_events;
CREATE MATERIALIZED VIEW storm_events AS
SELECT
    *,
    begin_date_time::timestamp as begin_date_time2,
    end_date_time::timestamp as end_date_time2,
    ST_SetSRID(
        ST_MakePoint(begin_lon, begin_lat),
        4269) as begin_point,
    ST_SetSRID(
        ST_MakePoint(end_lon, end_lat),
        4269) as end_point
FROM storm_events_details;

-- Hurricane Table
DROP VIEW IF EXISTS ibtracs_hurricanes;
CREATE VIEW ibtracs_hurricanes AS
SELECT
	serial_num, season, num, name, basin, sub_basin,
    wind_wmo, saffir_simpson(wind_wmo) as saffir_simpson,
    iso_time::timestamp as iso_time,
    latitude_for_mapping, longitude_for_mapping
FROM ibtracs_allstorms;

CREATE INDEX ON ibtracs_allstorms (name);
CREATE INDEX ON ibtracs_allstorms USING brin (season);

-- Hurricane Summary (requires PostGIS)
DROP MATERIALIZED VIEW IF EXISTS hurricane_summary CASCADE;
CREATE MATERIALIZED VIEW hurricane_summary AS
WITH init_query AS (SELECT
	serial_num, name, season,
    
    -- Build a geometry object of the entire path of the hurricane
	array_agg(ST_SetSRID(ST_MakePoint(longitude_for_mapping,
               latitude_for_mapping), 4269)) as points,
               
    -- Build an array of all of the hurricane's measured wind speeds
    array_max(array_agg(wind_wmo)) as wind_max_kt,
    
    -- Build an array of JSON objects
    -- Each of with corresponds to the location and intensity of a hurricane 
    -- at one point in time
    array_agg(jsonb_build_object(
        'name', name,
        'lon', longitude_for_mapping,
        'lat', latitude_for_mapping,
        'time', iso_time,
        'wind_max_kt', wind_wmo,
        'sshs', saffir_simpson(wind_wmo))
        
        -- Crucial: Make path_intensity ordered by time or else PDI won't work
        ORDER BY iso_time::timestamp ASC) as path_intensity,

	array_agg(iso_time) as time_range
FROM ibtracs_hurricanes ordered_by_time
GROUP BY serial_num, name, season
ORDER BY season ASC)
SELECT
	serial_num,
	name,
    season,
    wind_max_kt,
    path_intensity,
	saffir_simpson(wind_max_kt) AS sshs_peak,
    ST_MakeLine(points) as path,
    array_min(time_range) AS begin,
    array_max(time_range) AS end
FROM init_query;

-- Hurricanes Making Landfall in the Mainland US
DROP MATERIALIZED VIEW IF EXISTS us_hurricanes;
CREATE MATERIALIZED VIEW us_hurricanes AS
SELECT * FROM 
    (SELECT *, st_length(path) FROM hurricane_summary 
    WHERE st_intersects(path, (SELECT * FROM us_bbox))) as init_query
WHERE 
    -- Temporary fix involving handling of paths crossing 180th meridian
    NOT(st_intersects(path, ST_MakeLine(
        ST_SetSRID(ST_MakePoint(170, 80), 4269),
        ST_SetSRID(ST_MakePoint(170, -80), 4269))))
        
    -- Ignore Hawaiian typhoons
    AND NOT(st_crosses(path,
        (SELECT geom FROM us_states WHERE name LIKE 'FLORIDA')))

-- United States bounding box
CREATE VIEW us_bbox AS
SELECT ST_union(array_agg(st_envelope(geom))) FROM us_outline