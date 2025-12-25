--
-- PostgreSQL database dump
--

\restrict uIKF71osG0k6wYHdN6pcQwmrsSj3BVV3qy72IShNgZsE5lyKVhGmCPyWbTsL1gA

-- Dumped from database version 16.10 (Ubuntu 16.10-0ubuntu0.24.04.1)
-- Dumped by pg_dump version 16.11 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: timescaledb; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS timescaledb WITH SCHEMA public;


--
-- Name: EXTENSION timescaledb; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION timescaledb IS 'Enables scalable inserts and complex queries for time-series data (Community Edition)';


--
-- Name: pg_cron; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;


--
-- Name: EXTENSION pg_cron; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_cron IS 'Job scheduler for PostgreSQL';


--
-- Name: prs; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA prs;


--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


--
-- Name: calculate_energy_baseline_shift(integer, date, integer); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.calculate_energy_baseline_shift(p_tenant_id integer DEFAULT 3, p_calculation_date date DEFAULT CURRENT_DATE, p_lookback_weeks integer DEFAULT 8) RETURNS TABLE(baseline_version integer, profile_type character varying, load_group character varying, shift_name character varying, day_type character varying, baseline_median numeric, baseline_mean numeric, baseline_p10 numeric, baseline_p90 numeric, baseline_std numeric, baseline_min numeric, baseline_max numeric, sample_count integer, measurement_unit character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_version INTEGER;
    v_period_start DATE;
    v_period_end DATE;
BEGIN
    -- Calculate version as YYYYMM
    v_version := EXTRACT(YEAR FROM p_calculation_date)::INTEGER * 100 + 
                 EXTRACT(MONTH FROM p_calculation_date)::INTEGER;
    
    -- Calculate lookback period (exclude last 3 days for stability)
    v_period_end := p_calculation_date - INTERVAL '3 days';
    v_period_start := v_period_end - (p_lookback_weeks || ' weeks')::INTERVAL;
    
    RETURN QUERY
    WITH shift_kwh_data AS (
        SELECT
            decs.daily_bucket::date as report_date,
            CASE
                WHEN EXTRACT(DOW FROM decs.daily_bucket) IN (0, 6) THEN 'WEEKEND'
                ELSE 'WEEKDAY'
            END as day_type,
            decs.shift_period as shift_name,
            SUM(decs.total_consumption) FILTER (WHERE decs.device_id IN (18,19,33,104)) as wjl,
            SUM(decs.total_consumption) FILTER (WHERE decs.device_id IN (17)) as pkn,
            SUM(decs.total_consumption) FILTER (WHERE decs.device_id IN (29,30)) as ajl,
            SUM(decs.total_consumption) FILTER (WHERE decs.device_id IN (26,28)) as compressor,
            SUM(decs.total_consumption) FILTER (WHERE decs.device_id IN (34)) as tricot,
            SUM(decs.total_consumption) FILTER (WHERE decs.device_id IN (20,21)) as wsbc
        FROM public.daily_energy_cost_summary decs
        WHERE decs.tenant_id = p_tenant_id
            AND decs.quantity_id = 124
            AND decs.grouping_type = 'SHIFT_RATE'
            AND decs.daily_bucket::date BETWEEN v_period_start AND v_period_end
        GROUP BY decs.daily_bucket::date, day_type, decs.shift_period
    ),
    unpivoted_data AS (
        SELECT
            skd.report_date,
            skd.day_type,
            skd.shift_name,
            unpivot.load_group,
            unpivot.kwh
        FROM shift_kwh_data skd
        CROSS JOIN LATERAL (
            VALUES
                ('wjl', skd.wjl),
                ('pkn', skd.pkn),
                ('ajl', skd.ajl),
                ('compressor', skd.compressor),
                ('tricot', skd.tricot),
                ('wsbc', skd.wsbc)
        ) AS unpivot(load_group, kwh)
        WHERE unpivot.kwh IS NOT NULL
    ),
    baseline_stats AS (
        SELECT
            v_version as bs_baseline_version,
            'ENERGY_SHIFT'::VARCHAR(50) as bs_profile_type,
            ud.load_group as bs_load_group,
            ud.shift_name as bs_shift_name,
            ud.day_type as bs_day_type,
            PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ud.kwh) as bs_baseline_median,
            AVG(ud.kwh) as bs_baseline_mean,
            PERCENTILE_CONT(0.1) WITHIN GROUP (ORDER BY ud.kwh) as bs_baseline_p10,
            PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY ud.kwh) as bs_baseline_p90,
            STDDEV(ud.kwh) as bs_baseline_std,
            MIN(ud.kwh) as bs_baseline_min,
            MAX(ud.kwh) as bs_baseline_max,
            COUNT(*) as bs_sample_count,
            'kWh'::VARCHAR(20) as bs_unit
        FROM unpivoted_data ud
        GROUP BY ud.load_group, ud.shift_name, ud.day_type
        HAVING COUNT(*) >= 5  -- Require at least 5 data points for reliable baseline
    )
    SELECT 
        bs.bs_baseline_version,
        bs.bs_profile_type::VARCHAR(50),
        bs.bs_load_group::VARCHAR(50),
        bs.bs_shift_name::VARCHAR(50),
        bs.bs_day_type::VARCHAR(20),
        ROUND(bs.bs_baseline_median::NUMERIC, 3) as baseline_median,
        ROUND(bs.bs_baseline_mean::NUMERIC, 3) as baseline_mean,
        ROUND(bs.bs_baseline_p10::NUMERIC, 3) as baseline_p10,
        ROUND(bs.bs_baseline_p90::NUMERIC, 3) as baseline_p90,
        ROUND(bs.bs_baseline_std::NUMERIC, 3) as baseline_std,
        ROUND(bs.bs_baseline_min::NUMERIC, 3) as baseline_min,
        ROUND(bs.bs_baseline_max::NUMERIC, 3) as baseline_max,
        bs.bs_sample_count::INTEGER,
        bs.bs_unit::VARCHAR(20)
    FROM baseline_stats bs
    ORDER BY bs.bs_load_group, bs.bs_shift_name, bs.bs_day_type;
END;
$$;


--
-- Name: calculate_monthly_baseline(integer, date, integer); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.calculate_monthly_baseline(p_tenant_id integer DEFAULT 3, p_calculation_date date DEFAULT CURRENT_DATE, p_lookback_weeks integer DEFAULT 8) RETURNS TABLE(baseline_version integer, load_group character varying, shift_name character varying, day_type character varying, time_hhmm time without time zone, baseline_median numeric, baseline_mean numeric, baseline_p10 numeric, baseline_p90 numeric, baseline_std numeric, baseline_min numeric, baseline_max numeric, sample_count integer, data_completeness numeric)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_version INTEGER;
    v_period_start DATE;
    v_period_end DATE;
BEGIN
    -- Calculate version as YYYYMM
    v_version := EXTRACT(YEAR FROM p_calculation_date)::INTEGER * 100 + 
                 EXTRACT(MONTH FROM p_calculation_date)::INTEGER;
    
    -- Calculate lookback period (exclude last 3 days for stability)
    v_period_end := p_calculation_date - INTERVAL '3 days';
    v_period_start := v_period_end - (p_lookback_weeks || ' weeks')::INTERVAL;
    
    RETURN QUERY
    WITH raw_data AS (
        -- Get telemetry data with shift assignment using your existing function
        SELECT
            ta.bucket as raw_bucket,
            DATE(ta.bucket AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Jakarta') as raw_calendar_date,
            ta.bucket::TIME as raw_time_hhmm,
            get_shift_period(p_tenant_id, ta.bucket) as raw_shift_name,
            CASE 
                WHEN EXTRACT(DOW FROM (ta.bucket AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Jakarta')) IN (0, 6) 
                THEN 'WEEKEND'
                ELSE 'WEEKDAY'
            END as raw_day_type,
            -- Your load group aggregations
            SUM(ta.aggregated_value) FILTER (WHERE ta.device_id IN (26,28)) as compressor_power,
            SUM(ta.aggregated_value) FILTER (WHERE ta.device_id IN (29,30)) as ajl_power,
            SUM(ta.aggregated_value) FILTER (WHERE ta.device_id IN (18,19,33,104)) as wjl_power,
            SUM(ta.aggregated_value) FILTER (WHERE ta.device_id IN (17)) as pkn_power,
            SUM(ta.aggregated_value) FILTER (WHERE ta.device_id IN (34)) as tricot_power,
            SUM(ta.aggregated_value) FILTER (WHERE ta.device_id IN (20,21)) as wsbc_power
        FROM telemetry_15min_agg ta
        WHERE ta.tenant_id = p_tenant_id
          AND ta.device_id IN (17,18,19,20,21,26,28,29,30,33,34,104)
          AND ta.quantity_id = 185
          AND DATE(ta.bucket AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Jakarta') 
              BETWEEN v_period_start AND v_period_end
        GROUP BY ta.bucket
    ),
    unpivoted_data AS (
        -- Unpivot load groups for easier aggregation
        SELECT 
            rd.raw_calendar_date as upv_calendar_date, 
            rd.raw_shift_name as upv_shift_name, 
            rd.raw_day_type as upv_day_type, 
            rd.raw_time_hhmm as upv_time_hhmm, 
            'compressor' as upv_load_group, 
            rd.compressor_power as upv_power 
        FROM raw_data rd
        UNION ALL
        SELECT rd.raw_calendar_date, rd.raw_shift_name, rd.raw_day_type, rd.raw_time_hhmm, 'ajl', rd.ajl_power FROM raw_data rd
        UNION ALL
        SELECT rd.raw_calendar_date, rd.raw_shift_name, rd.raw_day_type, rd.raw_time_hhmm, 'wjl', rd.wjl_power FROM raw_data rd
        UNION ALL
        SELECT rd.raw_calendar_date, rd.raw_shift_name, rd.raw_day_type, rd.raw_time_hhmm, 'pkn', rd.pkn_power FROM raw_data rd
        UNION ALL
        SELECT rd.raw_calendar_date, rd.raw_shift_name, rd.raw_day_type, rd.raw_time_hhmm, 'tricot', rd.tricot_power FROM raw_data rd
        UNION ALL
        SELECT rd.raw_calendar_date, rd.raw_shift_name, rd.raw_day_type, rd.raw_time_hhmm, 'wsbc', rd.wsbc_power FROM raw_data rd
    ),
    shift_expected_intervals AS (
        -- Dynamically get shift definitions from tenant_shift_periods
        -- Calculate expected intervals based on shift duration
        SELECT 
            tsp.shift_name as sei_shift_name,
            CASE 
                WHEN tsp.start_hour < tsp.end_hour THEN 
                    (tsp.end_hour - tsp.start_hour) * 4  -- 4 intervals per hour
                WHEN tsp.start_hour > tsp.end_hour THEN 
                    ((24 - tsp.start_hour) + tsp.end_hour) * 4
                ELSE 96  -- 24-hour shift
            END as sei_expected_count
        FROM tenant_shift_periods tsp
        WHERE tsp.tenant_id = p_tenant_id
          AND tsp.is_active = true
          AND (tsp.effective_to IS NULL OR tsp.effective_to >= CURRENT_DATE)
          AND tsp.effective_from <= CURRENT_DATE
    ),
    daily_completeness AS (
        -- Check data completeness per calendar-day, shift, and load group
        SELECT 
            ud.upv_calendar_date as dc_calendar_date,
            ud.upv_shift_name as dc_shift_name,
            ud.upv_day_type as dc_day_type,
            ud.upv_load_group as dc_load_group,
            COUNT(*) as dc_intervals_present,
            sei.sei_expected_count as dc_expected_count,
            (COUNT(*)::NUMERIC / NULLIF(sei.sei_expected_count, 0)) * 100 as dc_completeness_pct
        FROM unpivoted_data ud
        JOIN shift_expected_intervals sei ON ud.upv_shift_name = sei.sei_shift_name
        WHERE ud.upv_power IS NOT NULL
        GROUP BY ud.upv_calendar_date, ud.upv_shift_name, ud.upv_day_type, ud.upv_load_group, sei.sei_expected_count
    ),
    filtered_data AS (
        -- Exclude calendar-days with <80% data completeness for that shift
        SELECT 
            ud.upv_calendar_date as fd_calendar_date,
            ud.upv_shift_name as fd_shift_name,
            ud.upv_day_type as fd_day_type,
            ud.upv_time_hhmm as fd_time_hhmm,
            ud.upv_load_group as fd_load_group,
            ud.upv_power as fd_power
        FROM unpivoted_data ud
        JOIN daily_completeness dc 
            ON ud.upv_calendar_date = dc.dc_calendar_date 
            AND ud.upv_shift_name = dc.dc_shift_name
            AND ud.upv_load_group = dc.dc_load_group
        WHERE dc.dc_completeness_pct >= 80
          AND ud.upv_power IS NOT NULL
          AND ud.upv_power >= 0  -- Include zeros but not nulls
    ),
    baseline_stats AS (
        -- Calculate baseline statistics per time slot within each shift
        SELECT
            v_version as bs_baseline_version,
            fd.fd_load_group as bs_load_group,
            fd.fd_shift_name as bs_shift_name,
            fd.fd_day_type as bs_day_type,
            fd.fd_time_hhmm as bs_time_hhmm,
            PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY fd.fd_power) as bs_baseline_median,
            AVG(fd.fd_power) as bs_baseline_mean,
            PERCENTILE_CONT(0.1) WITHIN GROUP (ORDER BY fd.fd_power) as bs_baseline_p10,
            PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY fd.fd_power) as bs_baseline_p90,
            STDDEV(fd.fd_power) as bs_baseline_std,
            MIN(fd.fd_power) as bs_baseline_min,
            MAX(fd.fd_power) as bs_baseline_max,
            COUNT(*) as bs_sample_count,
            -- Calculate average completeness for this time slot
            AVG(dc.dc_completeness_pct) as bs_avg_completeness
        FROM filtered_data fd
        JOIN daily_completeness dc 
            ON fd.fd_calendar_date = dc.dc_calendar_date
            AND fd.fd_shift_name = dc.dc_shift_name
            AND fd.fd_load_group = dc.dc_load_group
        GROUP BY fd.fd_load_group, fd.fd_shift_name, fd.fd_day_type, fd.fd_time_hhmm
        HAVING COUNT(*) >= 5  -- Require at least 5 data points for reliable baseline
    )
    SELECT 
        bs.bs_baseline_version,
        bs.bs_load_group::VARCHAR(50),
        bs.bs_shift_name::VARCHAR(50),
        bs.bs_day_type::VARCHAR(20),
        bs.bs_time_hhmm,
        ROUND(bs.bs_baseline_median::NUMERIC, 3) as baseline_median,
        ROUND(bs.bs_baseline_mean::NUMERIC, 3) as baseline_mean,
        ROUND(bs.bs_baseline_p10::NUMERIC, 3) as baseline_p10,
        ROUND(bs.bs_baseline_p90::NUMERIC, 3) as baseline_p90,
        ROUND(bs.bs_baseline_std::NUMERIC, 3) as baseline_std,
        ROUND(bs.bs_baseline_min::NUMERIC, 3) as baseline_min,
        ROUND(bs.bs_baseline_max::NUMERIC, 3) as baseline_max,
        bs.bs_sample_count::INTEGER,
        ROUND(bs.bs_avg_completeness::NUMERIC, 2) as data_completeness
    FROM baseline_stats bs
    ORDER BY bs.bs_load_group, bs.bs_shift_name, bs.bs_day_type, bs.bs_time_hhmm;
END;
$$;


--
-- Name: compare_energy_to_baseline(integer, date, date, integer); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.compare_energy_to_baseline(p_tenant_id integer, p_start_date date, p_end_date date, p_baseline_version integer DEFAULT NULL::integer) RETURNS TABLE(report_date date, shift_name character varying, day_type character varying, load_group character varying, actual_kwh numeric, baseline_median numeric, baseline_p10 numeric, baseline_p90 numeric)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_baseline_version INTEGER;
BEGIN
    -- Get latest baseline version if not specified
    IF p_baseline_version IS NULL THEN
        SELECT MAX(blp.baseline_version) INTO v_baseline_version
        FROM prs.baseline_load_profiles blp
        WHERE blp.tenant_id = p_tenant_id
          AND blp.profile_type = 'ENERGY_SHIFT'
          AND blp.is_active = true;
    ELSE
        v_baseline_version := p_baseline_version;
    END IF;
    
    RETURN QUERY
    WITH aggregated_energy AS (
        -- First aggregate by date, shift, day_type
        SELECT
            decs.daily_bucket::date as report_date,
            CASE
                WHEN EXTRACT(DOW FROM decs.daily_bucket) IN (0, 6) THEN 'WEEKEND'
                ELSE 'WEEKDAY'
            END as day_type,
            decs.shift_period as shift_name,
            SUM(decs.total_consumption) FILTER (WHERE decs.device_id IN (18,19,33,104)) as wjl_kwh,
            SUM(decs.total_consumption) FILTER (WHERE decs.device_id IN (17)) as pkn_kwh,
            SUM(decs.total_consumption) FILTER (WHERE decs.device_id IN (29,30)) as ajl_kwh,
            SUM(decs.total_consumption) FILTER (WHERE decs.device_id IN (26,28)) as compressor_kwh,
            SUM(decs.total_consumption) FILTER (WHERE decs.device_id IN (34)) as tricot_kwh,
            SUM(decs.total_consumption) FILTER (WHERE decs.device_id IN (20,21)) as wsbc_kwh
        FROM public.daily_energy_cost_summary decs
        WHERE decs.tenant_id = p_tenant_id
            AND decs.quantity_id = 124
            AND decs.grouping_type = 'SHIFT_RATE'
            AND decs.daily_bucket::date BETWEEN p_start_date AND p_end_date
        GROUP BY decs.daily_bucket::date, day_type, decs.shift_period
    ),
    unpivoted_actual AS (
        -- Then unpivot the load groups
        SELECT
            ae.report_date,
            ae.day_type,
            ae.shift_name,
            unpivot.load_group,
            unpivot.kwh as actual_kwh
        FROM aggregated_energy ae
        CROSS JOIN LATERAL (
            VALUES
                ('wjl', ae.wjl_kwh),
                ('pkn', ae.pkn_kwh),
                ('ajl', ae.ajl_kwh),
                ('compressor', ae.compressor_kwh),
                ('tricot', ae.tricot_kwh),
                ('wsbc', ae.wsbc_kwh)
        ) AS unpivot(load_group, kwh)
        WHERE unpivot.kwh IS NOT NULL
    )
    SELECT 
        ua.report_date,
        ua.shift_name::VARCHAR(50),
        ua.day_type::VARCHAR(20),
        ua.load_group::VARCHAR(50),
        ROUND(ua.actual_kwh, 3) as actual_kwh,
        ROUND(blp.baseline_median, 3) as baseline_median,
        ROUND(blp.baseline_p10, 3) as baseline_p10,
        ROUND(blp.baseline_p90, 3) as baseline_p90
    FROM unpivoted_actual ua
    LEFT JOIN prs.baseline_load_profiles blp
        ON blp.tenant_id = p_tenant_id
        AND blp.baseline_version = v_baseline_version
        AND blp.profile_type = 'ENERGY_SHIFT'
        AND blp.load_group = ua.load_group
        AND blp.shift_name = ua.shift_name
        AND blp.day_type = ua.day_type
        AND blp.is_active = true
    ORDER BY ua.report_date, ua.shift_name, ua.load_group;
END;
$$;


--
-- Name: compare_to_baseline(integer, timestamp without time zone, timestamp without time zone, integer); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.compare_to_baseline(p_tenant_id integer, p_start_timestamp timestamp without time zone, p_end_timestamp timestamp without time zone, p_baseline_version integer DEFAULT NULL::integer) RETURNS TABLE(bucket timestamp without time zone, calendar_date date, shift_name character varying, day_type character varying, time_hhmm time without time zone, load_group character varying, actual_power numeric, baseline_mean numeric, baseline_median numeric, baseline_p10 numeric, baseline_p90 numeric)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_baseline_version INTEGER;
BEGIN
    -- Get latest baseline version if not specified
    IF p_baseline_version IS NULL THEN
        SELECT MAX(blp.baseline_version) INTO v_baseline_version
        FROM prs.baseline_load_profiles blp
        WHERE blp.tenant_id = p_tenant_id
          AND blp.is_active = true;
    ELSE
        v_baseline_version := p_baseline_version;
    END IF;
    
    RETURN QUERY
    WITH raw_data AS (
        -- Get telemetry data with shift assignment (similar to calculate_monthly_baseline)
        SELECT
            ta.bucket as raw_bucket,
            DATE(ta.bucket AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Jakarta') as raw_calendar_date,
            ta.bucket::TIME as raw_time_hhmm,
            get_shift_period(p_tenant_id, ta.bucket) as raw_shift_name,
            CASE 
                WHEN EXTRACT(DOW FROM (ta.bucket AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Jakarta')) IN (0, 6) 
                THEN 'WEEKEND'
                ELSE 'WEEKDAY'
            END as raw_day_type,
            -- Your load group aggregations
            SUM(ta.aggregated_value) FILTER (WHERE ta.device_id IN (26,28)) as compressor_power,
            SUM(ta.aggregated_value) FILTER (WHERE ta.device_id IN (29,30)) as ajl_power,
            SUM(ta.aggregated_value) FILTER (WHERE ta.device_id IN (18,19,33,104)) as wjl_power,
            SUM(ta.aggregated_value) FILTER (WHERE ta.device_id IN (17)) as pkn_power,
            SUM(ta.aggregated_value) FILTER (WHERE ta.device_id IN (34)) as tricot_power,
            SUM(ta.aggregated_value) FILTER (WHERE ta.device_id IN (20,21)) as wsbc_power
        FROM telemetry_15min_agg ta
        WHERE ta.tenant_id = p_tenant_id
          AND ta.device_id IN (17,18,19,20,21,26,28,29,30,33,34,104)
          AND ta.quantity_id = 185
          AND ta.bucket >= p_start_timestamp
          AND ta.bucket < p_end_timestamp
        GROUP BY ta.bucket
    ),
    unpivoted_data AS (
        -- Unpivot load groups
        SELECT 
            rd.raw_bucket,
            rd.raw_calendar_date, 
            rd.raw_shift_name, 
            rd.raw_day_type, 
            rd.raw_time_hhmm, 
            'compressor' as load_group_name, 
            rd.compressor_power as power_value
        FROM raw_data rd
        UNION ALL
        SELECT rd.raw_bucket, rd.raw_calendar_date, rd.raw_shift_name, rd.raw_day_type, rd.raw_time_hhmm, 'ajl', rd.ajl_power 
        FROM raw_data rd
        UNION ALL
        SELECT rd.raw_bucket, rd.raw_calendar_date, rd.raw_shift_name, rd.raw_day_type, rd.raw_time_hhmm, 'wjl', rd.wjl_power 
        FROM raw_data rd
        UNION ALL
        SELECT rd.raw_bucket, rd.raw_calendar_date, rd.raw_shift_name, rd.raw_day_type, rd.raw_time_hhmm, 'pkn', rd.pkn_power 
        FROM raw_data rd
        UNION ALL
        SELECT rd.raw_bucket, rd.raw_calendar_date, rd.raw_shift_name, rd.raw_day_type, rd.raw_time_hhmm, 'tricot', rd.tricot_power 
        FROM raw_data rd
        UNION ALL
        SELECT rd.raw_bucket, rd.raw_calendar_date, rd.raw_shift_name, rd.raw_day_type, rd.raw_time_hhmm, 'wsbc', rd.wsbc_power 
        FROM raw_data rd
    ),
    with_baseline AS (
        -- Join with baseline data
        SELECT 
            ud.raw_bucket,
            ud.raw_calendar_date,
            ud.raw_shift_name,
            ud.raw_day_type,
            ud.raw_time_hhmm,
            ud.load_group_name,
            ud.power_value,
            blp.baseline_mean,
            blp.baseline_median,
            blp.baseline_p10,
            blp.baseline_p90
        FROM unpivoted_data ud
        LEFT JOIN prs.baseline_load_profiles blp
            ON blp.tenant_id = p_tenant_id
            AND blp.baseline_version = v_baseline_version
            AND blp.load_group = ud.load_group_name
            AND blp.shift_name = ud.raw_shift_name
            AND blp.day_type = ud.raw_day_type
            AND blp.time_hhmm = ud.raw_time_hhmm
            AND blp.is_active = true
			AND blp.profile_type = 'POWER_15MIN'
    )
    SELECT 
        wb.raw_bucket,
        wb.raw_calendar_date,
        wb.raw_shift_name,
        wb.raw_day_type::VARCHAR(50),
        wb.raw_time_hhmm,
        wb.load_group_name::VARCHAR(50),
        ROUND(wb.power_value::NUMERIC, 3) as actual_power,
        ROUND(wb.baseline_mean::NUMERIC, 3) as baseline_mean,
        ROUND(wb.baseline_median::NUMERIC, 3) as baseline_median,
        ROUND(wb.baseline_p10::NUMERIC, 3) as baseline_p10,
        ROUND(wb.baseline_p90::NUMERIC, 3) as baseline_p90
    FROM with_baseline wb
    ORDER BY wb.raw_bucket, wb.load_group_name;
END;
$$;


--
-- Name: excel_reporter_factory_a(); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.excel_reporter_factory_a() RETURNS TABLE(report_date date, total_wjl numeric, total_pkn numeric, total_chiller numeric, total_ajl numeric, total_compressor numeric, total_tricot numeric, total_wsbc numeric, shift1_total numeric, shift2_total numeric, shift3_total numeric, total_factory_a numeric, shift1_wjl numeric, shift1_pkn numeric, shift1_chiller numeric, shift1_ajl numeric, shift1_compressor numeric, shift1_tricot numeric, shift1_wsbc numeric, shift2_wjl numeric, shift2_pkn numeric, shift2_chiller numeric, shift2_ajl numeric, shift2_compressor numeric, shift2_tricot numeric, shift2_wsbc numeric, shift3_wjl numeric, shift3_pkn numeric, shift3_chiller numeric, shift3_ajl numeric, shift3_compressor numeric, shift3_tricot numeric, shift3_wsbc numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
RETURN QUERY
SELECT
	daily_bucket::DATE as report_date,
	-- Total Values
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (18,19,33,104) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_wjl, --WJL
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (17) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_pkn, --PKN
	(
		COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (26) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) -
		COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (98) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0)
	) as total_chiller, -- chiller, pump & tower
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (29,30) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_ajl, --AJL
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (26,28) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_compressor, --Compressor
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (34) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_tricot, --Tricot
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (20,21) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_wsbc, --WSBC

	-- SHIFT 1 TOTAL: FIXED - Added device 17, Removed device 15
	(
		COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (18,19,33,104,17,29,30,26,28,34,21,20) AND shift_period IN ('SHIFT1')),0) +
		(COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (26) AND shift_period IN ('SHIFT1')),0) -
		COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (98) AND shift_period IN ('SHIFT1')),0))
	) as shift1_total,

	-- SHIFT 2 TOTAL: FIXED - Added device 17, Removed device 15
	(
		COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (18,19,33,104,17,29,30,26,28,34,21,20) AND shift_period IN ('SHIFT2')),0) +
		(COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (26) AND shift_period IN ('SHIFT2')),0) -
		COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (98) AND shift_period IN ('SHIFT2')),0))
	) as shift2_total,

	-- SHIFT 3 TOTAL: FIXED - Added device 17, Removed device 15
	(
		COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (18,19,33,104,17,29,30,26,28,34,21,20) AND shift_period IN ('SHIFT3')),0) +
		(COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (26) AND shift_period IN ('SHIFT3')),0) -
		COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (98) AND shift_period IN ('SHIFT3')),0))
	) as shift3_total,

	-- TOTAL FACTORY A: FIXED - Added device 17, Removed device 15
	(
		COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (18,19,33,104,17,29,30,26,28,34,21,20) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) +
		(COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (26) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) -
		COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (98) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0))
	) as total_factory_a,

	--SHIFT 1 ONLY
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (18,19,33,104) AND shift_period IN ('SHIFT1')),0) shift1_wjl, --WJL
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (17) AND shift_period IN ('SHIFT1')),0) shift1_pkn, --PKN
	(
		COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (26) AND shift_period IN ('SHIFT1')),0) -
		COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (98) AND shift_period IN ('SHIFT1')),0)
	) shift1_chiller, -- chiller, pump & tower
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (29,30) AND shift_period IN ('SHIFT1')),0) shift1_ajl, --AJL
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (26,28) AND shift_period IN ('SHIFT1')),0) shift1_compressor, --Compressor
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (34) AND shift_period IN ('SHIFT1')),0) shift1_tricot, --Tricot
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (20,21) AND shift_period IN ('SHIFT1')),0) shift1_wsbc,

	-- SHIFT 2 ONLY
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (18,19,33,104) AND shift_period IN ('SHIFT2')),0) as shift2_wjl, --WJL
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (17) AND shift_period IN ('SHIFT2')),0) as shift2_pkn, --PKN
	(
		COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (26) AND shift_period IN ('SHIFT2')),0) -
		COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (98) AND shift_period IN ('SHIFT2')),0)
	) as shift2_chiller, -- chiller, pump & tower
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (29,30) AND shift_period IN ('SHIFT2')),0) as shift2_ajl, --AJL
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (26,28) AND shift_period IN ('SHIFT2')),0) as shift2_compressor, --Compressor
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (34) AND shift_period IN ('SHIFT2')),0) as shift2_tricot, --Tricot
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (20,21) AND shift_period IN ('SHIFT2')),0) as shift2_wsbc, --WSBC

	--SHIFT 3 ONLY
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (18,19,33,104) AND shift_period IN ('SHIFT3')),0) as shift3_wjl, --WJL
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (17) AND shift_period IN ('SHIFT3')),0) as shift3_pkn, --PKN
	(
		COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (26) AND shift_period IN ('SHIFT3')),0) -
		COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (98) AND shift_period IN ('SHIFT3')),0)
	) as shift3_chiller, -- chiller, pump & tower
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (29,30) AND shift_period IN ('SHIFT3')),0) as shift3_ajl, --AJL
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (26,28) AND shift_period IN ('SHIFT3')),0) as shift3_compressor, --Compressor
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (34) AND shift_period IN ('SHIFT3')),0) as shift3_tricot, --Tricot
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (20,21) AND shift_period IN ('SHIFT3')),0) as shift3_wsbc --WSBC

FROM daily_energy_cost_summary
WHERE
	tenant_id = 3
	AND device_id = ANY(ARRAY[17,18,19,20,21,26,28,29,30,33,34,98,104])
	AND quantity_id = 124
	AND daily_bucket BETWEEN
		date_trunc('month', NOW() + INTERVAL '7 hours') AND
		(NOW() + INTERVAL '7 hours') - INTERVAL '1 day'
GROUP BY
	daily_bucket
ORDER BY
	daily_bucket;
END;
$$;


--
-- Name: excel_reporter_factory_b(); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.excel_reporter_factory_b() RETURNS TABLE(report_date date, total_beam numeric, total_rapid numeric, total_press numeric, total_raincoat numeric, total_packing numeric, total_lab numeric, total_fin1 numeric, total_fin22 numeric, total_fin21 numeric, total_wtp numeric, total_comp numeric, total_boiler numeric, total_factory_b numeric, shift1_total numeric, shift2_total numeric, shift3_total numeric, shift1_beam numeric, shift1_rapid numeric, shift1_press numeric, shift1_raincoat numeric, shift1_packing numeric, shift1_lab numeric, shift1_fin1 numeric, shift1_fin22 numeric, shift1_fin21 numeric, shift1_wtp numeric, shift1_comp numeric, shift1_boiler numeric, shift2_beam numeric, shift2_rapid numeric, shift2_press numeric, shift2_raincoat numeric, shift2_packing numeric, shift2_lab numeric, shift2_fin1 numeric, shift2_fin22 numeric, shift2_fin21 numeric, shift2_wtp numeric, shift2_comp numeric, shift2_boiler numeric, shift3_beam numeric, shift3_rapid numeric, shift3_press numeric, shift3_raincoat numeric, shift3_packing numeric, shift3_lab numeric, shift3_fin1 numeric, shift3_fin22 numeric, shift3_fin21 numeric, shift3_wtp numeric, shift3_comp numeric, shift3_boiler numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
RETURN QUERY
SELECT
	daily_bucket::DATE as report_date,
	-- Total Values
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (13,14) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_beam, --Celup1
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (15) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_rapid, --Celup2
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (7) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_press, --Celup3
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (6) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_raincoat, --Raincoat
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (10) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_packing, --Packing
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (16) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_lab, --Lab
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (9) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_fin1, --Finishing 1
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (5) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_fin22, --Finishing 2.2
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (3) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_fin21, --Lab
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (91) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_wtp, --WTP2
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (4) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_comp, --Comp 100HP
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (8) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_boiler, --Lab
	COALESCE(SUM(total_consumption) FILTER (WHERE shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_factory_b, --Total Factory B
	COALESCE(SUM(total_consumption) FILTER (WHERE shift_period IN ('SHIFT1')),0) as shift1_total, --Total Shift 1
	COALESCE(SUM(total_consumption) FILTER (WHERE shift_period IN ('SHIFT2')),0) as shift2_total, --Total Shift 2
	COALESCE(SUM(total_consumption) FILTER (WHERE shift_period IN ('SHIFT3')),0) as shift3_total, --Total Shift 3

	-- SHIFT 1 ONLY
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (13,14) AND shift_period IN ('SHIFT1')),0) as shift1_beam, --Celup1
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (15) AND shift_period IN ('SHIFT1')),0) as shift1_rapid, --Celup2
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (7) AND shift_period IN ('SHIFT1')),0) as shift1_press, --Celup3
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (6) AND shift_period IN ('SHIFT1')),0) as shift1_raincoat, --Raincoat
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (10) AND shift_period IN ('SHIFT1')),0) as shift1_packing, --Packing
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (16) AND shift_period IN ('SHIFT1')),0) as shift1_lab, --Lab
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (9) AND shift_period IN ('SHIFT1')),0) as shift1_fin1, --Finishing 1
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (5) AND shift_period IN ('SHIFT1')),0) as shift1_fin22, --Finishing 2.2
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (3) AND shift_period IN ('SHIFT1')),0) as shift1_fin21, --Lab
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (91) AND shift_period IN ('SHIFT1')),0) as shift1_wtp,
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (4) AND shift_period IN ('SHIFT1')),0) as shift1_comp, --Comp 100HP
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (8) AND shift_period IN ('SHIFT1')),0) as shift1_boiler, --Lab

	-- SHIFT 2 ONLY
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (13,14) AND shift_period IN ('SHIFT2')),0) as shift2_beam, --Celup1
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (15) AND shift_period IN ('SHIFT2')),0) as shift2_rapid, --Celup2
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (7) AND shift_period IN ('SHIFT2')),0) as shift2_press, --Celup3
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (6) AND shift_period IN ('SHIFT2')),0) as shift2_raincoat, --Raincoat
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (10) AND shift_period IN ('SHIFT2')),0) as shift2_packing, --Packing
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (16) AND shift_period IN ('SHIFT2')),0) as shift2_lab, --Lab
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (9) AND shift_period IN ('SHIFT2')),0) as shift2_fin1, --Finishing 1
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (5) AND shift_period IN ('SHIFT2')),0) as shift2_fin22, --Finishing 2.2
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (3) AND shift_period IN ('SHIFT2')),0) as shift2_fin21, --Lab
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (91) AND shift_period IN ('SHIFT2')),0) as shift2_wtp,
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (4) AND shift_period IN ('SHIFT2')),0) as shift2_comp, --Comp 100HP
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (8) AND shift_period IN ('SHIFT2')),0) as shift2_boiler, --Lab	

	-- SHIFT 3 ONLY
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (13,14) AND shift_period IN ('SHIFT3')),0) as shift3_beam, --Celup1
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (15) AND shift_period IN ('SHIFT3')),0) as shift3_rapid, --Celup2
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (7) AND shift_period IN ('SHIFT3')),0) as shift3_press, --Celup3
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (6) AND shift_period IN ('SHIFT3')),0) as shift3_raincoat, --Raincoat
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (10) AND shift_period IN ('SHIFT3')),0) as shift3_packing, --Packing
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (16) AND shift_period IN ('SHIFT3')),0) as shift3_lab, --Lab
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (9) AND shift_period IN ('SHIFT3')),0) as shift3_fin1, --Finishing 1
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (5) AND shift_period IN ('SHIFT3')),0) as shift3_fin22, --Finishing 2.2
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (3) AND shift_period IN ('SHIFT3')),0) as shift3_fin21, --Lab
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (91) AND shift_period IN ('SHIFT3')),0) as shift3_wtp,
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (4) AND shift_period IN ('SHIFT3')),0) as shift3_comp, --Comp 100HP
	COALESCE(SUM(total_consumption) FILTER (WHERE device_id IN (8) AND shift_period IN ('SHIFT3')),0) as shift3_boiler --Lab	
	
FROM daily_energy_cost_summary
WHERE
	tenant_id = 3
	AND device_id = ANY(ARRAY[3,4,5,6,7,8,9,10,13,14,15,16,91])
	AND quantity_id = 124
	AND daily_bucket BETWEEN
		date_trunc('month', NOW() + INTERVAL '7 hours') AND
		(NOW() + INTERVAL '7 hours') - INTERVAL '1 day'
GROUP BY
	daily_bucket
ORDER BY
	daily_bucket;
END;
$$;


--
-- Name: excel_reporter_prs(); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.excel_reporter_prs() RETURNS TABLE(report_date date, shift1_pln numeric, shift2_pln numeric, shift3_pln numeric, lwbp_pln numeric, wbp_pln numeric, total_pln numeric, plts_a numeric, plts_b numeric, total_purchase numeric, divisi_kain numeric, divisi_benang numeric, factory_a_pln numeric, factory_b_pln numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
RETURN QUERY
SELECT
	daily_bucket::DATE as report_date,
	SUM(total_consumption) FILTER (WHERE device_id = 94 AND shift_period = 'SHIFT1') as shift1_pln,
	SUM(total_consumption) FILTER (WHERE device_id = 94 AND shift_period = 'SHIFT2') as shift2_pln,
	SUM(total_consumption) FILTER (WHERE device_id = 94 AND shift_period = 'SHIFT3') as shift3_pln,
	SUM(total_consumption) FILTER (WHERE device_id = 94 AND rate_code IN ('LWBP1','LWBP2')) as lwbp_pln,
	SUM(total_consumption) FILTER (WHERE device_id = 94 AND rate_code = 'WBP') as wbp_pln,
	SUM(total_consumption) FILTER (WHERE device_id = 94 AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')) as total_pln,
	SUM(total_consumption) FILTER (WHERE device_id = 27 AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')) as plts_a,
	SUM(total_consumption) FILTER (WHERE device_id = 11 AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')) as plts_b,
	SUM(total_consumption) FILTER (WHERE device_id IN (94,11,27) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')) as total_purchase,
	SUM(total_consumption) FILTER (WHERE device_id IN (84,11,27) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')) as divisi_kain,
	(
		SUM(total_consumption) FILTER (WHERE device_id = 94 AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')) - 
		SUM(total_consumption) FILTER (WHERE device_id = 84 AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3'))
	) as divisi_benang,
	(
		SUM(total_consumption) FILTER (WHERE device_id IN (25,26,28,23,24) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')) - 
		SUM(total_consumption) FILTER (WHERE device_id = 27 AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3'))
	) as factory_a_pln,
	(
		SUM(total_consumption) FILTER (WHERE device_id = 12 AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')) - 
		SUM(total_consumption) FILTER (WHERE device_id = 11 AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3'))
	) as factory_b_pln
FROM daily_energy_cost_summary
WHERE
	tenant_id = 3
	AND device_id = ANY(ARRAY[11,12,23,24,25,26,27,28,84,94])
	AND quantity_id = 124
	AND daily_bucket BETWEEN
		date_trunc('month', NOW() + INTERVAL '7 hours') AND
		(NOW() + INTERVAL '7 hours') - INTERVAL '1 day'
GROUP BY
	daily_bucket
ORDER BY
	daily_bucket;
END;
$$;


--
-- Name: format_value(numeric, boolean); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.format_value(p_value numeric, p_is_cost boolean) RETURNS text
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF p_is_cost THEN
        RETURN TO_CHAR(ROUND(p_value::numeric, 2), 'FM999,999,999,990.00');
    ELSE
        RETURN CASE 
            WHEN p_value >= 1000000 THEN TO_CHAR(ROUND(p_value/1000000.0, 2), 'FM999999999.00')
            WHEN p_value >= 1000 THEN TO_CHAR(ROUND(p_value/1000.0, 2), 'FM999999999.00')
            ELSE TO_CHAR(ROUND(p_value::numeric, 2), 'FM999999999.00')
        END;
    END IF;
END;
$$;


--
-- Name: get_daily_device_breakdown(boolean, integer[], integer[], integer, integer); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.get_daily_device_breakdown(p_is_cost boolean DEFAULT false, p_grid_devices integer[] DEFAULT ARRAY[94], p_pv_devices integer[] DEFAULT ARRAY[11, 27], p_days_offset integer DEFAULT 0, p_quantity_id integer DEFAULT 124) RETURNS TABLE(device_id integer, main_value text, main_value_unit text, title text, subtitle text, stat1_label text, stat1_value text, stat1_unit text, stat2_label text, stat2_value text, stat2_unit text, stat3_label text, stat3_value text, stat3_unit text, stat4_label text, stat4_value text, stat4_unit text, stat5_label text, stat5_value text, stat5_unit text, stat6_label text, stat6_value text, stat6_unit text, stat7_label text, stat7_value text, stat7_unit text, total_energy numeric, shift1_energy numeric, shift2_energy numeric, shift3_energy numeric, grid_peak_energy numeric, grid_offpeak_energy numeric, pv_day_energy numeric, grid_energy numeric)
    LANGUAGE plpgsql
    AS $$
DECLARE
    target_date TIMESTAMP;
    all_devices INTEGER[];
BEGIN
    -- Calculate target date
    target_date := DATE_TRUNC('day', 
        (NOW() AT TIME ZONE 'Asia/Jakarta') - (p_days_offset || ' days')::INTERVAL
    )::TIMESTAMP;
    
    all_devices := p_grid_devices || p_pv_devices;
    
    RETURN QUERY
    WITH daily_energy AS(
        SELECT
            c.daily_bucket,
			c.device_id as device_breakdown,
            MAX(c.last_refreshed) AT TIME ZONE 'Asia/Jakarta' as last_entry,
            COALESCE(SUM(CASE WHEN p_is_cost THEN c.total_cost ELSE c.total_consumption END) 
                     FILTER (WHERE c.shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN c.total_cost ELSE c.total_consumption END) 
                     FILTER (WHERE c.device_id = ANY(p_grid_devices) AND c.grouping_type='SHIFT_RATE' 
                             AND c.shift_period IN ('SHIFT1','SHIFT3','SHIFT2')),0) as grid_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN c.total_cost ELSE c.total_consumption END) 
                     FILTER (WHERE c.device_id = ANY(p_pv_devices) AND c.grouping_type='SHIFT_RATE' 
                             AND c.shift_period IN ('SHIFT1','SHIFT3','SHIFT2')),0) as pv_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN c.total_cost ELSE c.total_consumption END) 
                     FILTER (WHERE c.grouping_type='SHIFT_RATE' AND c.shift_period='SHIFT1'),0) as shift1_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN c.total_cost ELSE c.total_consumption END) 
                     FILTER (WHERE c.grouping_type='SHIFT_RATE' AND c.shift_period='SHIFT2'),0) as shift2_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN c.total_cost ELSE c.total_consumption END) 
                     FILTER (WHERE c.grouping_type='SHIFT_RATE' AND c.shift_period='SHIFT3'),0) as shift3_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN c.total_cost ELSE c.total_consumption END) 
                     FILTER (WHERE c.device_id = ANY(p_grid_devices) AND c.grouping_type='SHIFT_RATE' 
                             AND c.rate_code IN ('LWBP1', 'LWBP2')),0) as grid_offpeak_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN c.total_cost ELSE c.total_consumption END) 
                     FILTER (WHERE c.device_id = ANY(p_grid_devices) AND c.grouping_type='SHIFT_RATE' 
                             AND c.rate_code = 'WBP'),0) as grid_peak_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN c.total_cost ELSE c.total_consumption END) 
                     FILTER (WHERE c.device_id = ANY(p_pv_devices) AND c.grouping_type='SHIFT_RATE' 
                             AND c.rate_code = 'PV'),0) as pv_day_energy
        FROM
            daily_energy_cost_summary c
        WHERE
            c.tenant_id = 3
            AND c.device_id = ANY(all_devices)
            AND c.quantity_id = p_quantity_id
            AND c.daily_bucket = target_date
        GROUP BY c.daily_bucket, c.device_id
        ORDER BY c.daily_bucket
    )
    SELECT
		d.device_breakdown as device_id,
        -- Main Value: Today's Total Energy
        CASE 
            WHEN p_is_cost THEN
                TO_CHAR(ROUND(d.total_energy::numeric, 2), 'FM999,999,999,990.00')
            WHEN d.total_energy >= 1000000 THEN 
                TO_CHAR(ROUND(d.total_energy/1000000.0, 2), 'FM999999999.00')
            WHEN d.total_energy >= 1000 THEN 
                TO_CHAR(ROUND(d.total_energy/1000.0, 2), 'FM999999999.00')
            ELSE 
                TO_CHAR(ROUND(d.total_energy::numeric, 2), 'FM999999999.00')
        END::TEXT as main_value,
        
        CASE 
            WHEN p_is_cost THEN 'Rp.'
            WHEN d.total_energy >= 1000000 THEN 'GWh'
            WHEN d.total_energy >= 1000 THEN 'MWh'
            ELSE 'kWh'
        END::TEXT as main_value_unit,
        
        TO_CHAR(d.daily_bucket, 'DD Month YYYY')::TEXT as title,
		CASE
			WHEN p_days_offset >0 THEN '24 hours'
			ELSE CONCAT('As of ',TO_CHAR(d.last_entry, 'HH24:MI'))::TEXT
        END::TEXT as subtitle,
        -- Stat 1: Shift 1 (07:00 - 15:00)
        'Shift 1 (07-15)'::TEXT as stat1_label,
        prs.format_value(d.shift1_energy, p_is_cost)::TEXT as stat1_value,
        prs.get_unit(d.shift1_energy, p_is_cost)::TEXT as stat1_unit,
        
        -- Stat 2: Shift 2 (15:00 - 23:00)
        'Shift 2 (15-23)'::TEXT as stat2_label,
        prs.format_value(d.shift2_energy, p_is_cost)::TEXT as stat2_value,
        prs.get_unit(d.shift2_energy, p_is_cost)::TEXT as stat2_unit,
        
        -- Stat 3: Shift 3 (23:00 yesterday - 07:00 today)
        'Shift 3 (23-07)'::TEXT as stat3_label,
        prs.format_value(d.shift3_energy, p_is_cost)::TEXT as stat3_value,
        prs.get_unit(d.shift3_energy, p_is_cost)::TEXT as stat3_unit,
        
        -- Stat 4: Peak (18:00 - 22:00)
        'Peak (18-22)'::TEXT as stat4_label,
        prs.format_value(d.grid_peak_energy, p_is_cost)::TEXT as stat4_value,
        prs.get_unit(d.grid_peak_energy, p_is_cost)::TEXT as stat4_unit,
        
        -- Stat 5: Off Peak
        'Off Peak'::TEXT as stat5_label,
        prs.format_value(d.grid_offpeak_energy, p_is_cost)::TEXT as stat5_value,
        prs.get_unit(d.grid_offpeak_energy, p_is_cost)::TEXT as stat5_unit,

        -- Stat 6: PV
        'PV'::TEXT as stat6_label,
        prs.format_value(d.pv_day_energy, p_is_cost)::TEXT as stat6_value,
        prs.get_unit(d.pv_day_energy, p_is_cost)::TEXT as stat6_unit,

       -- Stat 7: Grid
        'Grid'::TEXT as stat7_label,
        prs.format_value(d.grid_peak_energy + d.grid_offpeak_energy, p_is_cost)::TEXT as stat7_value,
        prs.get_unit(d.grid_peak_energy + d.grid_offpeak_energy, p_is_cost)::TEXT as stat7_unit,

		-- DEBUGGING VALUES, use to combine between devices arrays
		d.total_energy,
		d.shift1_energy,
		d.shift2_energy,
		d.shift3_energy,
		d.grid_peak_energy,
		d.grid_offpeak_energy,
		d.pv_day_energy,
		(d.grid_peak_energy + d.grid_offpeak_energy) as grid_energy

    FROM daily_energy d;
END;
$$;


--
-- Name: get_daily_summary(boolean, integer[], integer[], integer, integer); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.get_daily_summary(p_is_cost boolean DEFAULT false, p_grid_devices integer[] DEFAULT ARRAY[94], p_pv_devices integer[] DEFAULT ARRAY[11, 27], p_days_offset integer DEFAULT 0, p_quantity_id integer DEFAULT 124) RETURNS TABLE(main_value text, main_value_unit text, title text, subtitle text, stat1_label text, stat1_value text, stat1_unit text, stat2_label text, stat2_value text, stat2_unit text, stat3_label text, stat3_value text, stat3_unit text, stat4_label text, stat4_value text, stat4_unit text, stat5_label text, stat5_value text, stat5_unit text, stat6_label text, stat6_value text, stat6_unit text, stat7_label text, stat7_value text, stat7_unit text, total_energy numeric, shift1_energy numeric, shift2_energy numeric, shift3_energy numeric, grid_peak_energy numeric, grid_offpeak_energy numeric, pv_day_energy numeric, grid_energy numeric)
    LANGUAGE plpgsql
    AS $$
DECLARE
    target_date TIMESTAMP;
    all_devices INTEGER[];
BEGIN
    -- Calculate target date
    target_date := DATE_TRUNC('day', 
        (NOW() AT TIME ZONE 'Asia/Jakarta') - (p_days_offset || ' days')::INTERVAL
    )::TIMESTAMP;
    
    all_devices := p_grid_devices || p_pv_devices;
    
    RETURN QUERY
    WITH daily_energy AS(
        SELECT
            daily_bucket,
            MAX(last_refreshed) AT TIME ZONE 'Asia/Jakarta' as last_entry,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(p_grid_devices) AND grouping_type='SHIFT_RATE' 
                             AND shift_period IN ('SHIFT1','SHIFT3','SHIFT2')),0) as grid_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(p_pv_devices) AND grouping_type='SHIFT_RATE' 
                             AND shift_period IN ('SHIFT1','SHIFT3','SHIFT2')),0) as pv_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE grouping_type='SHIFT_RATE' AND shift_period='SHIFT1'),0) as shift1_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE grouping_type='SHIFT_RATE' AND shift_period='SHIFT2'),0) as shift2_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE grouping_type='SHIFT_RATE' AND shift_period='SHIFT3'),0) as shift3_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(p_grid_devices) AND grouping_type='SHIFT_RATE' 
                             AND rate_code IN ('LWBP1', 'LWBP2')),0) as grid_offpeak_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(p_grid_devices) AND grouping_type='SHIFT_RATE' 
                             AND rate_code = 'WBP'),0) as grid_peak_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(p_pv_devices) AND grouping_type='SHIFT_RATE' 
                             AND rate_code = 'PV'),0) as pv_day_energy
        FROM
            daily_energy_cost_summary
        WHERE
            tenant_id = 3
            AND device_id = ANY(all_devices)
            AND quantity_id = p_quantity_id
            AND daily_bucket = target_date
        GROUP BY daily_bucket
        ORDER BY daily_bucket
    )
    SELECT
        -- Main Value: Today's Total Energy
        CASE 
            WHEN p_is_cost THEN
                TO_CHAR(ROUND(d.total_energy::numeric, 2), 'FM999,999,999,990.00')
            WHEN d.total_energy >= 1000000 THEN 
                TO_CHAR(ROUND(d.total_energy/1000000.0, 2), 'FM999999999.00')
            WHEN d.total_energy >= 1000 THEN 
                TO_CHAR(ROUND(d.total_energy/1000.0, 2), 'FM999999999.00')
            ELSE 
                TO_CHAR(ROUND(d.total_energy::numeric, 2), 'FM999999999.00')
        END::TEXT as main_value,
        
        CASE 
            WHEN p_is_cost THEN 'Rp.'
            WHEN d.total_energy >= 1000000 THEN 'GWh'
            WHEN d.total_energy >= 1000 THEN 'MWh'
            ELSE 'kWh'
        END::TEXT as main_value_unit,
        
        TO_CHAR(d.daily_bucket, 'DD Month YYYY')::TEXT as title,
		CASE
			WHEN p_days_offset >0 THEN '24 hours'
			ELSE CONCAT('As of ',TO_CHAR(d.last_entry, 'HH24:MI'))::TEXT
        END::TEXT as subtitle,
        -- Stat 1: Shift 1 (07:00 - 15:00)
        'Shift 1 (07-15)'::TEXT as stat1_label,
        prs.format_value(d.shift1_energy, p_is_cost)::TEXT as stat1_value,
        prs.get_unit(d.shift1_energy, p_is_cost)::TEXT as stat1_unit,
        
        -- Stat 2: Shift 2 (15:00 - 23:00)
        'Shift 2 (15-23)'::TEXT as stat2_label,
        prs.format_value(d.shift2_energy, p_is_cost)::TEXT as stat2_value,
        prs.get_unit(d.shift2_energy, p_is_cost)::TEXT as stat2_unit,
        
        -- Stat 3: Shift 3 (23:00 yesterday - 07:00 today)
        'Shift 3 (23-07)'::TEXT as stat3_label,
        prs.format_value(d.shift3_energy, p_is_cost)::TEXT as stat3_value,
        prs.get_unit(d.shift3_energy, p_is_cost)::TEXT as stat3_unit,
        
        -- Stat 4: Peak (18:00 - 22:00)
        'Peak (18-22)'::TEXT as stat4_label,
        prs.format_value(d.grid_peak_energy, p_is_cost)::TEXT as stat4_value,
        prs.get_unit(d.grid_peak_energy, p_is_cost)::TEXT as stat4_unit,
        
        -- Stat 5: Off Peak
        'Off Peak'::TEXT as stat5_label,
        prs.format_value(d.grid_offpeak_energy, p_is_cost)::TEXT as stat5_value,
        prs.get_unit(d.grid_offpeak_energy, p_is_cost)::TEXT as stat5_unit,

        -- Stat 6: PV
        'PV'::TEXT as stat6_label,
        prs.format_value(d.pv_day_energy, p_is_cost)::TEXT as stat6_value,
        prs.get_unit(d.pv_day_energy, p_is_cost)::TEXT as stat6_unit,

       -- Stat 7: Grid
        'Grid'::TEXT as stat7_label,
        prs.format_value(d.grid_peak_energy + d.grid_offpeak_energy, p_is_cost)::TEXT as stat7_value,
        prs.get_unit(d.grid_peak_energy + d.grid_offpeak_energy, p_is_cost)::TEXT as stat7_unit,

		-- DEBUGGING VALUES, use to combine between devices arrays
		d.total_energy,
		d.shift1_energy,
		d.shift2_energy,
		d.shift3_energy,
		d.grid_peak_energy,
		d.grid_offpeak_energy,
		d.pv_day_energy,
		(d.grid_peak_energy + d.grid_offpeak_energy) as grid_energy

    FROM daily_energy d;
END;
$$;


--
-- Name: get_energy_time_series(boolean, integer[], integer[], date, date, character varying, integer); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.get_energy_time_series(p_is_cost boolean DEFAULT false, p_grid_devices integer[] DEFAULT ARRAY[94], p_pv_devices integer[] DEFAULT ARRAY[11, 27], p_start_date date DEFAULT NULL::date, p_end_date date DEFAULT NULL::date, p_group_by character varying DEFAULT 'DAY'::character varying, p_quantity_id integer DEFAULT 124) RETURNS TABLE(time_bucket timestamp without time zone, total_energy numeric, grid_energy numeric, pv_energy numeric, shift1_energy numeric, shift2_energy numeric, shift3_energy numeric, peak_energy numeric, offpeak_energy numeric, pv_day_energy numeric, formatted_date text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    start_date DATE;
    end_date DATE;
    all_devices INTEGER[];
BEGIN
    -- Set default date range if not provided
    start_date := COALESCE(p_start_date, CURRENT_DATE - INTERVAL '30 days');
    end_date := COALESCE(p_end_date, CURRENT_DATE);
    
    all_devices := p_grid_devices || p_pv_devices;
    
    RETURN QUERY
    -- KEY FIX: Add the time bucket transformation in the SELECT and GROUP BY
    SELECT 
        CASE 
            WHEN p_group_by = 'WEEK' THEN DATE_TRUNC('week', daily_bucket)
            WHEN p_group_by = 'MONTH' THEN DATE_TRUNC('month', daily_bucket)
            ELSE daily_bucket
        END as time_bucket,
        
        -- Aggregate the sums across the time bucket
        COALESCE(SUM(
            CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END
        ) FILTER (WHERE grouping_type = 'SHIFT_RATE' AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')), 0) as total_energy,
        
        COALESCE(SUM(
            CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END
        ) FILTER (WHERE device_id = ANY(p_grid_devices) AND grouping_type = 'SHIFT_RATE'), 0) as grid_energy,
        
        COALESCE(SUM(
            CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END
        ) FILTER (WHERE device_id = ANY(p_pv_devices) AND grouping_type = 'SHIFT_RATE'), 0) as pv_energy,
        
        COALESCE(SUM(
            CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END
        ) FILTER (WHERE grouping_type = 'SHIFT_RATE' AND shift_period = 'SHIFT1'), 0) as shift1_energy,
        
        COALESCE(SUM(
            CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END
        ) FILTER (WHERE grouping_type = 'SHIFT_RATE' AND shift_period = 'SHIFT2'), 0) as shift2_energy,
        
        COALESCE(SUM(
            CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END
        ) FILTER (WHERE grouping_type = 'SHIFT_RATE' AND shift_period = 'SHIFT3'), 0) as shift3_energy,
        
        COALESCE(SUM(
            CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END
        ) FILTER (WHERE device_id = ANY(p_grid_devices) AND grouping_type = 'SHIFT_RATE' 
                    AND rate_code = 'WBP'), 0) as peak_energy,
        
        COALESCE(SUM(
            CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END
        ) FILTER (WHERE device_id = ANY(p_grid_devices) AND grouping_type = 'SHIFT_RATE' 
                    AND rate_code IN ('LWBP1', 'LWBP2')), 0) as offpeak_energy,

        COALESCE(SUM(
            CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END
        ) FILTER (WHERE device_id = ANY(p_pv_devices) AND grouping_type = 'SHIFT_RATE'), 0) as pv_day_energy,

		TO_CHAR(
            CASE 
                WHEN p_group_by = 'WEEK' THEN DATE_TRUNC('week', daily_bucket)
                WHEN p_group_by = 'MONTH' THEN DATE_TRUNC('month', daily_bucket)
                ELSE daily_bucket
            END, 
            CASE p_group_by
                WHEN 'WEEK' THEN 'YYYY-MM-DD'
                WHEN 'MONTH' THEN 'YYYY-MM'
                ELSE 'YYYY-MM-DD'
            END
        ) as formatted_date
        
    FROM daily_energy_cost_summary
    WHERE tenant_id = 3
      AND device_id = ANY(all_devices)
      AND quantity_id = p_quantity_id
      AND daily_bucket BETWEEN start_date::TIMESTAMP AND end_date::TIMESTAMP
    -- KEY FIX: Group by the transformed time bucket
    GROUP BY 
        CASE 
            WHEN p_group_by = 'WEEK' THEN DATE_TRUNC('week', daily_bucket)
            WHEN p_group_by = 'MONTH' THEN DATE_TRUNC('month', daily_bucket)
            ELSE daily_bucket
        END
    ORDER BY time_bucket;
END;
$$;


--
-- Name: get_executive_summary(); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.get_executive_summary() RETURNS TABLE(period_bucket timestamp without time zone, consumption_wtd numeric, cons_wtd_pct numeric, cons_wtd_projected numeric, consumption_wtd_prev_period numeric, consumption_wtd_prev_full numeric, consumption_mtd numeric, cons_mtd_pct numeric, cons_mtd_projected numeric, consumption_mtd_prev_period numeric, consumption_mtd_prev_full numeric, cost_wtd numeric, cost_wtd_pct numeric, cost_wtd_proj numeric, cost_wtd_prev_period numeric, cost_wtd_prev_full numeric, cost_mtd numeric, cost_mtd_pct numeric, cost_mtd_proj numeric, cost_mtd_prev_period numeric, cost_mtd_prev_full numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH current_date_info AS (
        -- Determine the latest date and calculate period boundaries
        SELECT 
            MAX(daily_bucket) as latest_date,
            MAX(last_refreshed) as latest_refresh_time_utc,
            (MAX(last_refreshed) AT TIME ZONE 'Asia/Jakarta')::TIMESTAMP as latest_refresh_local,
            -- Current week boundaries (Monday start)
            DATE_TRUNC('week', MAX(daily_bucket))::DATE as current_week_start,
            -- Previous week boundaries (same Monday, one week back)
            (DATE_TRUNC('week', MAX(daily_bucket)) - INTERVAL '7 days')::DATE as previous_week_start,
            -- Current month boundaries
            DATE_TRUNC('month', MAX(daily_bucket))::DATE as current_month_start,
            -- Previous month boundaries
            (DATE_TRUNC('month', MAX(daily_bucket)) - INTERVAL '1 month')::DATE as previous_month_start,
            -- Calculate elapsed days in current week (1-7, where Monday=1)
            (MAX(daily_bucket)::DATE - DATE_TRUNC('week', MAX(daily_bucket))::DATE + 1) as days_elapsed_in_week,
            -- Calculate elapsed days in current month
            EXTRACT(DAY FROM MAX(daily_bucket))::INTEGER as days_elapsed_in_month,
            -- Total days in current month
            EXTRACT(DAY FROM (DATE_TRUNC('month', MAX(daily_bucket)) + INTERVAL '1 month' - INTERVAL '1 day'))::INTEGER as days_in_current_month,
            -- Total days in previous month
            EXTRACT(DAY FROM (DATE_TRUNC('month', MAX(daily_bucket)) - INTERVAL '1 day'))::INTEGER as days_in_previous_month
        FROM daily_energy_cost_summary
        WHERE tenant_id = 3
          AND device_id IN (94, 11, 27)  -- Grid and PV devices
          AND quantity_id = 124  -- Active energy (kWh)
          AND grouping_type = 'SHIFT_RATE'
    ),
    
    latest_day_projection AS (
        -- Project partial day data to full 24-hour day
        SELECT 
            cdi.latest_date,
            cdi.latest_refresh_local,
            -- Calculate elapsed hours from midnight to latest refresh (in local time)
            EXTRACT(EPOCH FROM (cdi.latest_refresh_local - cdi.latest_date)) / 3600.0 as elapsed_hours,
            -- Sum partial day consumption and cost
            COALESCE(SUM(decs.total_consumption), 0) as partial_consumption,
            COALESCE(SUM(decs.total_cost), 0) as partial_cost,
            -- Project to full 24 hours only if we have at least 6 hours of data
            CASE 
                WHEN EXTRACT(EPOCH FROM (cdi.latest_refresh_local - cdi.latest_date)) / 3600.0 >= 6 THEN
                    COALESCE(SUM(decs.total_consumption), 0) * 24.0 / 
                    (EXTRACT(EPOCH FROM (cdi.latest_refresh_local - cdi.latest_date)) / 3600.0)
                ELSE 
                    0  -- Not enough data to project reliably
            END as projected_consumption,
            CASE 
                WHEN EXTRACT(EPOCH FROM (cdi.latest_refresh_local - cdi.latest_date)) / 3600.0 >= 6 THEN
                    COALESCE(SUM(decs.total_cost), 0) * 24.0 / 
                    (EXTRACT(EPOCH FROM (cdi.latest_refresh_local - cdi.latest_date)) / 3600.0)
                ELSE 
                    0  -- Not enough data to project reliably
            END as projected_cost
        FROM current_date_info cdi
        LEFT JOIN daily_energy_cost_summary decs 
            ON decs.daily_bucket = cdi.latest_date
            AND decs.tenant_id = 3
            AND decs.device_id IN (94, 11, 27)
            AND decs.quantity_id = 124
            AND decs.grouping_type = 'SHIFT_RATE'
        GROUP BY cdi.latest_date, cdi.latest_refresh_local
    ),
    
    current_wtd AS (
        -- Calculate week-to-date with projected current day
        SELECT 
            cdi.days_elapsed_in_week,
            -- Sum complete days (before latest date)
            COALESCE(SUM(decs.total_consumption), 0) as complete_days_consumption,
            COALESCE(SUM(decs.total_cost), 0) as complete_days_cost,
            -- Add projected current day
            COALESCE(SUM(decs.total_consumption), 0) + COALESCE(ldp.projected_consumption, 0) as wtd_consumption,
            COALESCE(SUM(decs.total_cost), 0) + COALESCE(ldp.projected_cost, 0) as wtd_cost
        FROM current_date_info cdi
        CROSS JOIN latest_day_projection ldp
        LEFT JOIN daily_energy_cost_summary decs
            ON decs.daily_bucket >= cdi.current_week_start
            AND decs.daily_bucket < cdi.latest_date  -- Exclude latest date (using projection instead)
            AND decs.tenant_id = 3
            AND decs.device_id IN (94, 11, 27)
            AND decs.quantity_id = 124
            AND decs.grouping_type = 'SHIFT_RATE'
        GROUP BY cdi.days_elapsed_in_week, ldp.projected_consumption, ldp.projected_cost
    ),
    
    previous_wtd_period AS (
        -- Calculate same elapsed days from previous week (all complete days)
        SELECT 
            COALESCE(SUM(decs.total_consumption), 0) as prev_wtd_consumption,
            COALESCE(SUM(decs.total_cost), 0) as prev_wtd_cost
        FROM current_date_info cdi
        LEFT JOIN daily_energy_cost_summary decs
            ON decs.daily_bucket >= cdi.previous_week_start
            AND decs.daily_bucket < cdi.previous_week_start + (cdi.days_elapsed_in_week::TEXT || ' days')::INTERVAL
            AND decs.tenant_id = 3
            AND decs.device_id IN (94, 11, 27)
            AND decs.quantity_id = 124
            AND decs.grouping_type = 'SHIFT_RATE'
        GROUP BY cdi.previous_week_start, cdi.days_elapsed_in_week
    ),
    
    previous_wtd_full AS (
        -- Calculate FULL previous week (7 complete days)
        SELECT 
            COALESCE(SUM(decs.total_consumption), 0) as prev_week_full_consumption,
            COALESCE(SUM(decs.total_cost), 0) as prev_week_full_cost
        FROM current_date_info cdi
        LEFT JOIN daily_energy_cost_summary decs
            ON decs.daily_bucket >= cdi.previous_week_start
            AND decs.daily_bucket < cdi.previous_week_start + INTERVAL '7 days'
            AND decs.tenant_id = 3
            AND decs.device_id IN (94, 11, 27)
            AND decs.quantity_id = 124
            AND decs.grouping_type = 'SHIFT_RATE'
        GROUP BY cdi.previous_week_start
    ),
    
    current_mtd AS (
        -- Calculate month-to-date with projected current day
        SELECT 
            cdi.days_elapsed_in_month,
            cdi.days_in_current_month,
            -- Sum complete days (before latest date)
            COALESCE(SUM(decs.total_consumption), 0) as complete_days_consumption,
            COALESCE(SUM(decs.total_cost), 0) as complete_days_cost,
            -- Add projected current day
            COALESCE(SUM(decs.total_consumption), 0) + COALESCE(ldp.projected_consumption, 0) as mtd_consumption,
            COALESCE(SUM(decs.total_cost), 0) + COALESCE(ldp.projected_cost, 0) as mtd_cost
        FROM current_date_info cdi
        CROSS JOIN latest_day_projection ldp
        LEFT JOIN daily_energy_cost_summary decs
            ON decs.daily_bucket >= cdi.current_month_start
            AND decs.daily_bucket < cdi.latest_date  -- Exclude latest date (using projection instead)
            AND decs.tenant_id = 3
            AND decs.device_id IN (94, 11, 27)
            AND decs.quantity_id = 124
            AND decs.grouping_type = 'SHIFT_RATE'
        GROUP BY cdi.days_elapsed_in_month, cdi.days_in_current_month, 
                 ldp.projected_consumption, ldp.projected_cost
    ),
    
    previous_mtd_period AS (
        -- Calculate same elapsed days from previous month (all complete days)
        SELECT 
            COALESCE(SUM(decs.total_consumption), 0) as prev_mtd_consumption,
            COALESCE(SUM(decs.total_cost), 0) as prev_mtd_cost
        FROM current_date_info cdi
        LEFT JOIN daily_energy_cost_summary decs
            ON decs.daily_bucket >= cdi.previous_month_start
            AND decs.daily_bucket < cdi.previous_month_start + (cdi.days_elapsed_in_month::TEXT || ' days')::INTERVAL
            AND decs.tenant_id = 3
            AND decs.device_id IN (94, 11, 27)
            AND decs.quantity_id = 124
            AND decs.grouping_type = 'SHIFT_RATE'
        GROUP BY cdi.previous_month_start, cdi.days_elapsed_in_month
    ),
    
    previous_mtd_full AS (
        -- Calculate FULL previous month (all days in that month)
        SELECT 
            COALESCE(SUM(decs.total_consumption), 0) as prev_month_full_consumption,
            COALESCE(SUM(decs.total_cost), 0) as prev_month_full_cost
        FROM current_date_info cdi
        LEFT JOIN daily_energy_cost_summary decs
            ON decs.daily_bucket >= cdi.previous_month_start
            AND decs.daily_bucket < cdi.current_month_start  -- All days in previous month
            AND decs.tenant_id = 3
            AND decs.device_id IN (94, 11, 27)
            AND decs.quantity_id = 124
            AND decs.grouping_type = 'SHIFT_RATE'
        GROUP BY cdi.previous_month_start, cdi.current_month_start
    )
    
    -- Final SELECT: Combine all metrics with calculations
    SELECT 
        cdi.latest_date as period_bucket,
        
        -- Week-to-Date Consumption Metrics
        ROUND(cwtd.wtd_consumption, 2) as consumption_wtd,
        CASE 
            WHEN pwtd_period.prev_wtd_consumption > 0 THEN
                ROUND(((cwtd.wtd_consumption - pwtd_period.prev_wtd_consumption) / pwtd_period.prev_wtd_consumption * 100), 2)
            ELSE NULL
        END as cons_wtd_pct,
        CASE 
            WHEN cdi.days_elapsed_in_week > 0 THEN
                ROUND((cwtd.wtd_consumption / cdi.days_elapsed_in_week * 7), 2)
            ELSE NULL
        END as cons_wtd_projected,
        ROUND(pwtd_period.prev_wtd_consumption, 2) as consumption_wtd_prev_period,
        ROUND(pwtd_full.prev_week_full_consumption, 2) as consumption_wtd_prev_full,  -- NEW
        
        -- Month-to-Date Consumption Metrics
        ROUND(cmtd.mtd_consumption, 2) as consumption_mtd,
        CASE 
            WHEN pmtd_period.prev_mtd_consumption > 0 THEN
                ROUND(((cmtd.mtd_consumption - pmtd_period.prev_mtd_consumption) / pmtd_period.prev_mtd_consumption * 100), 2)
            ELSE NULL
        END as cons_mtd_pct,
        CASE 
            WHEN cdi.days_elapsed_in_month > 0 THEN
                ROUND((cmtd.mtd_consumption / cdi.days_elapsed_in_month * cmtd.days_in_current_month), 2)
            ELSE NULL
        END as cons_mtd_projected,
        ROUND(pmtd_period.prev_mtd_consumption, 2) as consumption_mtd_prev_period,
        ROUND(pmtd_full.prev_month_full_consumption, 2) as consumption_mtd_prev_full,  -- NEW
        
        -- Week-to-Date Cost Metrics
        ROUND(cwtd.wtd_cost, 2) as cost_wtd,
        CASE 
            WHEN pwtd_period.prev_wtd_cost > 0 THEN
                ROUND(((cwtd.wtd_cost - pwtd_period.prev_wtd_cost) / pwtd_period.prev_wtd_cost * 100), 2)
            ELSE NULL
        END as cost_wtd_pct,
        CASE 
            WHEN cdi.days_elapsed_in_week > 0 THEN
                ROUND((cwtd.wtd_cost / cdi.days_elapsed_in_week * 7), 2)
            ELSE NULL
        END as cost_wtd_proj,
        ROUND(pwtd_period.prev_wtd_cost, 2) as cost_wtd_prev_period,
        ROUND(pwtd_full.prev_week_full_cost, 2) as cost_wtd_prev_full,  -- NEW
        
        -- Month-to-Date Cost Metrics
        ROUND(cmtd.mtd_cost, 2) as cost_mtd,
        CASE 
            WHEN pmtd_period.prev_mtd_cost > 0 THEN
                ROUND(((cmtd.mtd_cost - pmtd_period.prev_mtd_cost) / pmtd_period.prev_mtd_cost * 100), 2)
            ELSE NULL
        END as cost_mtd_pct,
        CASE 
            WHEN cdi.days_elapsed_in_month > 0 THEN
                ROUND((cmtd.mtd_cost / cdi.days_elapsed_in_month * cmtd.days_in_current_month), 2)
            ELSE NULL
        END as cost_mtd_proj,
        ROUND(pmtd_period.prev_mtd_cost, 2) as cost_mtd_prev_period,
        ROUND(pmtd_full.prev_month_full_cost, 2) as cost_mtd_prev_full  -- NEW
        
    FROM current_date_info cdi
    CROSS JOIN latest_day_projection ldp
    CROSS JOIN current_wtd cwtd
    CROSS JOIN previous_wtd_period pwtd_period
    CROSS JOIN previous_wtd_full pwtd_full  -- NEW
    CROSS JOIN current_mtd cmtd
    CROSS JOIN previous_mtd_period pmtd_period
    CROSS JOIN previous_mtd_full pmtd_full;  -- NEW
END;
$$;


--
-- Name: FUNCTION get_executive_summary(); Type: COMMENT; Schema: prs; Owner: -
--

COMMENT ON FUNCTION prs.get_executive_summary() IS 'Executive dashboard summary providing WTD and MTD metrics for energy consumption and cost.
Includes percentage changes vs previous periods, full-period projections, previous period same-day values, and previous period full values.
Handles partial day data by projecting to 24 hours (minimum 6 hours required).
Uses Asia/Jakarta timezone for elapsed time calculations.
Hardcoded for tenant_id=3 with devices [94,11,27] and quantity_id=124 (Active Energy kWh).
Returns single row with 21 columns including both previous period (same elapsed days) and previous full period values.';


--
-- Name: get_executive_summary_formatted(); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.get_executive_summary_formatted() RETURNS TABLE(period_date text, wtd_period_range text, mtd_period_day text, consumption_wtd text, consumption_wtd_unit text, consumption_wtd_prev text, consumption_wtd_prev_unit text, consumption_wtd_prev_full text, consumption_wtd_prev_full_unit text, cons_wtd_projected text, cons_wtd_projected_unit text, cons_wtd_pct text, cons_wtd_trend_class text, cons_wtd_arrow text, consumption_mtd text, consumption_mtd_unit text, consumption_mtd_prev text, consumption_mtd_prev_unit text, consumption_mtd_prev_full text, consumption_mtd_prev_full_unit text, cons_mtd_projected text, cons_mtd_projected_unit text, cons_mtd_pct text, cons_mtd_trend_class text, cons_mtd_arrow text, cost_wtd text, cost_wtd_prev text, cost_wtd_prev_full text, cost_wtd_projected text, cost_wtd_pct text, cost_wtd_trend_class text, cost_wtd_arrow text, cost_mtd text, cost_mtd_prev text, cost_mtd_prev_full text, cost_mtd_projected text, cost_mtd_pct text, cost_mtd_trend_class text, cost_mtd_arrow text)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_raw RECORD;
  v_wtd_start DATE;
  v_wtd_end DATE;
  v_mtd_day TEXT;
BEGIN
  -- Get raw data
  SELECT * INTO v_raw FROM prs.get_executive_summary();
  
  -- Calculate WTD period range (e.g., "From Mon, 29 Sep to Thu, 2 Oct")
  v_wtd_start := DATE_TRUNC('week', v_raw.period_bucket)::DATE;
  v_wtd_end := v_raw.period_bucket::DATE;
  
  wtd_period_range := 'From ' || 
    TO_CHAR(v_wtd_start, 'Dy, DD Mon') || 
    ' to ' || 
    TO_CHAR(v_wtd_end, 'Dy, DD Mon');
  
  -- Calculate MTD period day (e.g., "Through 2 Oct")
  mtd_period_day := 'Through ' || TO_CHAR(v_raw.period_bucket, 'DD Mon');
  
  -- Period date for display
  period_date := TO_CHAR(v_raw.period_bucket, 'DD Mon YYYY');
  
  -- ==================================================================
  -- WTD CONSUMPTION with unit normalization
  -- ==================================================================
  
  -- Current WTD
  IF v_raw.consumption_wtd >= 1000000 THEN
    consumption_wtd := TO_CHAR(v_raw.consumption_wtd / 1000000, 'FM999,999.0');
    consumption_wtd_unit := 'GWh';
  ELSIF v_raw.consumption_wtd >= 1000 THEN
    consumption_wtd := TO_CHAR(v_raw.consumption_wtd / 1000, 'FM999,999.0');
    consumption_wtd_unit := 'MWh';
  ELSE
    consumption_wtd := TO_CHAR(v_raw.consumption_wtd, 'FM999,999.0');
    consumption_wtd_unit := 'kWh';
  END IF;
  
  -- Previous WTD (same period)
  IF v_raw.consumption_wtd_prev_period >= 1000000 THEN
    consumption_wtd_prev := TO_CHAR(v_raw.consumption_wtd_prev_period / 1000000, 'FM999,999.0');
    consumption_wtd_prev_unit := 'GWh';
  ELSIF v_raw.consumption_wtd_prev_period >= 1000 THEN
    consumption_wtd_prev := TO_CHAR(v_raw.consumption_wtd_prev_period / 1000, 'FM999,999.0');
    consumption_wtd_prev_unit := 'MWh';
  ELSE
    consumption_wtd_prev := TO_CHAR(v_raw.consumption_wtd_prev_period, 'FM999,999.0');
    consumption_wtd_prev_unit := 'kWh';
  END IF;
  
  -- Previous WTD (full week)
  IF v_raw.consumption_wtd_prev_full >= 1000000 THEN
    consumption_wtd_prev_full := TO_CHAR(v_raw.consumption_wtd_prev_full / 1000000, 'FM999,999.0');
    consumption_wtd_prev_full_unit := 'GWh';
  ELSIF v_raw.consumption_wtd_prev_full >= 1000 THEN
    consumption_wtd_prev_full := TO_CHAR(v_raw.consumption_wtd_prev_full / 1000, 'FM999,999.0');
    consumption_wtd_prev_full_unit := 'MWh';
  ELSE
    consumption_wtd_prev_full := TO_CHAR(v_raw.consumption_wtd_prev_full, 'FM999,999.0');
    consumption_wtd_prev_full_unit := 'kWh';
  END IF;
  
  -- Projected WTD
  IF v_raw.cons_wtd_projected >= 1000000 THEN
    cons_wtd_projected := TO_CHAR(v_raw.cons_wtd_projected / 1000000, 'FM999,999.0');
    cons_wtd_projected_unit := 'GWh';
  ELSIF v_raw.cons_wtd_projected >= 1000 THEN
    cons_wtd_projected := TO_CHAR(v_raw.cons_wtd_projected / 1000, 'FM999,999.0');
    cons_wtd_projected_unit := 'MWh';
  ELSE
    cons_wtd_projected := TO_CHAR(v_raw.cons_wtd_projected, 'FM999,999.0');
    cons_wtd_projected_unit := 'kWh';
  END IF;
  
  -- WTD percentage and trend
  cons_wtd_pct := TO_CHAR(ABS(v_raw.cons_wtd_pct), 'FM990.00');
  
  IF v_raw.cons_wtd_pct < -0.5 THEN
    cons_wtd_trend_class := 'down';
    cons_wtd_arrow := '▼';
  ELSIF v_raw.cons_wtd_pct > 0.5 THEN
    cons_wtd_trend_class := 'up';
    cons_wtd_arrow := '▲';
  ELSE
    cons_wtd_trend_class := 'neutral';
    cons_wtd_arrow := '—';
  END IF;
  
  -- ==================================================================
  -- MTD CONSUMPTION with unit normalization
  -- ==================================================================
  
  -- Current MTD
  IF v_raw.consumption_mtd >= 1000000 THEN
    consumption_mtd := TO_CHAR(v_raw.consumption_mtd / 1000000, 'FM999,999.0');
    consumption_mtd_unit := 'GWh';
  ELSIF v_raw.consumption_mtd >= 1000 THEN
    consumption_mtd := TO_CHAR(v_raw.consumption_mtd / 1000, 'FM999,999.0');
    consumption_mtd_unit := 'MWh';
  ELSE
    consumption_mtd := TO_CHAR(v_raw.consumption_mtd, 'FM999,999.0');
    consumption_mtd_unit := 'kWh';
  END IF;
  
  -- Previous MTD (same period)
  IF v_raw.consumption_mtd_prev_period >= 1000000 THEN
    consumption_mtd_prev := TO_CHAR(v_raw.consumption_mtd_prev_period / 1000000, 'FM999,999.0');
    consumption_mtd_prev_unit := 'GWh';
  ELSIF v_raw.consumption_mtd_prev_period >= 1000 THEN
    consumption_mtd_prev := TO_CHAR(v_raw.consumption_mtd_prev_period / 1000, 'FM999,999.0');
    consumption_mtd_prev_unit := 'MWh';
  ELSE
    consumption_mtd_prev := TO_CHAR(v_raw.consumption_mtd_prev_period, 'FM999,999.0');
    consumption_mtd_prev_unit := 'kWh';
  END IF;
  
  -- Previous MTD (full month)
  IF v_raw.consumption_mtd_prev_full >= 1000000 THEN
    consumption_mtd_prev_full := TO_CHAR(v_raw.consumption_mtd_prev_full / 1000000, 'FM999,999.0');
    consumption_mtd_prev_full_unit := 'GWh';
  ELSIF v_raw.consumption_mtd_prev_full >= 1000 THEN
    consumption_mtd_prev_full := TO_CHAR(v_raw.consumption_mtd_prev_full / 1000, 'FM999,999.0');
    consumption_mtd_prev_full_unit := 'MWh';
  ELSE
    consumption_mtd_prev_full := TO_CHAR(v_raw.consumption_mtd_prev_full, 'FM999,999.0');
    consumption_mtd_prev_full_unit := 'kWh';
  END IF;
  
  -- Projected MTD
  IF v_raw.cons_mtd_projected >= 1000000 THEN
    cons_mtd_projected := TO_CHAR(v_raw.cons_mtd_projected / 1000000, 'FM999,999.0');
    cons_mtd_projected_unit := 'GWh';
  ELSIF v_raw.cons_mtd_projected >= 1000 THEN
    cons_mtd_projected := TO_CHAR(v_raw.cons_mtd_projected / 1000, 'FM999,999.0');
    cons_mtd_projected_unit := 'MWh';
  ELSE
    cons_mtd_projected := TO_CHAR(v_raw.cons_mtd_projected, 'FM999,999.0');
    cons_mtd_projected_unit := 'kWh';
  END IF;
  
  -- MTD percentage and trend
  cons_mtd_pct := TO_CHAR(ABS(v_raw.cons_mtd_pct), 'FM990.00');
  
  IF v_raw.cons_mtd_pct < -0.5 THEN
    cons_mtd_trend_class := 'down';
    cons_mtd_arrow := '▼';
  ELSIF v_raw.cons_mtd_pct > 0.5 THEN
    cons_mtd_trend_class := 'up';
    cons_mtd_arrow := '▲';
  ELSE
    cons_mtd_trend_class := 'neutral';
    cons_mtd_arrow := '—';
  END IF;
  
  -- ==================================================================
  -- WTD COST (in millions IDR)
  -- ==================================================================
  
  cost_wtd := TO_CHAR(v_raw.cost_wtd / 1000000, 'FM999,999.0');
  cost_wtd_prev := TO_CHAR(v_raw.cost_wtd_prev_period / 1000000, 'FM999,999.0');
  cost_wtd_prev_full := TO_CHAR(v_raw.cost_wtd_prev_full / 1000000, 'FM999,999.0');
  cost_wtd_projected := TO_CHAR(v_raw.cost_wtd_proj / 1000000, 'FM999,999.0');
  cost_wtd_pct := TO_CHAR(ABS(v_raw.cost_wtd_pct), 'FM990.00');
  
  IF v_raw.cost_wtd_pct < -0.5 THEN
    cost_wtd_trend_class := 'down';
    cost_wtd_arrow := '▼';
  ELSIF v_raw.cost_wtd_pct > 0.5 THEN
    cost_wtd_trend_class := 'up';
    cost_wtd_arrow := '▲';
  ELSE
    cost_wtd_trend_class := 'neutral';
    cost_wtd_arrow := '—';
  END IF;
  
  -- ==================================================================
  -- MTD COST (in millions IDR)
  -- ==================================================================
  
  cost_mtd := TO_CHAR(v_raw.cost_mtd / 1000000, 'FM999,999.0');
  cost_mtd_prev := TO_CHAR(v_raw.cost_mtd_prev_period / 1000000, 'FM999,999.0');
  cost_mtd_prev_full := TO_CHAR(v_raw.cost_mtd_prev_full / 1000000, 'FM999,999.0');
  cost_mtd_projected := TO_CHAR(v_raw.cost_mtd_proj / 1000000, 'FM999,999.0');
  cost_mtd_pct := TO_CHAR(ABS(v_raw.cost_mtd_pct), 'FM990.00');
  
  IF v_raw.cost_mtd_pct < -0.5 THEN
    cost_mtd_trend_class := 'down';
    cost_mtd_arrow := '▼';
  ELSIF v_raw.cost_mtd_pct > 0.5 THEN
    cost_mtd_trend_class := 'up';
    cost_mtd_arrow := '▲';
  ELSE
    cost_mtd_trend_class := 'neutral';
    cost_mtd_arrow := '—';
  END IF;
  
  RETURN NEXT;
END;
$$;


--
-- Name: get_factory_a_daily_summary(boolean, integer, integer); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.get_factory_a_daily_summary(p_is_cost boolean DEFAULT false, p_days_offset integer DEFAULT 0, p_quantity_id integer DEFAULT 124) RETURNS TABLE(main_value text, main_value_unit text, title text, subtitle text, stat1_label text, stat1_value text, stat1_unit text, stat2_label text, stat2_value text, stat2_unit text, stat3_label text, stat3_value text, stat3_unit text, stat4_label text, stat4_value text, stat4_unit text, stat5_label text, stat5_value text, stat5_unit text, stat6_label text, stat6_value text, stat6_unit text, stat7_label text, stat7_value text, stat7_unit text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    target_date TIMESTAMP;
    grid_devices INTEGER[] := ARRAY[23, 24, 25, 26, 28];
    pv_device INTEGER := 27;
BEGIN
    target_date := DATE_TRUNC('day', 
        (NOW() AT TIME ZONE 'Asia/Jakarta') - (p_days_offset || ' days')::INTERVAL
    )::TIMESTAMP;
    
    RETURN QUERY
    WITH daily_energy AS(
        SELECT
            daily_bucket,
            MAX(last_refreshed) AT TIME ZONE 'Asia/Jakarta' as last_entry,
            
            -- Consumption metrics (unchanged)
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = ANY(grid_devices)),0) as grid_meters_consumption,
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = pv_device AND rate_code = 'PV'),0) as pv_production,
            
            -- Shift consumption
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND shift_period = 'SHIFT1'),0) as shift1_consumption,
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND shift_period = 'SHIFT2'),0) as shift2_consumption,
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND shift_period = 'SHIFT3'),0) as shift3_consumption,
            
            -- PV by shift (for proportional allocation)
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = pv_device AND shift_period = 'SHIFT1'),0) as shift1_pv,
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = pv_device AND shift_period = 'SHIFT2'),0) as shift2_pv,
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = pv_device AND shift_period = 'SHIFT3'),0) as shift3_pv,
            
            -- Rate-based consumption
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND rate_code = 'WBP'),0) as grid_peak_consumption,
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND rate_code IN ('LWBP1', 'LWBP2')),0) as grid_offpeak_consumption,
            
            -- ============ COST METRICS ============
            
            -- Grid device costs (as billed, includes mixed grid+PV)
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = ANY(grid_devices)),0) as grid_meters_cost_raw,
            
            -- PV costs (operational cost)
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = pv_device AND rate_code = 'PV'),0) as pv_cost,
            
            -- Shift costs (raw from grid meters)
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND shift_period = 'SHIFT1'),0) as shift1_cost_raw,
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND shift_period = 'SHIFT2'),0) as shift2_cost_raw,
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND shift_period = 'SHIFT3'),0) as shift3_cost_raw,
            
            -- PV cost by shift
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = pv_device AND shift_period = 'SHIFT1'),0) as shift1_pv_cost,
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = pv_device AND shift_period = 'SHIFT2'),0) as shift2_pv_cost,
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = pv_device AND shift_period = 'SHIFT3'),0) as shift3_pv_cost,
            
            -- Rate-based costs
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND rate_code = 'WBP'),0) as grid_peak_cost,
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND rate_code IN ('LWBP1', 'LWBP2')),0) as grid_offpeak_cost_raw
            
        FROM daily_energy_cost_summary
        WHERE tenant_id = 3
          AND device_id = ANY(grid_devices || pv_device)
          AND quantity_id = p_quantity_id
          AND daily_bucket = target_date
          AND grouping_type = 'SHIFT_RATE'
        GROUP BY daily_bucket
    ),
    calculated_values AS (
        SELECT
            daily_bucket,
            last_entry,
            
            -- ============ CONSUMPTION VALUES ============
            grid_meters_consumption as total_consumption,
            shift1_consumption,
            shift2_consumption,
            shift3_consumption,
            grid_peak_consumption,
            (grid_offpeak_consumption - pv_production) as grid_offpeak_net,
            pv_production,
            (grid_meters_consumption - pv_production) as grid_net_consumption,
            
            -- ============ COST VALUES WITH PROPORTIONAL ALLOCATION ============
            
            -- Method: Adjusted Cost = Raw Grid Cost - (PV_kWh / Grid_kWh) * Raw Grid Cost + PV Cost
            
            -- Total cost (actual blended cost)
            grid_meters_cost_raw as total_cost_raw,
            
            -- Calculate PV proportion per shift
            CASE WHEN shift1_consumption > 0 
                 THEN shift1_cost_raw - (shift1_pv / NULLIF(shift1_consumption, 0)) * shift1_cost_raw + shift1_pv_cost
                 ELSE shift1_cost_raw 
            END as shift1_cost_adjusted,
            
            CASE WHEN shift2_consumption > 0 
                 THEN shift2_cost_raw - (shift2_pv / NULLIF(shift2_consumption, 0)) * shift2_cost_raw + shift2_pv_cost
                 ELSE shift2_cost_raw 
            END as shift2_cost_adjusted,
            
            CASE WHEN shift3_consumption > 0 
                 THEN shift3_cost_raw - (shift3_pv / NULLIF(shift3_consumption, 0)) * shift3_cost_raw + shift3_pv_cost
                 ELSE shift3_cost_raw 
            END as shift3_cost_adjusted,
            
            -- Peak cost (no PV during peak in Indonesia)
            grid_peak_cost as grid_peak_cost,
            
            -- Off-peak cost adjusted
            CASE WHEN grid_offpeak_consumption > 0
                 THEN grid_offpeak_cost_raw - (pv_production / NULLIF(grid_offpeak_consumption, 0)) * grid_offpeak_cost_raw + pv_cost
                 ELSE grid_offpeak_cost_raw
            END as grid_offpeak_cost_adjusted,
            
            -- PV cost
            pv_cost as pv_cost,
            
            -- Net grid cost (adjusted)
            CASE WHEN grid_meters_consumption > 0
                 THEN grid_meters_cost_raw - (pv_production / NULLIF(grid_meters_consumption, 0)) * grid_meters_cost_raw + pv_cost
                 ELSE grid_meters_cost_raw
            END as grid_net_cost_adjusted
            
        FROM daily_energy
    )
    SELECT
        -- Main Value
        CASE 
            WHEN p_is_cost THEN
                TO_CHAR(ROUND(CASE WHEN p_is_cost THEN c.total_cost_raw ELSE c.total_consumption END, 2), 'FM999,999,999,990.00')
            WHEN c.total_consumption >= 1000000 THEN 
                TO_CHAR(ROUND(c.total_consumption/1000000.0, 2), 'FM999999999.00')
            WHEN c.total_consumption >= 1000 THEN 
                TO_CHAR(ROUND(c.total_consumption/1000.0, 2), 'FM999999999.00')
            ELSE 
                TO_CHAR(ROUND(c.total_consumption, 2), 'FM999999999.00')
        END::TEXT as main_value,
        
        CASE 
            WHEN p_is_cost THEN 'Rp.'
            WHEN c.total_consumption >= 1000000 THEN 'GWh'
            WHEN c.total_consumption >= 1000 THEN 'MWh'
            ELSE 'kWh'
        END::TEXT as main_value_unit,
        
        TO_CHAR(c.daily_bucket, 'DD Month YYYY')::TEXT as title,
		CASE
			WHEN p_days_offset > 0 THEN '24 hours'
			ELSE CONCAT('As of ',TO_CHAR(c.last_entry, 'HH24:MI'))::TEXT
		END as subtitle,
        
        -- Stats
        'Shift 1 (07-15)'::TEXT as stat1_label,
        prs.format_value(CASE WHEN p_is_cost THEN c.shift1_cost_adjusted ELSE c.shift1_consumption END, p_is_cost)::TEXT as stat1_value,
        prs.get_unit(CASE WHEN p_is_cost THEN c.shift1_cost_adjusted ELSE c.shift1_consumption END, p_is_cost)::TEXT as stat1_unit,
        
        'Shift 2 (15-23)'::TEXT as stat2_label,
        prs.format_value(CASE WHEN p_is_cost THEN c.shift2_cost_adjusted ELSE c.shift2_consumption END, p_is_cost)::TEXT as stat2_value,
        prs.get_unit(CASE WHEN p_is_cost THEN c.shift2_cost_adjusted ELSE c.shift2_consumption END, p_is_cost)::TEXT as stat2_unit,
        
        'Shift 3 (23-07)'::TEXT as stat3_label,
        prs.format_value(CASE WHEN p_is_cost THEN c.shift3_cost_adjusted ELSE c.shift3_consumption END, p_is_cost)::TEXT as stat3_value,
        prs.get_unit(CASE WHEN p_is_cost THEN c.shift3_cost_adjusted ELSE c.shift3_consumption END, p_is_cost)::TEXT as stat3_unit,
        
        'Peak (18-22)'::TEXT as stat4_label,
        prs.format_value(CASE WHEN p_is_cost THEN c.grid_peak_cost ELSE c.grid_peak_consumption END, p_is_cost)::TEXT as stat4_value,
        prs.get_unit(CASE WHEN p_is_cost THEN c.grid_peak_cost ELSE c.grid_peak_consumption END, p_is_cost)::TEXT as stat4_unit,
        
        'Off Peak'::TEXT as stat5_label,
        prs.format_value(CASE WHEN p_is_cost THEN c.grid_offpeak_cost_adjusted ELSE c.grid_offpeak_net END, p_is_cost)::TEXT as stat5_value,
        prs.get_unit(CASE WHEN p_is_cost THEN c.grid_offpeak_cost_adjusted ELSE c.grid_offpeak_net END, p_is_cost)::TEXT as stat5_unit,

        'PV'::TEXT as stat6_label,
        prs.format_value(CASE WHEN p_is_cost THEN c.pv_cost ELSE c.pv_production END, p_is_cost)::TEXT as stat6_value,
        prs.get_unit(CASE WHEN p_is_cost THEN c.pv_cost ELSE c.pv_production END, p_is_cost)::TEXT as stat6_unit,

        'Grid (Net)'::TEXT as stat7_label,
        prs.format_value(CASE WHEN p_is_cost THEN c.grid_net_cost_adjusted ELSE c.grid_net_consumption END, p_is_cost)::TEXT as stat7_value,
        prs.get_unit(CASE WHEN p_is_cost THEN c.grid_net_cost_adjusted ELSE c.grid_net_consumption END, p_is_cost)::TEXT as stat7_unit

    FROM calculated_values c;
END;
$$;


--
-- Name: get_factory_a_device_breakdown(integer[], boolean, integer, integer); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.get_factory_a_device_breakdown(p_device_ids integer[] DEFAULT ARRAY[23, 24, 25, 26, 28], p_is_cost boolean DEFAULT false, p_days_offset integer DEFAULT 0, p_quantity_id integer DEFAULT 124) RETURNS TABLE(device_id integer, device_consumption numeric, device_cost_raw numeric, device_cost_adjusted numeric, pv_proportion numeric, cost_savings numeric, shift1_consumption numeric, shift1_cost_adjusted numeric, shift2_consumption numeric, shift2_cost_adjusted numeric, shift3_consumption numeric, shift3_cost_adjusted numeric)
    LANGUAGE plpgsql
    AS $$
DECLARE
    target_date TIMESTAMP;
    pv_device INTEGER := 27;
BEGIN
    target_date := DATE_TRUNC('day', 
        (NOW() AT TIME ZONE 'Asia/Jakarta') - (p_days_offset || ' days')::INTERVAL
    )::TIMESTAMP;
    
    RETURN QUERY
    WITH device_data AS (
        SELECT
            d.device_id,
            -- Device consumption
            COALESCE(SUM(d.total_consumption), 0) as device_consumption,
            COALESCE(SUM(d.total_cost), 0) as device_cost_raw,
            
            -- Device by shift
            COALESCE(SUM(d.total_consumption) FILTER (WHERE d.shift_period = 'SHIFT1'), 0) as shift1_consumption,
            COALESCE(SUM(d.total_consumption) FILTER (WHERE d.shift_period = 'SHIFT2'), 0) as shift2_consumption,
            COALESCE(SUM(d.total_consumption) FILTER (WHERE d.shift_period = 'SHIFT3'), 0) as shift3_consumption,
            
            COALESCE(SUM(d.total_cost) FILTER (WHERE d.shift_period = 'SHIFT1'), 0) as shift1_cost_raw,
            COALESCE(SUM(d.total_cost) FILTER (WHERE d.shift_period = 'SHIFT2'), 0) as shift2_cost_raw,
            COALESCE(SUM(d.total_cost) FILTER (WHERE d.shift_period = 'SHIFT3'), 0) as shift3_cost_raw
            
        FROM daily_energy_cost_summary d
        WHERE d.tenant_id = 3
          AND d.device_id = ANY(p_device_ids)
          AND d.quantity_id = p_quantity_id
          AND d.daily_bucket = target_date
          AND d.grouping_type = 'SHIFT_RATE'
        GROUP BY d.device_id
    ),
    pv_data AS (
        SELECT
            COALESCE(SUM(total_consumption) FILTER (WHERE rate_code = 'PV'), 0) as pv_production,
            COALESCE(SUM(total_cost) FILTER (WHERE rate_code = 'PV'), 0) as pv_cost,
            
            -- PV by shift
            COALESCE(SUM(total_consumption) FILTER (WHERE shift_period = 'SHIFT1'), 0) as shift1_pv,
            COALESCE(SUM(total_consumption) FILTER (WHERE shift_period = 'SHIFT2'), 0) as shift2_pv,
            COALESCE(SUM(total_consumption) FILTER (WHERE shift_period = 'SHIFT3'), 0) as shift3_pv,
            
            COALESCE(SUM(total_cost) FILTER (WHERE shift_period = 'SHIFT1'), 0) as shift1_pv_cost,
            COALESCE(SUM(total_cost) FILTER (WHERE shift_period = 'SHIFT2'), 0) as shift2_pv_cost,
            COALESCE(SUM(total_cost) FILTER (WHERE shift_period = 'SHIFT3'), 0) as shift3_pv_cost
            
        FROM daily_energy_cost_summary
        WHERE tenant_id = 3
          AND device_id = pv_device
          AND quantity_id = p_quantity_id
          AND daily_bucket = target_date
          AND grouping_type = 'SHIFT_RATE'
    ),
    total_grid AS (
        SELECT COALESCE(SUM(device_consumption), 0) as total_consumption
        FROM device_data
    )
    SELECT
        dd.device_id,
        dd.device_consumption,
        dd.device_cost_raw,
        
        -- Proportional cost adjustment per device
        CASE 
            WHEN dd.device_consumption > 0 AND tg.total_consumption > 0 THEN
                -- Device's share of total PV proportion
                dd.device_cost_raw - 
                ((dd.device_consumption / tg.total_consumption) * 
                 (pv.pv_production / NULLIF(tg.total_consumption, 0)) * dd.device_cost_raw) +
                ((dd.device_consumption / tg.total_consumption) * pv.pv_cost)
            ELSE dd.device_cost_raw
        END as device_cost_adjusted,
        
        -- PV proportion for this device
        CASE 
            WHEN tg.total_consumption > 0 THEN
                (dd.device_consumption / tg.total_consumption) * 
                (pv.pv_production / NULLIF(tg.total_consumption, 0)) * 100
            ELSE 0
        END as pv_proportion_percent,
        
        -- Cost savings from PV
        CASE 
            WHEN dd.device_consumption > 0 AND tg.total_consumption > 0 THEN
                ((dd.device_consumption / tg.total_consumption) * 
                 (pv.pv_production / NULLIF(tg.total_consumption, 0)) * dd.device_cost_raw)
            ELSE 0
        END as cost_savings,
        
        -- Shift breakdowns
        dd.shift1_consumption,
        CASE 
            WHEN dd.shift1_consumption > 0 THEN
                dd.shift1_cost_raw - 
                (pv.shift1_pv / NULLIF(dd.shift1_consumption, 0)) * dd.shift1_cost_raw +
                (dd.shift1_consumption / NULLIF(dd.shift1_consumption + dd.shift2_consumption + dd.shift3_consumption, 0)) * pv.shift1_pv_cost
            ELSE dd.shift1_cost_raw
        END as shift1_cost_adjusted,
        
        dd.shift2_consumption,
        CASE 
            WHEN dd.shift2_consumption > 0 THEN
                dd.shift2_cost_raw - 
                (pv.shift2_pv / NULLIF(dd.shift2_consumption, 0)) * dd.shift2_cost_raw +
                (dd.shift2_consumption / NULLIF(dd.shift1_consumption + dd.shift2_consumption + dd.shift3_consumption, 0)) * pv.shift2_pv_cost
            ELSE dd.shift2_cost_raw
        END as shift2_cost_adjusted,
        
        dd.shift3_consumption,
        CASE 
            WHEN dd.shift3_consumption > 0 THEN
                dd.shift3_cost_raw - 
                (pv.shift3_pv / NULLIF(dd.shift3_consumption, 0)) * dd.shift3_cost_raw +
                (dd.shift3_consumption / NULLIF(dd.shift1_consumption + dd.shift2_consumption + dd.shift3_consumption, 0)) * pv.shift3_pv_cost
            ELSE dd.shift3_cost_raw
        END as shift3_cost_adjusted
        
    FROM device_data dd
    CROSS JOIN pv_data pv
    CROSS JOIN total_grid tg
    ORDER BY dd.device_id;
END;
$$;


--
-- Name: get_factory_a_weekly_summary(boolean, integer, integer); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.get_factory_a_weekly_summary(p_is_cost boolean DEFAULT false, p_weeks_offset integer DEFAULT 0, p_quantity_id integer DEFAULT 124) RETURNS TABLE(main_value text, main_value_unit text, title text, subtitle text, stat1_label text, stat1_value text, stat1_unit text, stat2_label text, stat2_value text, stat2_unit text, stat3_label text, stat3_value text, stat3_unit text, stat4_label text, stat4_value text, stat4_unit text, stat5_label text, stat5_value text, stat5_unit text, stat6_label text, stat6_value text, stat6_unit text, stat7_label text, stat7_value text, stat7_unit text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    week_start_date TIMESTAMP;
    week_end_date TIMESTAMP;
    grid_devices INTEGER[] := ARRAY[23, 24, 25, 26, 28];
    pv_device INTEGER := 27;
BEGIN
    -- Calculate week boundaries
    week_start_date := DATE_TRUNC('week', 
        (NOW() AT TIME ZONE 'Asia/Jakarta') - (p_weeks_offset || ' weeks')::INTERVAL
    )::TIMESTAMP;
    
    week_end_date := DATE_TRUNC('day', (NOW() AT TIME ZONE 'Asia/Jakarta'))::TIMESTAMP;
    
    RETURN QUERY
    WITH weekly_energy AS(
        SELECT
            -- Grid meters total (all shifts, all rates)
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(grid_devices)),0) as grid_meters_total,
            
            -- PV production (rate_code = 'PV' only)
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = pv_device AND rate_code = 'PV'),0) as pv_production,
            
            -- Shift totals (no deduction, total consumption)
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND shift_period = 'SHIFT1'),0) as shift1_total,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND shift_period = 'SHIFT2'),0) as shift2_total,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND shift_period = 'SHIFT3'),0) as shift3_total,
            
            -- PV by shift (for deduction calculation)
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = pv_device AND shift_period = 'SHIFT1'),0) as shift1_pv,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = pv_device AND shift_period = 'SHIFT2'),0) as shift2_pv,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = pv_device AND shift_period = 'SHIFT3'),0) as shift3_pv,
            
            -- Grid Peak: WBP rate
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND rate_code = 'WBP'),0) as grid_peak,
            
            -- Grid Off-peak: LWBP1 + LWBP2 rates
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND rate_code IN ('LWBP1', 'LWBP2')),0) as grid_offpeak
            
        FROM daily_energy_cost_summary
        WHERE tenant_id = 3
          AND device_id = ANY(grid_devices || pv_device)
          AND quantity_id = p_quantity_id
          AND daily_bucket >= week_start_date
          AND daily_bucket <= week_end_date
          AND grouping_type = 'SHIFT_RATE'
    )
    SELECT
        -- Main Value: Total facility consumption/cost
        prs.format_value(w.grid_meters_total, p_is_cost)::TEXT as main_value,
        prs.get_unit(w.grid_meters_total, p_is_cost)::TEXT as main_value_unit,
        
        'Week to Date'::TEXT as title,
        ('Week of ' || TO_CHAR(week_start_date, 'DD Month YYYY'))::TEXT as subtitle,
        
        -- Stat 1: Shift 1 (total consumption, no deduction)
        'Shift 1 (07-15)'::TEXT as stat1_label,
        prs.format_value(w.shift1_total, p_is_cost)::TEXT as stat1_value,
        prs.get_unit(w.shift1_total, p_is_cost)::TEXT as stat1_unit,
        
        -- Stat 2: Shift 2
        'Shift 2 (15-23)'::TEXT as stat2_label,
        prs.format_value(w.shift2_total, p_is_cost)::TEXT as stat2_value,
        prs.get_unit(w.shift2_total, p_is_cost)::TEXT as stat2_unit,
        
        -- Stat 3: Shift 3
        'Shift 3 (23-07)'::TEXT as stat3_label,
        prs.format_value(w.shift3_total, p_is_cost)::TEXT as stat3_value,
        prs.get_unit(w.shift3_total, p_is_cost)::TEXT as stat3_unit,
        
        -- Stat 4: Peak (no PV deduction)
        'Peak (18-22)'::TEXT as stat4_label,
        prs.format_value(w.grid_peak, p_is_cost)::TEXT as stat4_value,
        prs.get_unit(w.grid_peak, p_is_cost)::TEXT as stat4_unit,
        
        -- Stat 5: Off Peak (deducted by total PV)
        'Off Peak'::TEXT as stat5_label,
        prs.format_value(w.grid_offpeak - w.pv_production, p_is_cost)::TEXT as stat5_value,
        prs.get_unit(w.grid_offpeak - w.pv_production, p_is_cost)::TEXT as stat5_unit,

        -- Stat 6: PV Production
        'PV'::TEXT as stat6_label,
        prs.format_value(w.pv_production, p_is_cost)::TEXT as stat6_value,
        prs.get_unit(w.pv_production, p_is_cost)::TEXT as stat6_unit,

        -- Stat 7: Net Grid (Total - PV)
        'Grid (Net)'::TEXT as stat7_label,
        prs.format_value(w.grid_meters_total - w.pv_production, p_is_cost)::TEXT as stat7_value,
        prs.get_unit(w.grid_meters_total - w.pv_production, p_is_cost)::TEXT as stat7_unit

    FROM weekly_energy w;
END;
$$;


--
-- Name: get_factory_b_daily_summary(boolean, integer, integer); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.get_factory_b_daily_summary(p_is_cost boolean DEFAULT false, p_days_offset integer DEFAULT 0, p_quantity_id integer DEFAULT 124) RETURNS TABLE(main_value text, main_value_unit text, title text, subtitle text, stat1_label text, stat1_value text, stat1_unit text, stat2_label text, stat2_value text, stat2_unit text, stat3_label text, stat3_value text, stat3_unit text, stat4_label text, stat4_value text, stat4_unit text, stat5_label text, stat5_value text, stat5_unit text, stat6_label text, stat6_value text, stat6_unit text, stat7_label text, stat7_value text, stat7_unit text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    target_date TIMESTAMP;
    grid_devices INTEGER[] := ARRAY[12];
    pv_device INTEGER := 11;
BEGIN
    target_date := DATE_TRUNC('day', 
        (NOW() AT TIME ZONE 'Asia/Jakarta') - (p_days_offset || ' days')::INTERVAL
    )::TIMESTAMP;
    
    RETURN QUERY
    WITH daily_energy AS(
        SELECT
            daily_bucket,
            MAX(last_refreshed) AT TIME ZONE 'Asia/Jakarta' as last_entry,
            
            -- Consumption metrics
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = ANY(grid_devices)),0) as grid_meters_consumption,
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = pv_device AND rate_code = 'PV'),0) as pv_production,
            
            -- Shift consumption
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND shift_period = 'SHIFT1'),0) as shift1_consumption,
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND shift_period = 'SHIFT2'),0) as shift2_consumption,
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND shift_period = 'SHIFT3'),0) as shift3_consumption,
            
            -- PV by shift
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = pv_device AND shift_period = 'SHIFT1'),0) as shift1_pv,
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = pv_device AND shift_period = 'SHIFT2'),0) as shift2_pv,
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = pv_device AND shift_period = 'SHIFT3'),0) as shift3_pv,
            
            -- Rate-based consumption
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND rate_code = 'WBP'),0) as grid_peak_consumption,
            COALESCE(SUM(total_consumption) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND rate_code IN ('LWBP1', 'LWBP2')),0) as grid_offpeak_consumption,
            
            -- Cost metrics
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = ANY(grid_devices)),0) as grid_meters_cost_raw,
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = pv_device AND rate_code = 'PV'),0) as pv_cost,
            
            -- Shift costs
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND shift_period = 'SHIFT1'),0) as shift1_cost_raw,
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND shift_period = 'SHIFT2'),0) as shift2_cost_raw,
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND shift_period = 'SHIFT3'),0) as shift3_cost_raw,
            
            -- PV cost by shift
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = pv_device AND shift_period = 'SHIFT1'),0) as shift1_pv_cost,
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = pv_device AND shift_period = 'SHIFT2'),0) as shift2_pv_cost,
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = pv_device AND shift_period = 'SHIFT3'),0) as shift3_pv_cost,
            
            -- Rate-based costs
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND rate_code = 'WBP'),0) as grid_peak_cost,
            COALESCE(SUM(total_cost) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND rate_code IN ('LWBP1', 'LWBP2')),0) as grid_offpeak_cost_raw
            
        FROM daily_energy_cost_summary
        WHERE tenant_id = 3
          AND device_id = ANY(grid_devices || pv_device)
          AND quantity_id = p_quantity_id
          AND daily_bucket = target_date
          AND grouping_type = 'SHIFT_RATE'
        GROUP BY daily_bucket
    ),
    calculated_values AS (
        SELECT
            daily_bucket,
            last_entry,
            
            -- Consumption values
            grid_meters_consumption as total_consumption,
            shift1_consumption,
            shift2_consumption,
            shift3_consumption,
            grid_peak_consumption,
            (grid_offpeak_consumption - pv_production) as grid_offpeak_net,
            pv_production,
            (grid_meters_consumption - pv_production) as grid_net_consumption,
            
            -- Cost values with proportional allocation
            grid_meters_cost_raw as total_cost_raw,
            
            -- Shift costs adjusted
            CASE WHEN shift1_consumption > 0 
                 THEN shift1_cost_raw - (shift1_pv / NULLIF(shift1_consumption, 0)) * shift1_cost_raw + shift1_pv_cost
                 ELSE shift1_cost_raw 
            END as shift1_cost_adjusted,
            
            CASE WHEN shift2_consumption > 0 
                 THEN shift2_cost_raw - (shift2_pv / NULLIF(shift2_consumption, 0)) * shift2_cost_raw + shift2_pv_cost
                 ELSE shift2_cost_raw 
            END as shift2_cost_adjusted,
            
            CASE WHEN shift3_consumption > 0 
                 THEN shift3_cost_raw - (shift3_pv / NULLIF(shift3_consumption, 0)) * shift3_cost_raw + shift3_pv_cost
                 ELSE shift3_cost_raw 
            END as shift3_cost_adjusted,
            
            -- Peak cost (no adjustment, no PV during peak)
            grid_peak_cost,
            
            -- Off-peak cost adjusted
            CASE WHEN grid_offpeak_consumption > 0
                 THEN grid_offpeak_cost_raw - (pv_production / NULLIF(grid_offpeak_consumption, 0)) * grid_offpeak_cost_raw + pv_cost
                 ELSE grid_offpeak_cost_raw
            END as grid_offpeak_cost_adjusted,
            
            -- PV cost
            pv_cost,
            
            -- Net grid cost
            CASE WHEN grid_meters_consumption > 0
                 THEN grid_meters_cost_raw - (pv_production / NULLIF(grid_meters_consumption, 0)) * grid_meters_cost_raw + pv_cost
                 ELSE grid_meters_cost_raw
            END as grid_net_cost_adjusted
            
        FROM daily_energy
    )
    SELECT
        -- Main Value
        CASE 
            WHEN p_is_cost THEN
                TO_CHAR(ROUND(c.total_cost_raw, 2), 'FM999,999,999,990.00')
            WHEN c.total_consumption >= 1000000 THEN 
                TO_CHAR(ROUND(c.total_consumption/1000000.0, 2), 'FM999999999.00')
            WHEN c.total_consumption >= 1000 THEN 
                TO_CHAR(ROUND(c.total_consumption/1000.0, 2), 'FM999999999.00')
            ELSE 
                TO_CHAR(ROUND(c.total_consumption, 2), 'FM999999999.00')
        END::TEXT,
        
        CASE 
            WHEN p_is_cost THEN 'Rp.'
            WHEN c.total_consumption >= 1000000 THEN 'GWh'
            WHEN c.total_consumption >= 1000 THEN 'MWh'
            ELSE 'kWh'
        END::TEXT,
        
        TO_CHAR(c.daily_bucket, 'DD Month YYYY')::TEXT as title,
		CASE 
			WHEN p_days_offset > 0 THEN '24 hours'
			ELSE CONCAT('As of ',TO_CHAR(c.last_entry, 'HH24:MI'))::TEXT
        END  AS subtitle,
		
        -- Stats
        'Shift 1 (07-15)'::TEXT,
        prs.format_value(CASE WHEN p_is_cost THEN c.shift1_cost_adjusted ELSE c.shift1_consumption END, p_is_cost)::TEXT,
        prs.get_unit(CASE WHEN p_is_cost THEN c.shift1_cost_adjusted ELSE c.shift1_consumption END, p_is_cost)::TEXT,
        
        'Shift 2 (15-23)'::TEXT,
        prs.format_value(CASE WHEN p_is_cost THEN c.shift2_cost_adjusted ELSE c.shift2_consumption END, p_is_cost)::TEXT,
        prs.get_unit(CASE WHEN p_is_cost THEN c.shift2_cost_adjusted ELSE c.shift2_consumption END, p_is_cost)::TEXT,
        
        'Shift 3 (23-07)'::TEXT,
        prs.format_value(CASE WHEN p_is_cost THEN c.shift3_cost_adjusted ELSE c.shift3_consumption END, p_is_cost)::TEXT,
        prs.get_unit(CASE WHEN p_is_cost THEN c.shift3_cost_adjusted ELSE c.shift3_consumption END, p_is_cost)::TEXT,
        
        'Peak (18-22)'::TEXT,
        prs.format_value(CASE WHEN p_is_cost THEN c.grid_peak_cost ELSE c.grid_peak_consumption END, p_is_cost)::TEXT,
        prs.get_unit(CASE WHEN p_is_cost THEN c.grid_peak_cost ELSE c.grid_peak_consumption END, p_is_cost)::TEXT,
        
        'Off Peak'::TEXT,
        prs.format_value(CASE WHEN p_is_cost THEN c.grid_offpeak_cost_adjusted ELSE c.grid_offpeak_net END, p_is_cost)::TEXT,
        prs.get_unit(CASE WHEN p_is_cost THEN c.grid_offpeak_cost_adjusted ELSE c.grid_offpeak_net END, p_is_cost)::TEXT,

        'PV'::TEXT,
        prs.format_value(CASE WHEN p_is_cost THEN c.pv_cost ELSE c.pv_production END, p_is_cost)::TEXT,
        prs.get_unit(CASE WHEN p_is_cost THEN c.pv_cost ELSE c.pv_production END, p_is_cost)::TEXT,

        'Grid (Net)'::TEXT,
        prs.format_value(CASE WHEN p_is_cost THEN c.grid_net_cost_adjusted ELSE c.grid_net_consumption END, p_is_cost)::TEXT,
        prs.get_unit(CASE WHEN p_is_cost THEN c.grid_net_cost_adjusted ELSE c.grid_net_consumption END, p_is_cost)::TEXT

    FROM calculated_values c;
END;
$$;


--
-- Name: get_factory_b_weekly_summary(boolean, integer, integer); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.get_factory_b_weekly_summary(p_is_cost boolean DEFAULT false, p_weeks_offset integer DEFAULT 0, p_quantity_id integer DEFAULT 124) RETURNS TABLE(main_value text, main_value_unit text, title text, subtitle text, stat1_label text, stat1_value text, stat1_unit text, stat2_label text, stat2_value text, stat2_unit text, stat3_label text, stat3_value text, stat3_unit text, stat4_label text, stat4_value text, stat4_unit text, stat5_label text, stat5_value text, stat5_unit text, stat6_label text, stat6_value text, stat6_unit text, stat7_label text, stat7_value text, stat7_unit text)
    LANGUAGE plpgsql
    AS $$
DECLARE
    week_start_date TIMESTAMP;
    week_end_date TIMESTAMP;
    grid_devices INTEGER[] := ARRAY[12];
    pv_device INTEGER := 11;
BEGIN
    -- Calculate week boundaries
    week_start_date := DATE_TRUNC('week', 
        (NOW() AT TIME ZONE 'Asia/Jakarta') - (p_weeks_offset || ' weeks')::INTERVAL
    )::TIMESTAMP;
    
    week_end_date := DATE_TRUNC('day', (NOW() AT TIME ZONE 'Asia/Jakarta'))::TIMESTAMP;
    
    RETURN QUERY
    WITH weekly_energy AS(
        SELECT
            -- Grid meters total (all shifts, all rates)
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(grid_devices)),0) as grid_meters_total,
            
            -- PV production (rate_code = 'PV' only)
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = pv_device AND rate_code = 'PV'),0) as pv_production,
            
            -- Shift totals (no deduction, total consumption)
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND shift_period = 'SHIFT1'),0) as shift1_total,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND shift_period = 'SHIFT2'),0) as shift2_total,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND shift_period = 'SHIFT3'),0) as shift3_total,
            
            -- PV by shift (for deduction calculation)
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = pv_device AND shift_period = 'SHIFT1'),0) as shift1_pv,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = pv_device AND shift_period = 'SHIFT2'),0) as shift2_pv,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = pv_device AND shift_period = 'SHIFT3'),0) as shift3_pv,
            
            -- Grid Peak: WBP rate
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND rate_code = 'WBP'),0) as grid_peak,
            
            -- Grid Off-peak: LWBP1 + LWBP2 rates
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(grid_devices) AND rate_code IN ('LWBP1', 'LWBP2')),0) as grid_offpeak
            
        FROM daily_energy_cost_summary
        WHERE tenant_id = 3
          AND device_id = ANY(grid_devices || pv_device)
          AND quantity_id = p_quantity_id
          AND daily_bucket >= week_start_date
          AND daily_bucket <= week_end_date
          AND grouping_type = 'SHIFT_RATE'
    )
    SELECT
        -- Main Value: Total facility consumption/cost
        prs.format_value(w.grid_meters_total, p_is_cost)::TEXT as main_value,
        prs.get_unit(w.grid_meters_total, p_is_cost)::TEXT as main_value_unit,
        
        'Week to Date'::TEXT as title,
        ('Week of ' || TO_CHAR(week_start_date, 'DD Month YYYY'))::TEXT as subtitle,
        
        -- Stat 1: Shift 1 (total consumption, no deduction)
        'Shift 1 (07-15)'::TEXT as stat1_label,
        prs.format_value(w.shift1_total, p_is_cost)::TEXT as stat1_value,
        prs.get_unit(w.shift1_total, p_is_cost)::TEXT as stat1_unit,
        
        -- Stat 2: Shift 2
        'Shift 2 (15-23)'::TEXT as stat2_label,
        prs.format_value(w.shift2_total, p_is_cost)::TEXT as stat2_value,
        prs.get_unit(w.shift2_total, p_is_cost)::TEXT as stat2_unit,
        
        -- Stat 3: Shift 3
        'Shift 3 (23-07)'::TEXT as stat3_label,
        prs.format_value(w.shift3_total, p_is_cost)::TEXT as stat3_value,
        prs.get_unit(w.shift3_total, p_is_cost)::TEXT as stat3_unit,
        
        -- Stat 4: Peak (no PV deduction)
        'Peak (18-22)'::TEXT as stat4_label,
        prs.format_value(w.grid_peak, p_is_cost)::TEXT as stat4_value,
        prs.get_unit(w.grid_peak, p_is_cost)::TEXT as stat4_unit,
        
        -- Stat 5: Off Peak (deducted by total PV)
        'Off Peak'::TEXT as stat5_label,
        prs.format_value(w.grid_offpeak - w.pv_production, p_is_cost)::TEXT as stat5_value,
        prs.get_unit(w.grid_offpeak - w.pv_production, p_is_cost)::TEXT as stat5_unit,

        -- Stat 6: PV Production
        'PV'::TEXT as stat6_label,
        prs.format_value(w.pv_production, p_is_cost)::TEXT as stat6_value,
        prs.get_unit(w.pv_production, p_is_cost)::TEXT as stat6_unit,

        -- Stat 7: Net Grid (Total - PV)
        'Grid (Net)'::TEXT as stat7_label,
        prs.format_value(w.grid_meters_total - w.pv_production, p_is_cost)::TEXT as stat7_value,
        prs.get_unit(w.grid_meters_total - w.pv_production, p_is_cost)::TEXT as stat7_unit

    FROM weekly_energy w;
END;
$$;


--
-- Name: get_sankey_energy_flow(integer, timestamp without time zone, timestamp without time zone, boolean, integer, character varying, character varying[], character varying); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.get_sankey_energy_flow(p_tenant_id integer, p_start_time timestamp without time zone, p_end_time timestamp without time zone, p_is_cost boolean DEFAULT false, p_quantity_id integer DEFAULT 124, p_time_bucket character varying DEFAULT 'month'::character varying, p_shift_periods character varying[] DEFAULT ARRAY['SHIFT1'::text, 'SHIFT2'::text, 'SHIFT3'::text], p_timezone character varying DEFAULT 'Asia/Jakarta'::character varying) RETURNS TABLE(time_bucket timestamp without time zone, source text, target text, value numeric, level integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH base_aggregation AS (
        SELECT
            date_trunc(p_time_bucket, daily_bucket) as bucket,
            
            -- Level 1: Energy Sources
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (94) AND shift_period = ANY(p_shift_periods)), 0) as grid,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (11) AND shift_period = ANY(p_shift_periods)), 0) as pltsb,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (27) AND shift_period = ANY(p_shift_periods)), 0) as pltsa,
            
            -- Level 2: Total Purchased Energy
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (11,27,94) AND shift_period = ANY(p_shift_periods)), 0) as purchased,
            
            -- Level 2: Utilities Total
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (3,4,8,25,26,27,48,50,51,52,53,71,72,73,74,86,87,88,89,91,92,98,105) 
                        AND shift_period = ANY(p_shift_periods)), 0) as utilities,
            
            -- Level 2: Production (Balance)
            (
                COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                    FILTER (WHERE device_id IN (11,27,94) AND shift_period = ANY(p_shift_periods)), 0) - 
                COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                    FILTER (WHERE device_id IN (3,4,8,25,26,27,48,50,51,52,53,71,72,73,74,86,87,88,89,91,92,98,105) 
                            AND shift_period = ANY(p_shift_periods)), 0)
            ) as production,
            
            -- Level 3: Utilities Breakdown by Type
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (3,8) AND shift_period = ANY(p_shift_periods)), 0) as boiler,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (4,27,51,52,53,71,72,73,74,98,105) AND shift_period = ANY(p_shift_periods)), 0) as compressor,
            (
                COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                    FILTER (WHERE device_id IN (25,26,50,86,87,88,89) AND shift_period = ANY(p_shift_periods)), 0) - 
                COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                    FILTER (WHERE device_id IN (98) AND shift_period = ANY(p_shift_periods)), 0)
            ) as hvac,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (48) AND shift_period = ANY(p_shift_periods)), 0) as lighting,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (91,92) AND shift_period = ANY(p_shift_periods)), 0) as wtp,
            
            -- Level 4: Boiler Units
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (3) AND shift_period = ANY(p_shift_periods)), 0) as boiler_hto,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (8) AND shift_period = ANY(p_shift_periods)), 0) as boiler_miura,
            
            -- Level 4: Compressor Units
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (4) AND shift_period = ANY(p_shift_periods)), 0) as comp_100hp,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (27) AND shift_period = ANY(p_shift_periods)), 0) as comp_a5,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (51) AND shift_period = ANY(p_shift_periods)), 0) as comp_fusheng300hp,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (52) AND shift_period = ANY(p_shift_periods)), 0) as comp_cobelco300hp,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (53) AND shift_period = ANY(p_shift_periods)), 0) as comp_turbo300hp,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (74) AND shift_period = ANY(p_shift_periods)), 0) as comp_sp3,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (98) AND shift_period = ANY(p_shift_periods)), 0) as comp_scr2200,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (105) AND shift_period = ANY(p_shift_periods)), 0) as comp_aiki,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (71) AND shift_period = ANY(p_shift_periods)), 0) as comp_kaeser,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (72) AND shift_period = ANY(p_shift_periods)), 0) as comp_winder,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (73) AND shift_period = ANY(p_shift_periods)), 0) as comp_interlace,
            
            -- Level 4: HVAC Units
            (
                COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                    FILTER (WHERE device_id IN (26) AND shift_period = ANY(p_shift_periods)), 0) - 
                COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                    FILTER (WHERE device_id IN (98) AND shift_period = ANY(p_shift_periods)), 0)
            ) as hvac_a4,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (25) AND shift_period = ANY(p_shift_periods)), 0) as hvac_a3,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (50) AND shift_period = ANY(p_shift_periods)), 0) as hvac_ahu,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (86) AND shift_period = ANY(p_shift_periods)), 0) as hvac_chiller1,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (87) AND shift_period = ANY(p_shift_periods)), 0) as hvac_chiller2,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (88) AND shift_period = ANY(p_shift_periods)), 0) as ahu_line1,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (89) AND shift_period = ANY(p_shift_periods)), 0) as ahu_line2,
            
            -- Level 4: WTP Units
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (91) AND shift_period = ANY(p_shift_periods)), 0) as wtp1,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                FILTER (WHERE device_id IN (92) AND shift_period = ANY(p_shift_periods)), 0) as wtp2
        FROM
            daily_energy_cost_summary
        WHERE
            tenant_id = p_tenant_id
            AND device_id = ANY(ARRAY[94,11,27,3,4,8,25,26,27,48,50,51,52,53,71,72,73,74,86,87,88,89,91,92,98,105])
            AND quantity_id = p_quantity_id
            AND daily_bucket BETWEEN 
                date_trunc(p_time_bucket, p_start_time AT TIME ZONE p_timezone)
                AND p_end_time AT TIME ZONE p_timezone
        GROUP BY bucket
    ),
    sankey_links AS (
        SELECT bucket, link_source as source, link_target as target, link_value as value, link_level as level FROM (
            -- Level 1: Energy Sources to Purchased
            SELECT bucket, 'Grid' as link_source, 'Purchased Energy' as link_target, grid as link_value, 1 as link_level 
            FROM base_aggregation WHERE grid > 0
            UNION ALL
            SELECT bucket, 'PLTS A' as link_source, 'Purchased Energy' as link_target, pltsa as link_value, 1 as link_level 
            FROM base_aggregation WHERE pltsa > 0
            UNION ALL
            SELECT bucket, 'PLTS B' as link_source, 'Purchased Energy' as link_target, pltsb as link_value, 1 as link_level 
            FROM base_aggregation WHERE pltsb > 0
            
            -- Level 2: Purchased to Utilities and Production
            UNION ALL
            SELECT bucket, 'Purchased Energy' as link_source, 'Utilities' as link_target, utilities as link_value, 2 as link_level 
            FROM base_aggregation WHERE utilities > 0
            UNION ALL
            SELECT bucket, 'Purchased Energy' as link_source, 'Production' as link_target, production as link_value, 2 as link_level 
            FROM base_aggregation WHERE production > 0
            
            -- Level 3: Utilities to Types
            UNION ALL
            SELECT bucket, 'Utilities' as link_source, 'Boiler' as link_target, boiler as link_value, 3 as link_level 
            FROM base_aggregation WHERE boiler > 0
            UNION ALL
            SELECT bucket, 'Utilities' as link_source, 'Compressor' as link_target, compressor as link_value, 3 as link_level 
            FROM base_aggregation WHERE compressor > 0
            UNION ALL
            SELECT bucket, 'Utilities' as link_source, 'HVAC' as link_target, hvac as link_value, 3 as link_level 
            FROM base_aggregation WHERE hvac > 0
            UNION ALL
            SELECT bucket, 'Utilities' as link_source, 'Lighting' as link_target, lighting as link_value, 3 as link_level 
            FROM base_aggregation WHERE lighting > 0
            UNION ALL
            SELECT bucket, 'Utilities' as link_source, 'WTP' as link_target, wtp as link_value, 3 as link_level 
            FROM base_aggregation WHERE wtp > 0
            
            -- Level 4: Boiler Units
            UNION ALL
            SELECT bucket, 'Boiler' as link_source, 'Boiler HTO' as link_target, boiler_hto as link_value, 4 as link_level 
            FROM base_aggregation WHERE boiler_hto > 0
            UNION ALL
            SELECT bucket, 'Boiler' as link_source, 'Boiler Miura' as link_target, boiler_miura as link_value, 4 as link_level 
            FROM base_aggregation WHERE boiler_miura > 0
            
            -- Level 4: Compressor Units
            UNION ALL
            SELECT bucket, 'Compressor' as link_source, 'Comp 100HP' as link_target, comp_100hp as link_value, 4 as link_level 
            FROM base_aggregation WHERE comp_100hp > 0
            UNION ALL
            SELECT bucket, 'Compressor' as link_source, 'Comp A5' as link_target, comp_a5 as link_value, 4 as link_level 
            FROM base_aggregation WHERE comp_a5 > 0
            UNION ALL
            SELECT bucket, 'Compressor' as link_source, 'Comp Fusheng 300HP' as link_target, comp_fusheng300hp as link_value, 4 as link_level 
            FROM base_aggregation WHERE comp_fusheng300hp > 0
            UNION ALL
            SELECT bucket, 'Compressor' as link_source, 'Comp Cobelco 300HP' as link_target, comp_cobelco300hp as link_value, 4 as link_level 
            FROM base_aggregation WHERE comp_cobelco300hp > 0
            UNION ALL
            SELECT bucket, 'Compressor' as link_source, 'Comp Turbo 300HP' as link_target, comp_turbo300hp as link_value, 4 as link_level 
            FROM base_aggregation WHERE comp_turbo300hp > 0
            UNION ALL
            SELECT bucket, 'Compressor' as link_source, 'Comp SP3' as link_target, comp_sp3 as link_value, 4 as link_level 
            FROM base_aggregation WHERE comp_sp3 > 0
            UNION ALL
            SELECT bucket, 'Compressor' as link_source, 'Comp SCR2200' as link_target, comp_scr2200 as link_value, 4 as link_level 
            FROM base_aggregation WHERE comp_scr2200 > 0
            UNION ALL
            SELECT bucket, 'Compressor' as link_source, 'Comp Aiki' as link_target, comp_aiki as link_value, 4 as link_level 
            FROM base_aggregation WHERE comp_aiki > 0
            UNION ALL
            SELECT bucket, 'Compressor' as link_source, 'Comp Kaeser' as link_target, comp_kaeser as link_value, 4 as link_level 
            FROM base_aggregation WHERE comp_kaeser > 0
            UNION ALL
            SELECT bucket, 'Compressor' as link_source, 'Comp Winder' as link_target, comp_winder as link_value, 4 as link_level 
            FROM base_aggregation WHERE comp_winder > 0
            UNION ALL
            SELECT bucket, 'Compressor' as link_source, 'Comp Interlace' as link_target, comp_interlace as link_value, 4 as link_level 
            FROM base_aggregation WHERE comp_interlace > 0
            
            -- Level 4: HVAC Units
            UNION ALL
            SELECT bucket, 'HVAC' as link_source, 'HVAC A4' as link_target, hvac_a4 as link_value, 4 as link_level 
            FROM base_aggregation WHERE hvac_a4 > 0
            UNION ALL
            SELECT bucket, 'HVAC' as link_source, 'HVAC A3' as link_target, hvac_a3 as link_value, 4 as link_level 
            FROM base_aggregation WHERE hvac_a3 > 0
            UNION ALL
            SELECT bucket, 'HVAC' as link_source, 'HVAC AHU' as link_target, hvac_ahu as link_value, 4 as link_level 
            FROM base_aggregation WHERE hvac_ahu > 0
            UNION ALL
            SELECT bucket, 'HVAC' as link_source, 'HVAC Chiller 1' as link_target, hvac_chiller1 as link_value, 4 as link_level 
            FROM base_aggregation WHERE hvac_chiller1 > 0
            UNION ALL
            SELECT bucket, 'HVAC' as link_source, 'HVAC Chiller 2' as link_target, hvac_chiller2 as link_value, 4 as link_level 
            FROM base_aggregation WHERE hvac_chiller2 > 0
            UNION ALL
            SELECT bucket, 'HVAC' as link_source, 'AHU Line 1' as link_target, ahu_line1 as link_value, 4 as link_level 
            FROM base_aggregation WHERE ahu_line1 > 0
            UNION ALL
            SELECT bucket, 'HVAC' as link_source, 'AHU Line 2' as link_target, ahu_line2 as link_value, 4 as link_level 
            FROM base_aggregation WHERE ahu_line2 > 0
            
            -- Level 4: WTP Units
            UNION ALL
            SELECT bucket, 'WTP' as link_source, 'WTP 1' as link_target, wtp1 as link_value, 4 as link_level 
            FROM base_aggregation WHERE wtp1 > 0
            UNION ALL
            SELECT bucket, 'WTP' as link_source, 'WTP 2' as link_target, wtp2 as link_value, 4 as link_level 
            FROM base_aggregation WHERE wtp2 > 0
        ) all_links
        WHERE link_value > 0
    )
    SELECT 
        sl.bucket as time_bucket,
        sl.source,
        sl.target,
        sl.value,
        sl.level
    FROM sankey_links sl
    ORDER BY sl.bucket, sl.level, sl.source, sl.target;
END;
$$;


--
-- Name: get_sankey_time_series(integer, timestamp without time zone, timestamp without time zone, character varying, boolean, character varying); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.get_sankey_time_series(p_tenant_id integer, p_start_time timestamp without time zone, p_end_time timestamp without time zone, p_time_bucket character varying DEFAULT 'week'::character varying, p_is_cost boolean DEFAULT false, p_timezone character varying DEFAULT 'Asia/Jakarta'::character varying) RETURNS TABLE(time_bucket timestamp without time zone, total_purchased numeric, total_shift1 numeric, total_shift2 numeric, total_shift3 numeric, total_utilities numeric, total_production numeric)
    LANGUAGE plpgsql
    AS $$
DECLARE
	start_period TIMESTAMPTZ;
	end_period TIMESTAMPTZ;
BEGIN
	start_period := p_start_time AT TIME ZONE p_timezone;
	end_period := p_end_time AT TIME ZONE p_timezone;
	
	RETURN QUERY
	SELECT
		date_trunc(p_time_bucket, daily_bucket) as time_bucket,
		COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) FILTER (WHERE device_id IN (11,27,94) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_purchased,
		COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) FILTER (WHERE device_id IN (11,27,94) AND shift_period IN ('SHIFT1')),0) as total_shift1,
		COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) FILTER (WHERE device_id IN (11,27,94) AND shift_period IN ('SHIFT2')),0) as total_shift2,
		COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) FILTER (WHERE device_id IN (11,27,94) AND shift_period IN ('SHIFT3')),0) as total_shift3,
		COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) FILTER (WHERE device_id IN (3,4,8,25,26,27,48,50,51,52,53,71,72,73,74,86,87,88,89,91,92,98,105) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_utilities,
		(
			COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) FILTER (WHERE device_id IN (11,27,94) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) - 
			COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) FILTER (WHERE device_id IN (3,4,8,25,26,27,48,50,51,52,53,71,72,73,74,86,87,88,89,91,92,98,105) AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0)
		) as total_production
	FROM
		daily_energy_cost_summary
	WHERE
		tenant_id = p_tenant_id
		AND device_id = ANY(ARRAY[94,11,27,3,4,8,25,26,27,48,50,51,52,53,71,72,73,74,86,87,88,89,91,92,98,105])
		AND quantity_id = 124
		AND daily_bucket
			BETWEEN start_period AND end_period
	GROUP BY time_bucket
	ORDER BY time_bucket;
END;
$$;


--
-- Name: get_unit(numeric, boolean); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.get_unit(p_value numeric, p_is_cost boolean) RETURNS text
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF p_is_cost THEN
        RETURN 'Rp.';
    ELSE
        RETURN CASE 
            WHEN p_value >= 1000000 THEN 'GWh'
            WHEN p_value >= 1000 THEN 'MWh'
            ELSE 'kWh'
        END;
    END IF;
END;
$$;


--
-- Name: get_weekly_summary(boolean, integer[], integer[], integer, integer); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.get_weekly_summary(p_is_cost boolean DEFAULT false, p_grid_devices integer[] DEFAULT ARRAY[94], p_pv_devices integer[] DEFAULT ARRAY[11, 27], p_weeks_offset integer DEFAULT 0, p_quantity_id integer DEFAULT 124) RETURNS TABLE(main_value text, main_value_unit text, title text, subtitle text, stat1_label text, stat1_value text, stat1_unit text, stat2_label text, stat2_value text, stat2_unit text, stat3_label text, stat3_value text, stat3_unit text, stat4_label text, stat4_value text, stat4_unit text, stat5_label text, stat5_value text, stat5_unit text, stat6_label text, stat6_value text, stat6_unit text, stat7_label text, stat7_value text, stat7_unit text, total_energy numeric, shift1_energy numeric, shift2_energy numeric, shift3_energy numeric, grid_peak_energy numeric, grid_offpeak_energy numeric, pv_day_energy numeric, grid_energy numeric)
    LANGUAGE plpgsql
    AS $$
DECLARE
    week_start_date TIMESTAMP;
    week_end_date TIMESTAMP;
    all_devices INTEGER[];
BEGIN
    -- Calculate week boundaries
    week_start_date := DATE_TRUNC('week', 
        (NOW() AT TIME ZONE 'Asia/Jakarta') - (p_weeks_offset || ' weeks')::INTERVAL
    )::TIMESTAMP;
    
    week_end_date := DATE_TRUNC('day', (NOW() AT TIME ZONE 'Asia/Jakarta'))::TIMESTAMP;
    
    all_devices := COALESCE(p_grid_devices, ARRAY[]::INTEGER[]) || COALESCE(p_pv_devices, ARRAY[]::INTEGER[]);
    
    RETURN QUERY
    WITH weekly_energy AS(
        SELECT
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE grouping_type='SHIFT_RATE' AND shift_period IN ('SHIFT1','SHIFT2','SHIFT3')),0) as total_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE grouping_type='SHIFT_RATE' AND shift_period='SHIFT1'),0) as shift1_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE grouping_type='SHIFT_RATE' AND shift_period='SHIFT2'),0) as shift2_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE grouping_type='SHIFT_RATE' AND shift_period='SHIFT3'),0) as shift3_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(p_grid_devices) AND grouping_type='SHIFT_RATE' 
                             AND rate_code IN ('LWBP1', 'LWBP2')),0) as grid_offpeak_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(p_grid_devices) AND grouping_type='SHIFT_RATE' 
                             AND rate_code = 'WBP'),0) as grid_peak_energy,
            COALESCE(SUM(CASE WHEN p_is_cost THEN total_cost ELSE total_consumption END) 
                     FILTER (WHERE device_id = ANY(p_pv_devices) AND grouping_type='SHIFT_RATE' 
                             AND rate_code = 'PV'),0) as pv_day_energy
        FROM daily_energy_cost_summary
        WHERE tenant_id = 3
          AND device_id = ANY(all_devices)
          AND quantity_id = p_quantity_id
          AND daily_bucket >= week_start_date
          AND daily_bucket <= week_end_date
    )
    SELECT
        prs.format_value(w.total_energy, p_is_cost)::TEXT as main_value,
        prs.get_unit(w.total_energy, p_is_cost)::TEXT as main_value_unit,

        'Week to Date'::TEXT as title,
		('Week of ' || TO_CHAR(week_start_date, 'DD Month YYYY'))::TEXT as subtitle,

        'Shift 1 (07-15)'::TEXT as stat1_label,
        prs.format_value(w.shift1_energy, p_is_cost)::TEXT as stat1_value,
        prs.get_unit(w.shift1_energy, p_is_cost)::TEXT as stat1_unit,
        
        'Shift 2 (15-23)'::TEXT as stat2_label,
        prs.format_value(w.shift2_energy, p_is_cost)::TEXT as stat2_value,
        prs.get_unit(w.shift2_energy, p_is_cost)::TEXT as stat2_unit,
        
        'Shift 3 (23-07)'::TEXT as stat3_label,
        prs.format_value(w.shift3_energy, p_is_cost)::TEXT as stat3_value,
        prs.get_unit(w.shift3_energy, p_is_cost)::TEXT as stat3_unit,
        
        'Peak (18-22)'::TEXT as stat4_label,
        prs.format_value(w.grid_peak_energy, p_is_cost)::TEXT as stat4_value,
        prs.get_unit(w.grid_peak_energy, p_is_cost)::TEXT as stat4_unit,
        
        'Off Peak'::TEXT as stat5_label,
        prs.format_value(w.grid_offpeak_energy, p_is_cost)::TEXT as stat5_value,
        prs.get_unit(w.grid_offpeak_energy, p_is_cost)::TEXT as stat5_unit,

        'PV'::TEXT as stat6_label,
        prs.format_value(w.pv_day_energy, p_is_cost)::TEXT as stat6_value,
        prs.get_unit(w.pv_day_energy, p_is_cost)::TEXT as stat6_unit,

        'Grid'::TEXT as stat7_label,
        prs.format_value(w.grid_peak_energy + w.grid_offpeak_energy, p_is_cost)::TEXT as stat7_value,
        prs.get_unit(w.grid_peak_energy + w.grid_offpeak_energy, p_is_cost)::TEXT as stat7_unit,

		-- DEBUGGING VALUES, use to combine between devices arrays
		w.total_energy,
		w.shift1_energy,
		w.shift2_energy,
		w.shift3_energy,
		w.grid_peak_energy,
		w.grid_offpeak_energy,
		w.pv_day_energy,
		(w.grid_peak_energy + w.grid_offpeak_energy) as grid_energy

    FROM weekly_energy w;
END;
$$;


--
-- Name: get_yarn_daily_summary(boolean, integer); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.get_yarn_daily_summary(p_cost boolean DEFAULT false, p_offset integer DEFAULT 0) RETURNS TABLE(main_value text, main_value_unit text, title text, subtitle text, stat1_label text, stat1_value text, stat1_unit text, stat2_label text, stat2_value text, stat2_unit text, stat3_label text, stat3_value text, stat3_unit text, stat4_label text, stat4_value text, stat4_unit text, stat5_label text, stat5_value text, stat5_unit text, stat6_label text, stat6_value text, stat6_unit text, stat7_label text, stat7_value text, stat7_unit text)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH upstream AS (
        SELECT
            ds.title AS upstream_title,
            ds.subtitle AS upstream_subtitle,
            ds.total_energy AS upstream_total_energy,
            ds.shift1_energy AS upstream_shift1_energy,
            ds.shift2_energy AS upstream_shift2_energy,
            ds.shift3_energy AS upstream_shift3_energy,
            ds.grid_peak_energy AS upstream_grid_peak_energy,
            ds.grid_offpeak_energy AS upstream_grid_offpeak_energy,
            ds.pv_day_energy AS upstream_pv_day_energy,
            ds.grid_energy AS upstream_grid_energy
        FROM prs.get_daily_summary(p_cost, ARRAY[94], ARRAY[]::INTEGER[], p_offset) AS ds
    ),
    factory_ab AS (
        SELECT
            ds.total_energy AS ab_total_energy,
            ds.shift1_energy AS ab_shift1_energy,
            ds.shift2_energy AS ab_shift2_energy,
            ds.shift3_energy AS ab_shift3_energy,
            ds.grid_peak_energy AS ab_grid_peak_energy,
            ds.grid_offpeak_energy AS ab_grid_offpeak_energy,
            ds.pv_day_energy AS ab_pv_day_energy,
            ds.grid_energy AS ab_grid_energy
        FROM prs.get_daily_summary(p_cost, ARRAY[84], ARRAY[]::INTEGER[], p_offset) AS ds
    ),
    yarn AS (
        SELECT
            u.upstream_title AS title,
            u.upstream_subtitle AS subtitle,
            (u.upstream_total_energy - ab.ab_total_energy) AS total_energy,
            (u.upstream_shift1_energy - ab.ab_shift1_energy) AS shift1_energy,
            (u.upstream_shift2_energy - ab.ab_shift2_energy) AS shift2_energy,
            (u.upstream_shift3_energy - ab.ab_shift3_energy) AS shift3_energy,
            (u.upstream_grid_peak_energy - ab.ab_grid_peak_energy) AS grid_peak_energy,
            (u.upstream_grid_offpeak_energy - ab.ab_grid_offpeak_energy) AS grid_offpeak_energy,
            0::NUMERIC AS pv_day_energy,
            (u.upstream_grid_energy - ab.ab_grid_energy) AS grid_energy
        FROM upstream u
        CROSS JOIN factory_ab ab
    )
    SELECT
        -- Main Value
        CASE 
            WHEN p_cost THEN
                TO_CHAR(ROUND(d.total_energy::numeric, 2), 'FM999,999,999,990.00')
            WHEN d.total_energy >= 1000000 THEN 
                TO_CHAR(ROUND(d.total_energy/1000000.0, 2), 'FM999999999.00')
            WHEN d.total_energy >= 1000 THEN 
                TO_CHAR(ROUND(d.total_energy/1000.0, 2), 'FM999999999.00')
            ELSE 
                TO_CHAR(ROUND(d.total_energy::numeric, 2), 'FM999999999.00')
        END::TEXT AS main_value,
        
        CASE 
            WHEN p_cost THEN 'Rp.'
            WHEN d.total_energy >= 1000000 THEN 'GWh'
            WHEN d.total_energy >= 1000 THEN 'MWh'
            ELSE 'kWh'
        END::TEXT AS main_value_unit,
        
        d.title,
        d.subtitle,
        
        -- Stat 1: Shift 1 (07:00 - 15:00)
        'Shift 1 (07-15)'::TEXT AS stat1_label,
        prs.format_value(d.shift1_energy, p_cost)::TEXT AS stat1_value,
        prs.get_unit(d.shift1_energy, p_cost)::TEXT AS stat1_unit,
        
        -- Stat 2: Shift 2 (15:00 - 23:00)
        'Shift 2 (15-23)'::TEXT AS stat2_label,
        prs.format_value(d.shift2_energy, p_cost)::TEXT AS stat2_value,
        prs.get_unit(d.shift2_energy, p_cost)::TEXT AS stat2_unit,
        
        -- Stat 3: Shift 3 (23:00 yesterday - 07:00 today)
        'Shift 3 (23-07)'::TEXT AS stat3_label,
        prs.format_value(d.shift3_energy, p_cost)::TEXT AS stat3_value,
        prs.get_unit(d.shift3_energy, p_cost)::TEXT AS stat3_unit,
        
        -- Stat 4: Peak (18:00 - 22:00)
        'Peak (18-22)'::TEXT AS stat4_label,
        prs.format_value(d.grid_peak_energy, p_cost)::TEXT AS stat4_value,
        prs.get_unit(d.grid_peak_energy, p_cost)::TEXT AS stat4_unit,
        
        -- Stat 5: Off Peak
        'Off Peak'::TEXT AS stat5_label,
        prs.format_value(d.grid_offpeak_energy, p_cost)::TEXT AS stat5_value,
        prs.get_unit(d.grid_offpeak_energy, p_cost)::TEXT AS stat5_unit,
        
        -- Stat 6: PV
        'PV'::TEXT AS stat6_label,
        prs.format_value(d.pv_day_energy, p_cost)::TEXT AS stat6_value,
        prs.get_unit(d.pv_day_energy, p_cost)::TEXT AS stat6_unit,
        
        -- Stat 7: Grid
        'Grid'::TEXT AS stat7_label,
        prs.format_value(d.grid_peak_energy + d.grid_offpeak_energy, p_cost)::TEXT AS stat7_value,
        prs.get_unit(d.grid_peak_energy + d.grid_offpeak_energy, p_cost)::TEXT AS stat7_unit
    FROM yarn d;
END $$;


--
-- Name: get_yarn_weekly_summary(boolean, integer); Type: FUNCTION; Schema: prs; Owner: -
--

CREATE FUNCTION prs.get_yarn_weekly_summary(p_cost boolean DEFAULT false, p_offset integer DEFAULT 0) RETURNS TABLE(main_value text, main_value_unit text, title text, subtitle text, stat1_label text, stat1_value text, stat1_unit text, stat2_label text, stat2_value text, stat2_unit text, stat3_label text, stat3_value text, stat3_unit text, stat4_label text, stat4_value text, stat4_unit text, stat5_label text, stat5_value text, stat5_unit text, stat6_label text, stat6_value text, stat6_unit text, stat7_label text, stat7_value text, stat7_unit text)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH upstream AS (
        SELECT
            ds.title AS upstream_title,
            ds.subtitle AS upstream_subtitle,
            ds.total_energy AS upstream_total_energy,
            ds.shift1_energy AS upstream_shift1_energy,
            ds.shift2_energy AS upstream_shift2_energy,
            ds.shift3_energy AS upstream_shift3_energy,
            ds.grid_peak_energy AS upstream_grid_peak_energy,
            ds.grid_offpeak_energy AS upstream_grid_offpeak_energy,
            ds.pv_day_energy AS upstream_pv_day_energy,
            ds.grid_energy AS upstream_grid_energy
        FROM prs.get_weekly_summary(p_cost, ARRAY[94], ARRAY[]::INTEGER[], p_offset) AS ds
    ),
    factory_ab AS (
        SELECT
            ds.total_energy AS ab_total_energy,
            ds.shift1_energy AS ab_shift1_energy,
            ds.shift2_energy AS ab_shift2_energy,
            ds.shift3_energy AS ab_shift3_energy,
            ds.grid_peak_energy AS ab_grid_peak_energy,
            ds.grid_offpeak_energy AS ab_grid_offpeak_energy,
            ds.pv_day_energy AS ab_pv_day_energy,
            ds.grid_energy AS ab_grid_energy
        FROM prs.get_weekly_summary(p_cost, ARRAY[84], ARRAY[]::INTEGER[], p_offset) AS ds
    ),
    yarn AS (
        SELECT
            u.upstream_title AS title,
            u.upstream_subtitle AS subtitle,
            (u.upstream_total_energy - ab.ab_total_energy) AS total_energy,
            (u.upstream_shift1_energy - ab.ab_shift1_energy) AS shift1_energy,
            (u.upstream_shift2_energy - ab.ab_shift2_energy) AS shift2_energy,
            (u.upstream_shift3_energy - ab.ab_shift3_energy) AS shift3_energy,
            (u.upstream_grid_peak_energy - ab.ab_grid_peak_energy) AS grid_peak_energy,
            (u.upstream_grid_offpeak_energy - ab.ab_grid_offpeak_energy) AS grid_offpeak_energy,
            0::NUMERIC AS pv_day_energy,
            (u.upstream_grid_energy - ab.ab_grid_energy) AS grid_energy
        FROM upstream u
        CROSS JOIN factory_ab ab
    )
    SELECT
        -- Main Value
        CASE 
            WHEN p_cost THEN
                TO_CHAR(ROUND(d.total_energy::numeric, 2), 'FM999,999,999,990.00')
            WHEN d.total_energy >= 1000000 THEN 
                TO_CHAR(ROUND(d.total_energy/1000000.0, 2), 'FM999999999.00')
            WHEN d.total_energy >= 1000 THEN 
                TO_CHAR(ROUND(d.total_energy/1000.0, 2), 'FM999999999.00')
            ELSE 
                TO_CHAR(ROUND(d.total_energy::numeric, 2), 'FM999999999.00')
        END::TEXT AS main_value,
        
        CASE 
            WHEN p_cost THEN 'Rp.'
            WHEN d.total_energy >= 1000000 THEN 'GWh'
            WHEN d.total_energy >= 1000 THEN 'MWh'
            ELSE 'kWh'
        END::TEXT AS main_value_unit,
        
        d.title,
        d.subtitle,
        
        -- Stat 1: Shift 1 (07:00 - 15:00)
        'Shift 1 (07-15)'::TEXT AS stat1_label,
        prs.format_value(d.shift1_energy, p_cost)::TEXT AS stat1_value,
        prs.get_unit(d.shift1_energy, p_cost)::TEXT AS stat1_unit,
        
        -- Stat 2: Shift 2 (15:00 - 23:00)
        'Shift 2 (15-23)'::TEXT AS stat2_label,
        prs.format_value(d.shift2_energy, p_cost)::TEXT AS stat2_value,
        prs.get_unit(d.shift2_energy, p_cost)::TEXT AS stat2_unit,
        
        -- Stat 3: Shift 3 (23:00 yesterday - 07:00 today)
        'Shift 3 (23-07)'::TEXT AS stat3_label,
        prs.format_value(d.shift3_energy, p_cost)::TEXT AS stat3_value,
        prs.get_unit(d.shift3_energy, p_cost)::TEXT AS stat3_unit,
        
        -- Stat 4: Peak (18:00 - 22:00)
        'Peak (18-22)'::TEXT AS stat4_label,
        prs.format_value(d.grid_peak_energy, p_cost)::TEXT AS stat4_value,
        prs.get_unit(d.grid_peak_energy, p_cost)::TEXT AS stat4_unit,
        
        -- Stat 5: Off Peak
        'Off Peak'::TEXT AS stat5_label,
        prs.format_value(d.grid_offpeak_energy, p_cost)::TEXT AS stat5_value,
        prs.get_unit(d.grid_offpeak_energy, p_cost)::TEXT AS stat5_unit,
        
        -- Stat 6: PV
        'PV'::TEXT AS stat6_label,
        prs.format_value(d.pv_day_energy, p_cost)::TEXT AS stat6_value,
        prs.get_unit(d.pv_day_energy, p_cost)::TEXT AS stat6_unit,
        
        -- Stat 7: Grid
        'Grid'::TEXT AS stat7_label,
        prs.format_value(d.grid_peak_energy + d.grid_offpeak_energy, p_cost)::TEXT AS stat7_value,
        prs.get_unit(d.grid_peak_energy + d.grid_offpeak_energy, p_cost)::TEXT AS stat7_unit
    FROM yarn d;
END $$;


--
-- Name: store_monthly_baseline(integer, date, integer); Type: PROCEDURE; Schema: prs; Owner: -
--

CREATE PROCEDURE prs.store_monthly_baseline(IN p_tenant_id integer DEFAULT 3, IN p_calculation_date date DEFAULT CURRENT_DATE, IN p_lookback_weeks integer DEFAULT 8)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_version INTEGER;
    v_period_start DATE;
    v_period_end DATE;
    v_rows_inserted INTEGER;
BEGIN
    -- Calculate version
    v_version := EXTRACT(YEAR FROM p_calculation_date)::INTEGER * 100 + 
                 EXTRACT(MONTH FROM p_calculation_date)::INTEGER;
    
    v_period_end := p_calculation_date - INTERVAL '3 days';
    v_period_start := v_period_end - (p_lookback_weeks || ' weeks')::INTERVAL;
    
    RAISE NOTICE 'Starting baseline calculation for version: %, period: % to %', 
                 v_version, v_period_start, v_period_end;
    
    -- Insert calculated baseline data
    INSERT INTO prs.baseline_load_profiles (
        tenant_id,
        baseline_version,
        calculation_date,
        data_period_start,
        data_period_end,
        time_hhmm,
        shift_name,
        day_type,
        load_group,
        baseline_median,
        baseline_mean,
        baseline_p10,
        baseline_p90,
        baseline_std,
        baseline_min,
        baseline_max,
        sample_count,
        data_completeness
    )
    SELECT 
        p_tenant_id,
        baseline_version,
        p_calculation_date,
        v_period_start,
        v_period_end,
        time_hhmm,
        shift_name,
        day_type,
        load_group,
        baseline_median,
        baseline_mean,
        baseline_p10,
        baseline_p90,
        baseline_std,
        baseline_min,
        baseline_max,
        sample_count,
        data_completeness
    FROM prs.calculate_monthly_baseline(p_tenant_id, p_calculation_date, p_lookback_weeks)
    ON CONFLICT (tenant_id, baseline_version, time_hhmm, shift_name, day_type, load_group)
    DO UPDATE SET
        calculation_date = EXCLUDED.calculation_date,
        data_period_start = EXCLUDED.data_period_start,
        data_period_end = EXCLUDED.data_period_end,
        baseline_median = EXCLUDED.baseline_median,
        baseline_mean = EXCLUDED.baseline_mean,
        baseline_p10 = EXCLUDED.baseline_p10,
        baseline_p90 = EXCLUDED.baseline_p90,
        baseline_std = EXCLUDED.baseline_std,
        baseline_min = EXCLUDED.baseline_min,
        baseline_max = EXCLUDED.baseline_max,
        sample_count = EXCLUDED.sample_count,
        data_completeness = EXCLUDED.data_completeness,
        created_at = CURRENT_TIMESTAMP;
    
    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;
    
    RAISE NOTICE 'Baseline calculation complete. Rows inserted/updated: %', v_rows_inserted;
    
    COMMIT;
END;
$$;


--
-- Name: store_monthly_baseline_all_profiles(integer, date, integer); Type: PROCEDURE; Schema: prs; Owner: -
--

CREATE PROCEDURE prs.store_monthly_baseline_all_profiles(IN p_tenant_id integer DEFAULT 3, IN p_calculation_date date DEFAULT CURRENT_DATE, IN p_lookback_weeks integer DEFAULT 8)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_version INTEGER;
    v_period_start DATE;
    v_period_end DATE;
    v_power_rows INTEGER;
    v_energy_rows INTEGER;
BEGIN
    -- Calculate version
    v_version := EXTRACT(YEAR FROM p_calculation_date)::INTEGER * 100 + 
                 EXTRACT(MONTH FROM p_calculation_date)::INTEGER;
    
    v_period_end := p_calculation_date - INTERVAL '3 days';
    v_period_start := v_period_end - (p_lookback_weeks || ' weeks')::INTERVAL;
    
    RAISE NOTICE 'Starting baseline calculation for version: %, period: % to %', 
                 v_version, v_period_start, v_period_end;
    
    -- ========================================
    -- 1. Calculate and store POWER_15MIN baseline
    -- ========================================
    RAISE NOTICE 'Calculating POWER_15MIN baseline...';
    
    INSERT INTO prs.baseline_load_profiles (
        tenant_id,
        baseline_version,
        calculation_date,
        data_period_start,
        data_period_end,
        profile_type,
        time_hhmm,
        shift_name,
        day_type,
        load_group,
        baseline_median,
        baseline_mean,
        baseline_p10,
        baseline_p90,
        baseline_std,
        baseline_min,
        baseline_max,
        sample_count,
        data_completeness,
        measurement_unit
    )
    SELECT 
        p_tenant_id,
        baseline_version,
        p_calculation_date,
        v_period_start,
        v_period_end,
        'POWER_15MIN',
        time_hhmm,
        shift_name,
        day_type,
        load_group,
        baseline_median,
        baseline_mean,
        baseline_p10,
        baseline_p90,
        baseline_std,
        baseline_min,
        baseline_max,
        sample_count,
        data_completeness,
        'kW'
    FROM prs.calculate_monthly_baseline(p_tenant_id, p_calculation_date, p_lookback_weeks)
    ON CONFLICT (tenant_id, baseline_version, profile_type, shift_name, day_type, load_group, time_hhmm)
    DO UPDATE SET
        calculation_date = EXCLUDED.calculation_date,
        data_period_start = EXCLUDED.data_period_start,
        data_period_end = EXCLUDED.data_period_end,
        baseline_median = EXCLUDED.baseline_median,
        baseline_mean = EXCLUDED.baseline_mean,
        baseline_p10 = EXCLUDED.baseline_p10,
        baseline_p90 = EXCLUDED.baseline_p90,
        baseline_std = EXCLUDED.baseline_std,
        baseline_min = EXCLUDED.baseline_min,
        baseline_max = EXCLUDED.baseline_max,
        sample_count = EXCLUDED.sample_count,
        data_completeness = EXCLUDED.data_completeness,
        created_at = CURRENT_TIMESTAMP;
    
    GET DIAGNOSTICS v_power_rows = ROW_COUNT;
    RAISE NOTICE 'POWER_15MIN baseline complete. Rows: %', v_power_rows;
    
    -- ========================================
    -- 2. Calculate and store ENERGY_SHIFT baseline
    -- ========================================
    RAISE NOTICE 'Calculating ENERGY_SHIFT baseline...';
    
    INSERT INTO prs.baseline_load_profiles (
        tenant_id,
        baseline_version,
        calculation_date,
        data_period_start,
        data_period_end,
        profile_type,
        time_hhmm,
        shift_name,
        day_type,
        load_group,
        baseline_median,
        baseline_mean,
        baseline_p10,
        baseline_p90,
        baseline_std,
        baseline_min,
        baseline_max,
        sample_count,
        data_completeness,
        measurement_unit
    )
    SELECT 
        p_tenant_id,
        baseline_version,
        p_calculation_date,
        v_period_start,
        v_period_end,
        profile_type,
        NULL,  -- No time_hhmm for shift-level data
        shift_name,
        day_type,
        load_group,
        baseline_median,
        baseline_mean,
        baseline_p10,
        baseline_p90,
        baseline_std,
        baseline_min,
        baseline_max,
        sample_count,
        NULL,  -- No data_completeness for shift aggregates
        measurement_unit
    FROM prs.calculate_energy_baseline_shift(p_tenant_id, p_calculation_date, p_lookback_weeks)
    ON CONFLICT (tenant_id, baseline_version, profile_type, shift_name, day_type, load_group, time_hhmm)
    DO UPDATE SET
        calculation_date = EXCLUDED.calculation_date,
        data_period_start = EXCLUDED.data_period_start,
        data_period_end = EXCLUDED.data_period_end,
        baseline_median = EXCLUDED.baseline_median,
        baseline_mean = EXCLUDED.baseline_mean,
        baseline_p10 = EXCLUDED.baseline_p10,
        baseline_p90 = EXCLUDED.baseline_p90,
        baseline_std = EXCLUDED.baseline_std,
        baseline_min = EXCLUDED.baseline_min,
        baseline_max = EXCLUDED.baseline_max,
        sample_count = EXCLUDED.sample_count,
        created_at = CURRENT_TIMESTAMP;
    
    GET DIAGNOSTICS v_energy_rows = ROW_COUNT;
    RAISE NOTICE 'ENERGY_SHIFT baseline complete. Rows: %', v_energy_rows;
    
    -- ========================================
    -- 3. Log completion
    -- ========================================
    RAISE NOTICE 'All baselines calculated. Total rows: %', v_power_rows + v_energy_rows;
    COMMIT;
END;
$$;


--
-- Name: acknowledge_device_alert(integer, integer, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.acknowledge_device_alert(p_tenant_id integer, p_alert_id integer, p_acknowledged_by character varying) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    alert_device_id INTEGER;
    update_count INTEGER;
BEGIN
    -- Validate alert exists and belongs to tenant
    SELECT device_id INTO alert_device_id
    FROM device_alerts da
    JOIN devices d ON da.device_id = d.id
    WHERE da.id = p_alert_id 
      AND d.tenant_id = p_tenant_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Alert not found or access denied';
    END IF;
    
    -- Acknowledge the alert
    UPDATE device_alerts SET
        acknowledged = true,
        acknowledged_at = CURRENT_TIMESTAMP,
        acknowledged_by = p_acknowledged_by
    WHERE id = p_alert_id AND acknowledged = false;
    
    GET DIAGNOSTICS update_count = ROW_COUNT;
    
    -- Log the action
    INSERT INTO audit_logs (
        tenant_id, 
        action_type, 
        resource_type, 
        resource_id,
        action_description
    ) VALUES (
        p_tenant_id, 
        'ALERT_ACKNOWLEDGE', 
        'ALERT', 
        p_alert_id::TEXT,
        format('Acknowledged alert for device %s by %s', alert_device_id, p_acknowledged_by)
    );
    
    RETURN update_count > 0;
END;
$$;


--
-- Name: FUNCTION acknowledge_device_alert(p_tenant_id integer, p_alert_id integer, p_acknowledged_by character varying); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.acknowledge_device_alert(p_tenant_id integer, p_alert_id integer, p_acknowledged_by character varying) IS 'Acknowledge device alerts with audit trail';


--
-- Name: add_hotspot_coordinate(integer, character varying, integer, integer, integer, numeric, numeric, numeric, numeric, numeric, character varying, character varying, character varying, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.add_hotspot_coordinate(p_tenant_id integer, p_coordinate_type character varying, p_asset_id integer DEFAULT NULL::integer, p_device_id integer DEFAULT NULL::integer, p_file_id integer DEFAULT NULL::integer, p_x_coordinate numeric DEFAULT NULL::numeric, p_y_coordinate numeric DEFAULT NULL::numeric, p_z_coordinate numeric DEFAULT NULL::numeric, p_yaw numeric DEFAULT NULL::numeric, p_pitch numeric DEFAULT NULL::numeric, p_hotspot_label character varying DEFAULT NULL::character varying, p_hotspot_color character varying DEFAULT NULL::character varying, p_hotspot_type character varying DEFAULT 'EQUIPMENT'::character varying, p_level integer DEFAULT 0, p_navigation_target_id integer DEFAULT NULL::integer, p_chart_data_source_id integer DEFAULT NULL::integer) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    new_coordinate_id INTEGER;
BEGIN
    -- Validate that either asset_id or device_id is provided
    IF p_asset_id IS NULL AND p_device_id IS NULL THEN
        RAISE EXCEPTION 'Either asset_id or device_id must be provided';
    END IF;
    
    IF p_asset_id IS NOT NULL AND p_device_id IS NOT NULL THEN
        RAISE EXCEPTION 'Cannot specify both asset_id and device_id';
    END IF;
    
    -- Validate asset ownership if asset_id provided
    IF p_asset_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM assets 
            WHERE id = p_asset_id AND tenant_id = p_tenant_id AND is_active = true
        ) THEN
            RAISE EXCEPTION 'Asset not found or access denied';
        END IF;
    END IF;
    
    -- Validate device ownership if device_id provided
    IF p_device_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM devices 
            WHERE id = p_device_id AND tenant_id = p_tenant_id AND is_active = true
        ) THEN
            RAISE EXCEPTION 'Device not found or access denied';
        END IF;
    END IF;
    
    -- Validate file ownership if file_id provided
    IF p_file_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM file_storage 
            WHERE id = p_file_id AND tenant_id = p_tenant_id AND is_active = true
        ) THEN
            RAISE EXCEPTION 'File not found or access denied';
        END IF;
    END IF;
    
    -- Validate hotspot type
    IF p_hotspot_type NOT IN ('EQUIPMENT', 'SENSOR', 'NAVIGATION', 'CHART', 'INFO') THEN
        RAISE EXCEPTION 'Invalid hotspot type: %', p_hotspot_type;
    END IF;
    
    -- Validate navigation target if provided
    IF p_navigation_target_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM assets 
            WHERE id = p_navigation_target_id AND tenant_id = p_tenant_id AND is_active = true
        ) THEN
            RAISE EXCEPTION 'Navigation target asset not found or access denied';
        END IF;
    END IF;
    
    -- Validate chart data source if provided
    IF p_chart_data_source_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM devices 
            WHERE id = p_chart_data_source_id AND tenant_id = p_tenant_id AND is_active = true
        ) THEN
            RAISE EXCEPTION 'Chart data source device not found or access denied';
        END IF;
    END IF;
    
    -- Insert coordinate with new fields
    INSERT INTO hotspot_coordinates (
        asset_id,
        device_id,
        file_id,
        coordinate_type,
        x_coordinate,
        y_coordinate,
        z_coordinate,
        yaw,
        pitch,
        hotspot_label,
        hotspot_color,
        hotspot_type,
        level,
        navigation_target_id,
        chart_data_source_id,
        is_active
    ) VALUES (
        p_asset_id,
        p_device_id,
        p_file_id,
        p_coordinate_type,
        p_x_coordinate,
        p_y_coordinate,
        p_z_coordinate,
        p_yaw,
        p_pitch,
        p_hotspot_label,
        p_hotspot_color,
        p_hotspot_type,
        p_level,
        p_navigation_target_id,
        p_chart_data_source_id,
        true
    ) RETURNING id INTO new_coordinate_id;
    
    -- Log the action
    INSERT INTO audit_logs (
        tenant_id, 
        action_type, 
        resource_type, 
        resource_id,
        action_description
    ) VALUES (
        p_tenant_id, 
        'HOTSPOT_CREATE', 
        'HOTSPOT', 
        new_coordinate_id::TEXT,
        format('Added %s hotspot coordinate (Level: %s) for asset/device: %s/%s', 
               p_hotspot_type, p_level, p_asset_id, p_device_id)
    );
    
    RETURN new_coordinate_id;
END;
$$;


--
-- Name: add_new_asset(integer, character varying, character varying, integer, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.add_new_asset(p_tenant_id integer, p_asset_name character varying, p_asset_type character varying, p_parent_id integer DEFAULT NULL::integer, p_description text DEFAULT NULL::text, p_metadata jsonb DEFAULT NULL::jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    new_asset_id INTEGER;
    parent_depth INTEGER := 0;
BEGIN
    -- Validate tenant exists and is active
    IF NOT EXISTS (SELECT 1 FROM tenants WHERE id = p_tenant_id AND is_active = true) THEN
        RAISE EXCEPTION 'Invalid or inactive tenant: %', p_tenant_id;
    END IF;
    
    -- Validate parent asset if provided
    IF p_parent_id IS NOT NULL THEN
        SELECT level_depth INTO parent_depth
        FROM assets 
        WHERE id = p_parent_id AND tenant_id = p_tenant_id AND is_active = true;
        
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Parent asset not found or access denied';
        END IF;
        
        -- Check maximum hierarchy depth
        IF parent_depth >= 10 THEN
            RAISE EXCEPTION 'Maximum hierarchy depth (10) exceeded';
        END IF;
    END IF;
    
    -- Generate unique asset code
    INSERT INTO assets (
        tenant_id, 
        parent_id, 
        asset_code, 
        asset_name, 
        asset_type, 
        description, 
        metadata,
        is_active
    ) VALUES (
        p_tenant_id,
        p_parent_id,
        'AST_' || p_tenant_id || '_' || to_char(now(), 'YYYYMMDD') || '_' || nextval('assets_id_seq'),
        p_asset_name,
        p_asset_type,
        p_description,
        p_metadata,
        true
    ) RETURNING id INTO new_asset_id;
    
    -- Log the action
    INSERT INTO audit_logs (
        tenant_id, 
        action_type, 
        resource_type, 
        resource_id, 
        action_description
    ) VALUES (
        p_tenant_id, 
        'ASSET_CREATE', 
        'ASSET', 
        new_asset_id::TEXT,
        format('Created asset: %s (Type: %s, Parent: %s)', p_asset_name, p_asset_type, p_parent_id)
    );
    
    RETURN new_asset_id;
END;
$$;


--
-- Name: FUNCTION add_new_asset(p_tenant_id integer, p_asset_name character varying, p_asset_type character varying, p_parent_id integer, p_description text, p_metadata jsonb); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.add_new_asset(p_tenant_id integer, p_asset_name character varying, p_asset_type character varying, p_parent_id integer, p_description text, p_metadata jsonb) IS 'Create new asset with hierarchy validation and audit trail';


--
-- Name: add_new_device(integer, character varying, integer, character varying, character varying, character varying, character varying, character varying, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.add_new_device(p_tenant_id integer, p_device_name character varying, p_asset_id integer DEFAULT NULL::integer, p_device_type character varying DEFAULT NULL::character varying, p_display_name character varying DEFAULT NULL::character varying, p_alias character varying DEFAULT NULL::character varying, p_external_system character varying DEFAULT NULL::character varying, p_external_id character varying DEFAULT NULL::character varying, p_metadata jsonb DEFAULT NULL::jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    new_device_id INTEGER;
BEGIN
    -- Validate tenant
    IF NOT EXISTS (SELECT 1 FROM tenants WHERE id = p_tenant_id AND is_active = true) THEN
        RAISE EXCEPTION 'Invalid or inactive tenant: %', p_tenant_id;
    END IF;
    
    -- Validate asset ownership if provided
    IF p_asset_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM assets 
            WHERE id = p_asset_id AND tenant_id = p_tenant_id AND is_active = true
        ) THEN
            RAISE EXCEPTION 'Asset not found or access denied';
        END IF;
    END IF;
    
    -- Generate unique device code
    INSERT INTO devices (
        tenant_id,
        asset_id,
        device_code,
        device_name,
        device_type,
        display_name,
        alias,
        metadata,
        is_active
    ) VALUES (
        p_tenant_id,
        p_asset_id,
        'DEV_' || p_tenant_id || '_' || to_char(now(), 'YYYYMMDD') || '_' || nextval('devices_id_seq'),
        p_device_name,
        p_device_type,
        COALESCE(p_display_name, p_device_name),
        p_alias,
        p_metadata,
        true
    ) RETURNING id INTO new_device_id;
    
    -- Add external system mapping if provided
    IF p_external_system IS NOT NULL AND p_external_id IS NOT NULL THEN
        INSERT INTO device_mappings (
            device_id,
            external_system,
            external_id,
            external_name
        ) VALUES (
            new_device_id,
            p_external_system,
            p_external_id,
            p_device_name
        );
    END IF;
    
    -- Log the action
    INSERT INTO audit_logs (
        tenant_id, 
        action_type, 
        resource_type, 
        resource_id,
        action_description
    ) VALUES (
        p_tenant_id, 
        'DEVICE_CREATE', 
        'DEVICE', 
        new_device_id::TEXT,
        format('Created device: %s (Type: %s, Asset: %s)', p_device_name, p_device_type, p_asset_id)
    );
    
    RETURN new_device_id;
END;
$$;


--
-- Name: FUNCTION add_new_device(p_tenant_id integer, p_device_name character varying, p_asset_id integer, p_device_type character varying, p_display_name character varying, p_alias character varying, p_external_system character varying, p_external_id character varying, p_metadata jsonb); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.add_new_device(p_tenant_id integer, p_device_name character varying, p_asset_id integer, p_device_type character varying, p_display_name character varying, p_alias character varying, p_external_system character varying, p_external_id character varying, p_metadata jsonb) IS 'Create new device with external system mapping support';


--
-- Name: auth_update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.auth_update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;


--
-- Name: create_device_alert(integer, integer, character varying, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_device_alert(p_tenant_id integer, p_device_id integer, p_severity character varying, p_message text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    new_alert_id INTEGER;
BEGIN
    -- Validate device ownership
    IF NOT EXISTS (
        SELECT 1 FROM devices 
        WHERE id = p_device_id AND tenant_id = p_tenant_id AND is_active = true
    ) THEN
        RAISE EXCEPTION 'Device not found or access denied';
    END IF;
    
    -- Validate severity level
    IF p_severity NOT IN ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL') THEN
        RAISE EXCEPTION 'Invalid severity level: %', p_severity;
    END IF;
    
    -- Insert alert
    INSERT INTO device_alerts (
        device_id,
        tenant_id,
        severity,
        message,
        acknowledged
    ) VALUES (
        p_device_id,
        p_tenant_id,
        p_severity,
        p_message,
        false
    ) RETURNING id INTO new_alert_id;
    
    -- Log the action
    INSERT INTO audit_logs (
        tenant_id, 
        action_type, 
        resource_type, 
        resource_id,
        action_description
    ) VALUES (
        p_tenant_id, 
        'ALERT_CREATE', 
        'ALERT', 
        new_alert_id::TEXT,
        format('Created %s alert for device %s: %s', p_severity, p_device_id, p_message)
    );
    
    RETURN new_alert_id;
END;
$$;


--
-- Name: FUNCTION create_device_alert(p_tenant_id integer, p_device_id integer, p_severity character varying, p_message text); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.create_device_alert(p_tenant_id integer, p_device_id integer, p_severity character varying, p_message text) IS 'Create new device alerts with validation';


--
-- Name: detect_gaps_in_timerange(integer, integer[], timestamp without time zone, timestamp without time zone, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.detect_gaps_in_timerange(p_tenant_id integer, p_device_ids integer[], p_start_time timestamp without time zone, p_end_time timestamp without time zone, p_gap_threshold_hours numeric DEFAULT 2.0) RETURNS TABLE(tenant_id integer, device_id integer, quantity_id integer, gap_start timestamp without time zone, gap_end timestamp without time zone, gap_duration_hours numeric, suspected_accumulated_bucket timestamp without time zone, suspected_accumulated_value numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH time_gaps AS (
        SELECT 
            tc.tenant_id,
            tc.device_id,
            tc.quantity_id,
            tc.bucket,
            tc.interval_value,
            tc.cumulative_value,
            LAG(tc.bucket) OVER (PARTITION BY tc.tenant_id, tc.device_id, tc.quantity_id ORDER BY tc.bucket) as prev_bucket,
            
            -- Calculate actual gap duration
            EXTRACT(EPOCH FROM (tc.bucket - LAG(tc.bucket) OVER (PARTITION BY tc.tenant_id, tc.device_id, tc.quantity_id ORDER BY tc.bucket))) / 3600.0 as gap_hours
            
        FROM telemetry_intervals_cumulative tc
        WHERE tc.tenant_id = p_tenant_id
          AND (p_device_ids IS NULL OR tc.device_id = ANY(p_device_ids))
          AND tc.bucket BETWEEN p_start_time AND p_end_time
          AND tc.data_quality_flag = 'NORMAL'
        ORDER BY tc.tenant_id, tc.device_id, tc.quantity_id, tc.bucket
    ),
    problematic_gaps AS (
        SELECT 
            tg.tenant_id,
            tg.device_id,
            tg.quantity_id,
            tg.prev_bucket + INTERVAL '15 minutes' as gap_start,  -- Gap starts after previous reading (17:15)
            tg.bucket as gap_end,                                 -- Gap ends at accumulated reading (02:15) - INCLUDE IT
            tg.gap_hours,
            tg.bucket as suspected_bucket,                        -- The bucket with accumulated value (02:15)
            tg.interval_value as suspected_value                  -- The accumulated value (36,416)
        FROM time_gaps tg
        WHERE tg.gap_hours >= p_gap_threshold_hours
          AND tg.prev_bucket IS NOT NULL  -- Exclude first reading
          AND tg.interval_value > 0       -- Only positive accumulated values
    )
    SELECT 
        pg.tenant_id,
        pg.device_id,
        pg.quantity_id,
        pg.gap_start,
        pg.gap_end,
        pg.gap_hours,
        pg.suspected_bucket,
        pg.suspected_value
    FROM problematic_gaps pg
    ORDER BY pg.tenant_id, pg.device_id, pg.quantity_id, pg.gap_start;
END;
$$;


--
-- Name: get_15min_telemetry_for_user(integer, integer[], timestamp without time zone, timestamp without time zone, integer[], integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_15min_telemetry_for_user(p_user_id integer, p_device_ids integer[] DEFAULT NULL::integer[], p_start_time timestamp without time zone DEFAULT NULL::timestamp without time zone, p_end_time timestamp without time zone DEFAULT NULL::timestamp without time zone, p_quantity_ids integer[] DEFAULT NULL::integer[], p_limit integer DEFAULT 2000, p_tenant_id integer DEFAULT NULL::integer) RETURNS TABLE(bucket timestamp without time zone, tenant_id integer, device_id integer, quantity_id integer, aggregated_value numeric, sample_count bigint, source_system character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    accessible_tenant_ids INTEGER[];
    filtered_device_ids INTEGER[];
BEGIN
    -- 1. Validate user and get accessible tenants (same logic as above)
    IF NOT EXISTS (
        SELECT 1 FROM auth_users 
        WHERE id = p_user_id AND is_active = true
    ) THEN
        RAISE EXCEPTION 'Invalid or inactive user: %', p_user_id;
    END IF;
    
    SELECT ARRAY_AGG(DISTINCT ut.tenant_id) INTO accessible_tenant_ids
    FROM auth_user_tenants ut
    JOIN auth_products p ON ut.product_id = p.id
    WHERE ut.user_id = p_user_id 
    AND ut.is_active = true
    AND (ut.expires_at IS NULL OR ut.expires_at > CURRENT_TIMESTAMP)
    AND p.is_active = true
    AND (
        'read_telemetry' = ANY(ut.permissions) OR
        'api_read' = ANY(ut.permissions) OR
        'api_access' = ANY(ut.permissions)
    );
    
    IF accessible_tenant_ids IS NULL OR array_length(accessible_tenant_ids, 1) = 0 THEN
        RAISE EXCEPTION 'User % has no telemetry access to any tenants', p_user_id;
    END IF;
    
    -- Validate specific tenant if requested
    IF p_tenant_id IS NOT NULL THEN
        IF NOT (p_tenant_id = ANY(accessible_tenant_ids)) THEN
            RAISE EXCEPTION 'User % does not have access to tenant %', p_user_id, p_tenant_id;
        END IF;
        accessible_tenant_ids := ARRAY[p_tenant_id];
    END IF;
    
    -- Filter devices to accessible ones
    IF p_device_ids IS NOT NULL THEN
        SELECT ARRAY_AGG(d.id) INTO filtered_device_ids
        FROM devices d
        WHERE d.id = ANY(p_device_ids)
        AND d.tenant_id = ANY(accessible_tenant_ids)
        AND d.is_active = true;
        
        IF filtered_device_ids IS NULL OR array_length(filtered_device_ids, 1) = 0 THEN
            RAISE EXCEPTION 'No accessible devices found for user %', p_user_id;
        END IF;
    END IF;
    
    -- Return aggregated data
    RETURN QUERY
    SELECT 
        ta.bucket,
        d.tenant_id,
        ta.device_id,
        ta.quantity_id,
        ta.aggregated_value,
        ta.sample_count,
        ta.source_system
    FROM telemetry_15min_agg ta
    JOIN devices d ON ta.device_id = d.id
    WHERE d.tenant_id = ANY(accessible_tenant_ids)
      AND (filtered_device_ids IS NULL OR ta.device_id = ANY(filtered_device_ids))
      AND (p_start_time IS NULL OR ta.bucket >= p_start_time)
      AND (p_end_time IS NULL OR ta.bucket <= p_end_time)
      AND (p_quantity_ids IS NULL OR ta.quantity_id = ANY(p_quantity_ids))
      AND d.is_active = true
    ORDER BY ta.bucket DESC
    LIMIT p_limit;
    
END;
$$;


--
-- Name: FUNCTION get_15min_telemetry_for_user(p_user_id integer, p_device_ids integer[], p_start_time timestamp without time zone, p_end_time timestamp without time zone, p_quantity_ids integer[], p_limit integer, p_tenant_id integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.get_15min_telemetry_for_user(p_user_id integer, p_device_ids integer[], p_start_time timestamp without time zone, p_end_time timestamp without time zone, p_quantity_ids integer[], p_limit integer, p_tenant_id integer) IS 'Get aggregated telemetry data with user-based authentication';


--
-- Name: get_all_downstream_assets(integer, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_all_downstream_assets(source_asset_id integer, target_utility character varying DEFAULT NULL::character varying) RETURNS TABLE(asset_id integer, asset_name character varying, utility_type character varying, distance_levels integer, traversal_method character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    -- Get hierarchical descendants
    SELECT h.asset_id, h.asset_name, h.utility_type, h.distance_levels, 'HIERARCHY'::VARCHAR(20)
    FROM get_downstream_hierarchy(source_asset_id, target_utility) h
    
    UNION
    
    -- Get connection descendants
    SELECT c.asset_id, c.asset_name, c.utility_type, c.distance_levels, 'CONNECTION'::VARCHAR(20)
    FROM get_downstream_connections(source_asset_id, target_utility) c
    
    ORDER BY distance_levels, utility_type, asset_name;
END;
$$;


--
-- Name: get_bucketed_telemetry_for_user(integer, character varying, character varying, integer[], timestamp without time zone, timestamp without time zone, integer[], integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_bucketed_telemetry_for_user(p_user_id integer, p_bucket character varying, p_aggregation_method character varying, p_device_ids integer[] DEFAULT NULL::integer[], p_start_time timestamp without time zone DEFAULT NULL::timestamp without time zone, p_end_time timestamp without time zone DEFAULT NULL::timestamp without time zone, p_quantity_ids integer[] DEFAULT NULL::integer[], p_limit integer DEFAULT 10000, p_tenant_id integer DEFAULT NULL::integer) RETURNS TABLE("timestamp" timestamp without time zone, tenant_id integer, device_id integer, device_name character varying, quantity_id integer, quantity_code character varying, quantity_name character varying, unit character varying, display_value numeric, raw_value numeric, quality integer, sample_count bigint, source_system character varying, is_cumulative boolean, data_source character varying, bucket_size character varying, aggregation_method character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    v_user_exists boolean := false;
    v_tenant_access boolean := false;
    v_audit_id bigint;
    v_data_source_used varchar := 'telemetry_unified_15min';
BEGIN
    -- Security and authentication validation

    -- 1. Validate user exists
    SELECT EXISTS(SELECT 1 FROM auth_users WHERE id = p_user_id) INTO v_user_exists;
    IF NOT v_user_exists THEN
        RAISE EXCEPTION 'User not found or access denied' USING ERRCODE = 'P0001';
    END IF;

    -- 2. Validate tenant access - user must be assigned to tenant
    IF p_tenant_id IS NOT NULL THEN
        SELECT EXISTS(
            SELECT 1 FROM auth_user_tenants ut
            WHERE ut.user_id = p_user_id AND ut.tenant_id = p_tenant_id AND ut.is_active = true
        ) INTO v_tenant_access;

        IF NOT v_tenant_access THEN
            RAISE EXCEPTION 'Tenant access denied' USING ERRCODE = 'P0002';
        END IF;
    END IF;

    -- 3. Audit logging
    INSERT INTO audit_logs (
        user_id,
        action_type,
        resource_type,
        resource_id,
        action_description,
        created_at
    ) VALUES (
        p_user_id::varchar,
        'bucketed_telemetry_access',
        'telemetry_data',
        NULL,
        json_build_object(
            'bucket', p_bucket,
            'aggregation_method', p_aggregation_method,
            'device_ids', p_device_ids,
            'quantity_ids', p_quantity_ids,
            'start_time', p_start_time,
            'end_time', p_end_time,
            'limit', p_limit,
            'tenant_id', p_tenant_id
        )::text,
        NOW()
    ) RETURNING id INTO v_audit_id;

    -- 4. Route based on bucket size and data availability
    IF p_bucket IN ('hourly', 'daily', 'weekly', 'monthly') THEN
        -- Use telemetry_unified_15min view which has proper cumulative interval calculations
        RETURN QUERY
        SELECT
            date_trunc(
                CASE p_bucket 
                    WHEN 'hourly' THEN 'hour'
                    WHEN 'daily' THEN 'day'
                    WHEN 'weekly' THEN 'week'
                    WHEN 'monthly' THEN 'month'
                    ELSE p_bucket
                END, 
                tu15.bucket
            )::timestamp without time zone as timestamp,
            tu15.tenant_id,
            tu15.device_id,
            d.device_name::character varying,
            tu15.quantity_id,
            tu15.quantity_code::character varying,
            tu15.quantity_name::character varying,
            tu15.unit::character varying,
            -- Apply user aggregation method to display_value (intervals for cumulative, raw for instantaneous)
            CASE p_aggregation_method
                WHEN 'sum' THEN SUM(tu15.display_value)
                WHEN 'avg' THEN
                    CASE
                        WHEN SUM(tu15.sample_count) > 0 THEN
                            SUM(tu15.display_value * tu15.sample_count) / SUM(tu15.sample_count)
                        ELSE NULL
                    END
                WHEN 'min' THEN MIN(tu15.display_value)
                WHEN 'max' THEN MAX(tu15.display_value)
                WHEN 'latest' THEN (array_agg(tu15.display_value ORDER BY tu15.bucket DESC))[1]
            END as display_value,
            -- Apply user aggregation method to raw_value (cumulative values for cumulative, raw for instantaneous)
            CASE p_aggregation_method
                WHEN 'sum' THEN SUM(tu15.raw_value)
                WHEN 'avg' THEN
                    CASE
                        WHEN SUM(tu15.sample_count) > 0 THEN
                            SUM(tu15.raw_value * tu15.sample_count) / SUM(tu15.sample_count)
                        ELSE NULL
                    END
                WHEN 'min' THEN MIN(tu15.raw_value)
                WHEN 'max' THEN MAX(tu15.raw_value)
                WHEN 'latest' THEN (array_agg(tu15.raw_value ORDER BY tu15.bucket DESC))[1]
            END as raw_value,
            NULL::integer as quality, -- Quality not available in aggregated data
            SUM(tu15.sample_count)::bigint as sample_count,
            COALESCE(MIN(tu15.source_system), 'system'::character varying)::character varying as source_system,
            tu15.is_cumulative,
            v_data_source_used::character varying as data_source,
            p_bucket::character varying as bucket_size,
            p_aggregation_method::character varying as aggregation_method
        FROM telemetry_unified_15min tu15
        JOIN devices d ON tu15.device_id = d.id
        WHERE
            (p_tenant_id IS NULL OR tu15.tenant_id = p_tenant_id)
            AND (p_device_ids IS NULL OR tu15.device_id = ANY(p_device_ids))
            AND (p_quantity_ids IS NULL OR tu15.quantity_id = ANY(p_quantity_ids))
            AND (p_start_time IS NULL OR tu15.bucket >= p_start_time)
            AND (p_end_time IS NULL OR tu15.bucket <= p_end_time)
            -- Additional security: ensure devices belong to user's tenant
            AND (p_tenant_id IS NULL OR d.tenant_id = p_tenant_id)
        GROUP BY
            date_trunc(
                CASE p_bucket 
                    WHEN 'hourly' THEN 'hour'
                    WHEN 'daily' THEN 'day'
                    WHEN 'weekly' THEN 'week'
                    WHEN 'monthly' THEN 'month'
                    ELSE p_bucket
                END, 
                tu15.bucket
            ),
            tu15.tenant_id,
            tu15.device_id,
            d.device_name::character varying,
            tu15.quantity_id,
            tu15.quantity_code::character varying,
            tu15.quantity_name::character varying,
            tu15.unit::character varying,
            tu15.is_cumulative
        ORDER BY timestamp DESC
        LIMIT p_limit;

    ELSIF p_bucket = 'yearly' THEN
        -- Yearly bucketing using telemetry_unified_15min view with proper cumulative interval calculations
        RETURN QUERY
        SELECT
            date_trunc('year', tu15.bucket)::timestamp without time zone as timestamp,
            tu15.tenant_id,
            tu15.device_id,
            d.device_name::character varying,
            tu15.quantity_id,
            tu15.quantity_code::character varying,
            tu15.quantity_name::character varying,
            tu15.unit::character varying,
            -- Apply user aggregation method to display_value (intervals for cumulative, raw for instantaneous)
            CASE p_aggregation_method
                WHEN 'sum' THEN SUM(tu15.display_value)
                WHEN 'avg' THEN
                    CASE
                        WHEN SUM(tu15.sample_count) > 0 THEN
                            SUM(tu15.display_value * tu15.sample_count) / SUM(tu15.sample_count)
                        ELSE NULL
                    END
                WHEN 'min' THEN MIN(tu15.display_value)
                WHEN 'max' THEN MAX(tu15.display_value)
                WHEN 'latest' THEN (array_agg(tu15.display_value ORDER BY tu15.bucket DESC))[1]
            END as display_value,
            -- Apply user aggregation method to raw_value (cumulative values for cumulative, raw for instantaneous)
            CASE p_aggregation_method
                WHEN 'sum' THEN SUM(tu15.raw_value)
                WHEN 'avg' THEN
                    CASE
                        WHEN SUM(tu15.sample_count) > 0 THEN
                            SUM(tu15.raw_value * tu15.sample_count) / SUM(tu15.sample_count)
                        ELSE NULL
                    END
                WHEN 'min' THEN MIN(tu15.raw_value)
                WHEN 'max' THEN MAX(tu15.raw_value)
                WHEN 'latest' THEN (array_agg(tu15.raw_value ORDER BY tu15.bucket DESC))[1]
            END as raw_value,
            NULL::integer as quality, -- Quality not available in aggregated data
            SUM(tu15.sample_count)::bigint as sample_count,
            COALESCE(MIN(tu15.source_system), 'system'::character varying)::character varying as source_system,
            tu15.is_cumulative,
            v_data_source_used::character varying as data_source,
            p_bucket::character varying as bucket_size,
            p_aggregation_method::character varying as aggregation_method
        FROM telemetry_unified_15min tu15
        JOIN devices d ON tu15.device_id = d.id
        WHERE
            (p_tenant_id IS NULL OR tu15.tenant_id = p_tenant_id)
            AND (p_device_ids IS NULL OR tu15.device_id = ANY(p_device_ids))
            AND (p_quantity_ids IS NULL OR tu15.quantity_id = ANY(p_quantity_ids))
            AND (p_start_time IS NULL OR tu15.bucket >= p_start_time)
            AND (p_end_time IS NULL OR tu15.bucket <= p_end_time)
            AND (p_tenant_id IS NULL OR d.tenant_id = p_tenant_id)
        GROUP BY
            date_trunc('year', tu15.bucket),
            tu15.tenant_id,
            tu15.device_id,
            d.device_name::character varying,
            tu15.quantity_id,
            tu15.quantity_code::character varying,
            tu15.quantity_name::character varying,
            tu15.unit::character varying,
            tu15.is_cumulative
        ORDER BY timestamp DESC
        LIMIT p_limit;

    ELSE
        RAISE EXCEPTION 'Invalid bucket size: %', p_bucket USING ERRCODE = 'P0004';
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        -- Log the error for debugging
        INSERT INTO audit_logs (
            user_id,
            action_type,
            resource_type,
            resource_id,
            action_description,
            created_at
        ) VALUES (
            p_user_id::varchar,
            'bucketed_telemetry_error',
            'telemetry_data',
            NULL,
            json_build_object(
                'error_message', SQLERRM,
                'error_code', SQLSTATE,
                'bucket', p_bucket,
                'aggregation_method', p_aggregation_method
            )::text,
            NOW()
        );

        -- Re-raise the exception
        RAISE;
END;
$$;


--
-- Name: FUNCTION get_bucketed_telemetry_for_user(p_user_id integer, p_bucket character varying, p_aggregation_method character varying, p_device_ids integer[], p_start_time timestamp without time zone, p_end_time timestamp without time zone, p_quantity_ids integer[], p_limit integer, p_tenant_id integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.get_bucketed_telemetry_for_user(p_user_id integer, p_bucket character varying, p_aggregation_method character varying, p_device_ids integer[], p_start_time timestamp without time zone, p_end_time timestamp without time zone, p_quantity_ids integer[], p_limit integer, p_tenant_id integer) IS 'Retrieve telemetry data with time bucketing and user-specified aggregation methods. Supports hourly, daily, weekly, monthly, and yearly bucketing with min, max, sum, avg, and latest aggregation methods. Uses telemetry_15min_agg as the primary data source for consistent performance.';


--
-- Name: get_bucketed_telemetry_for_user(integer, character varying, character varying, character varying, integer[], timestamp without time zone, timestamp without time zone, integer[], integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_bucketed_telemetry_for_user(p_user_id integer, p_bucket character varying, p_aggregation_method character varying, p_group_by character varying DEFAULT 'device'::character varying, p_device_ids integer[] DEFAULT NULL::integer[], p_start_time timestamp without time zone DEFAULT NULL::timestamp without time zone, p_end_time timestamp without time zone DEFAULT NULL::timestamp without time zone, p_quantity_ids integer[] DEFAULT NULL::integer[], p_limit integer DEFAULT 10000, p_tenant_id integer DEFAULT NULL::integer) RETURNS TABLE("timestamp" timestamp without time zone, tenant_id integer, device_id integer, device_name character varying, quantity_id integer, quantity_code character varying, quantity_name character varying, unit character varying, display_value numeric, raw_value numeric, quality integer, sample_count bigint, source_system character varying, is_cumulative boolean, data_source character varying, bucket_size character varying, aggregation_method character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_user_exists boolean := false;
    v_tenant_access boolean := false;
    v_audit_id bigint;
    v_data_source_used varchar := 'telemetry_unified_15min';
BEGIN
    -- Security and authentication validation
    
    -- 1. Validate user exists
    SELECT EXISTS(SELECT 1 FROM auth_users WHERE id = p_user_id) INTO v_user_exists;
    IF NOT v_user_exists THEN
        RAISE EXCEPTION 'User not found or access denied' USING ERRCODE = 'P0001';
    END IF;
    
    -- 2. Validate tenant access - user must be assigned to tenant
    IF p_tenant_id IS NOT NULL THEN
        SELECT EXISTS(
            SELECT 1 FROM auth_user_tenants ut
            WHERE ut.user_id = p_user_id AND ut.tenant_id = p_tenant_id AND ut.is_active = true
        ) INTO v_tenant_access;
        
        IF NOT v_tenant_access THEN
            RAISE EXCEPTION 'Tenant access denied' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    
    -- 3. Audit logging
    INSERT INTO audit_logs (
        user_id,
        action_type,
        resource_type,
        resource_id,
        action_description,
        created_at
    ) VALUES (
        p_user_id::varchar,
        'bucketed_telemetry_access',
        'telemetry_data',
        NULL,
        json_build_object(
            'bucket', p_bucket,
            'aggregation_method', p_aggregation_method,
            'group_by', p_group_by,
            'device_ids', p_device_ids,
            'quantity_ids', p_quantity_ids,
            'start_time', p_start_time,
            'end_time', p_end_time,
            'limit', p_limit,
            'tenant_id', p_tenant_id
        )::text,
        NOW()
    ) RETURNING id INTO v_audit_id;
    
    -- 4. Route based on bucket size and data availability
    IF p_bucket IN ('hourly', 'daily', 'weekly', 'monthly') THEN
        -- Use telemetry_unified_15min view with dynamic grouping
        RETURN QUERY
        SELECT
            date_trunc(
                CASE p_bucket
                    WHEN 'hourly' THEN 'hour'
                    WHEN 'daily' THEN 'day'
                    WHEN 'weekly' THEN 'week'
                    WHEN 'monthly' THEN 'month'
                    ELSE p_bucket
                END,
                tu15.bucket
            )::timestamp without time zone as "timestamp",
            tu15.tenant_id,
            -- Device fields conditional on grouping
            CASE p_group_by
                WHEN 'none' THEN NULL
                ELSE tu15.device_id
            END as device_id,
            CASE p_group_by
                WHEN 'none' THEN 'All Devices'::character varying
                ELSE d.device_name::character varying
            END as device_name,
            -- Quantity fields conditional on grouping  
            CASE p_group_by
                WHEN 'device' THEN NULL
                WHEN 'none' THEN NULL
                ELSE tu15.quantity_id
            END as quantity_id,
            CASE p_group_by
                WHEN 'device' THEN 'Multiple Quantities'::character varying
                WHEN 'none' THEN 'All Quantities'::character varying
                ELSE tu15.quantity_code::character varying
            END as quantity_code,
            CASE p_group_by
                WHEN 'device' THEN 'Multiple Quantities'::character varying
                WHEN 'none' THEN 'All Quantities'::character varying
                ELSE tu15.quantity_name::character varying
            END as quantity_name,
            CASE p_group_by
                WHEN 'device' THEN 'mixed'::character varying
                WHEN 'none' THEN 'mixed'::character varying
                ELSE tu15.unit::character varying
            END as unit,
            -- Apply user aggregation method to display_value
            CASE p_aggregation_method
                WHEN 'sum' THEN SUM(tu15.display_value)
                WHEN 'avg' THEN
                    CASE
                        WHEN SUM(tu15.sample_count) > 0 THEN
                            SUM(tu15.display_value * tu15.sample_count) / SUM(tu15.sample_count)
                        ELSE NULL
                    END
                WHEN 'min' THEN MIN(tu15.display_value)
                WHEN 'max' THEN MAX(tu15.display_value)
                WHEN 'latest' THEN (array_agg(tu15.display_value ORDER BY tu15.bucket DESC))[1]
            END as display_value,
            -- Apply user aggregation method to raw_value
            CASE p_aggregation_method
                WHEN 'sum' THEN SUM(tu15.raw_value)
                WHEN 'avg' THEN
                    CASE
                        WHEN SUM(tu15.sample_count) > 0 THEN
                            SUM(tu15.raw_value * tu15.sample_count) / SUM(tu15.sample_count)
                        ELSE NULL
                    END
                WHEN 'min' THEN MIN(tu15.raw_value)
                WHEN 'max' THEN MAX(tu15.raw_value)
                WHEN 'latest' THEN (array_agg(tu15.raw_value ORDER BY tu15.bucket DESC))[1]
            END as raw_value,
            NULL::integer as quality, -- Quality not available in aggregated data
            SUM(tu15.sample_count)::bigint as sample_count,
            COALESCE(MIN(tu15.source_system), 'system'::character varying)::character varying as source_system,
            CASE p_group_by
                WHEN 'device' THEN NULL
                WHEN 'none' THEN NULL
                ELSE tu15.is_cumulative
            END as is_cumulative,
            v_data_source_used::character varying as data_source,
            p_bucket::character varying as bucket_size,
            p_aggregation_method::character varying as aggregation_method
        FROM telemetry_unified_15min tu15
        LEFT JOIN devices d ON tu15.device_id = d.id
        WHERE
            (p_tenant_id IS NULL OR tu15.tenant_id = p_tenant_id)
            AND (p_device_ids IS NULL OR tu15.device_id = ANY(p_device_ids))
            AND (p_quantity_ids IS NULL OR tu15.quantity_id = ANY(p_quantity_ids))
            AND (p_start_time IS NULL OR tu15.bucket >= p_start_time)
            AND (p_end_time IS NULL OR tu15.bucket <= p_end_time)
        GROUP BY 
            date_trunc(
                CASE p_bucket
                    WHEN 'hourly' THEN 'hour'
                    WHEN 'daily' THEN 'day'
                    WHEN 'weekly' THEN 'week'
                    WHEN 'monthly' THEN 'month'
                    ELSE p_bucket
                END,
                tu15.bucket
            ),
            tu15.tenant_id,
            -- Dynamic grouping based on p_group_by parameter
            CASE p_group_by WHEN 'none' THEN NULL ELSE tu15.device_id END,
            CASE p_group_by WHEN 'none' THEN NULL ELSE d.device_name END,
            CASE p_group_by WHEN 'device' THEN NULL WHEN 'none' THEN NULL ELSE tu15.quantity_id END,
            CASE p_group_by WHEN 'device' THEN NULL WHEN 'none' THEN NULL ELSE tu15.quantity_code END,
            CASE p_group_by WHEN 'device' THEN NULL WHEN 'none' THEN NULL ELSE tu15.quantity_name END,
            CASE p_group_by WHEN 'device' THEN NULL WHEN 'none' THEN NULL ELSE tu15.unit END,
            CASE p_group_by WHEN 'device' THEN NULL WHEN 'none' THEN NULL ELSE tu15.is_cumulative END
        ORDER BY 1 DESC
        LIMIT p_limit;
        
    ELSE
        -- Handle yearly bucket separately (simplified for now)
        RETURN QUERY
        SELECT
            date_trunc('year', tu15.bucket)::timestamp without time zone as "timestamp",
            tu15.tenant_id,
            CASE p_group_by WHEN 'none' THEN NULL ELSE tu15.device_id END as device_id,
            CASE p_group_by WHEN 'none' THEN 'All Devices'::character varying ELSE d.device_name::character varying END as device_name,
            CASE p_group_by WHEN 'device' THEN NULL WHEN 'none' THEN NULL ELSE tu15.quantity_id END as quantity_id,
            CASE p_group_by WHEN 'device' THEN 'Multiple Quantities'::character varying WHEN 'none' THEN 'All Quantities'::character varying ELSE tu15.quantity_code::character varying END as quantity_code,
            CASE p_group_by WHEN 'device' THEN 'Multiple Quantities'::character varying WHEN 'none' THEN 'All Quantities'::character varying ELSE tu15.quantity_name::character varying END as quantity_name,
            CASE p_group_by WHEN 'device' THEN 'mixed'::character varying WHEN 'none' THEN 'mixed'::character varying ELSE tu15.unit::character varying END as unit,
            CASE p_aggregation_method
                WHEN 'sum' THEN SUM(tu15.display_value)
                WHEN 'avg' THEN AVG(tu15.display_value)
                WHEN 'min' THEN MIN(tu15.display_value)
                WHEN 'max' THEN MAX(tu15.display_value)
                WHEN 'latest' THEN (array_agg(tu15.display_value ORDER BY tu15.bucket DESC))[1]
            END as display_value,
            CASE p_aggregation_method
                WHEN 'sum' THEN SUM(tu15.raw_value)
                WHEN 'avg' THEN AVG(tu15.raw_value)
                WHEN 'min' THEN MIN(tu15.raw_value)
                WHEN 'max' THEN MAX(tu15.raw_value)
                WHEN 'latest' THEN (array_agg(tu15.raw_value ORDER BY tu15.bucket DESC))[1]
            END as raw_value,
            NULL::integer as quality,
            SUM(tu15.sample_count)::bigint as sample_count,
            COALESCE(MIN(tu15.source_system), 'system')::character varying as source_system,
            CASE p_group_by WHEN 'device' THEN NULL WHEN 'none' THEN NULL ELSE tu15.is_cumulative END as is_cumulative,
            v_data_source_used::character varying as data_source,
            p_bucket::character varying as bucket_size,
            p_aggregation_method::character varying as aggregation_method
        FROM telemetry_unified_15min tu15
        LEFT JOIN devices d ON tu15.device_id = d.id
        WHERE
            (p_tenant_id IS NULL OR tu15.tenant_id = p_tenant_id)
            AND (p_device_ids IS NULL OR tu15.device_id = ANY(p_device_ids))
            AND (p_quantity_ids IS NULL OR tu15.quantity_id = ANY(p_quantity_ids))
            AND (p_start_time IS NULL OR tu15.bucket >= p_start_time)
            AND (p_end_time IS NULL OR tu15.bucket <= p_end_time)
        GROUP BY 
            date_trunc('year', tu15.bucket),
            tu15.tenant_id,
            CASE p_group_by WHEN 'none' THEN NULL ELSE tu15.device_id END,
            CASE p_group_by WHEN 'none' THEN NULL ELSE d.device_name END,
            CASE p_group_by WHEN 'device' THEN NULL WHEN 'none' THEN NULL ELSE tu15.quantity_id END,
            CASE p_group_by WHEN 'device' THEN NULL WHEN 'none' THEN NULL ELSE tu15.quantity_code END,
            CASE p_group_by WHEN 'device' THEN NULL WHEN 'none' THEN NULL ELSE tu15.quantity_name END,
            CASE p_group_by WHEN 'device' THEN NULL WHEN 'none' THEN NULL ELSE tu15.unit END,
            CASE p_group_by WHEN 'device' THEN NULL WHEN 'none' THEN NULL ELSE tu15.is_cumulative END
        ORDER BY 1 DESC
        LIMIT p_limit;
    END IF;
    
END;
$$;


--
-- Name: get_device_alerts(integer, integer[], character varying, boolean, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_device_alerts(p_tenant_id integer, p_device_ids integer[] DEFAULT NULL::integer[], p_severity_filter character varying DEFAULT NULL::character varying, p_acknowledged_filter boolean DEFAULT NULL::boolean, p_limit integer DEFAULT 100) RETURNS TABLE(alert_id integer, device_id integer, severity character varying, message text, acknowledged boolean, created_at timestamp without time zone, acknowledged_at timestamp without time zone, acknowledged_by character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    -- Validate tenant exists and is active
    IF NOT EXISTS (SELECT 1 FROM tenants WHERE id = p_tenant_id AND is_active = true) THEN
        RAISE EXCEPTION 'Invalid or inactive tenant: %', p_tenant_id;
    END IF;
    
    -- Validate device ownership if device filter provided
    IF p_device_ids IS NOT NULL THEN
        IF EXISTS (
            SELECT 1 FROM unnest(p_device_ids) AS device_id 
            WHERE device_id NOT IN (
                SELECT id FROM devices WHERE tenant_id = p_tenant_id AND is_active = true
            )
        ) THEN
            RAISE EXCEPTION 'Access denied: one or more devices do not belong to tenant %', p_tenant_id;
        END IF;
    END IF;
    
    -- Return filtered alert data
    RETURN QUERY
    SELECT 
        da.id,
        da.device_id,
        da.severity,
        da.message,
        da.acknowledged,
        da.created_at,
        da.acknowledged_at,
        da.acknowledged_by
    FROM device_alerts da
    WHERE da.tenant_id = p_tenant_id
      AND (p_device_ids IS NULL OR da.device_id = ANY(p_device_ids))
      AND (p_severity_filter IS NULL OR da.severity = p_severity_filter)
      AND (p_acknowledged_filter IS NULL OR da.acknowledged = p_acknowledged_filter)
    ORDER BY da.created_at DESC, da.severity DESC
    LIMIT p_limit;
END;
$$;


--
-- Name: FUNCTION get_device_alerts(p_tenant_id integer, p_device_ids integer[], p_severity_filter character varying, p_acknowledged_filter boolean, p_limit integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.get_device_alerts(p_tenant_id integer, p_device_ids integer[], p_severity_filter character varying, p_acknowledged_filter boolean, p_limit integer) IS 'Secure access to device alerts with tenant validation and filtering';


--
-- Name: get_device_quantity_coverage(integer, integer[], integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_device_quantity_coverage(p_user_id integer, p_device_ids integer[], p_tenant_id integer DEFAULT NULL::integer, p_time_window_hours integer DEFAULT 168) RETURNS TABLE(quantity_info jsonb, device_coverage jsonb, missing_devices integer[], coverage_percentage numeric)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_tenant_filter integer[];
    v_cutoff_timestamp timestamp;
    v_total_devices integer;
BEGIN
    -- Input validation and setup (similar to main function)
    IF p_device_ids IS NULL OR array_length(p_device_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'Device IDs array cannot be null or empty';
    END IF;
    
    v_cutoff_timestamp := CURRENT_TIMESTAMP - (p_time_window_hours || ' hours')::INTERVAL;
    v_total_devices := array_length(p_device_ids, 1);
    
    -- Tenant validation (same logic as main function)
    IF p_tenant_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM auth_user_tenants 
            WHERE user_id = p_user_id AND tenant_id = p_tenant_id AND is_active = true
        ) THEN
            RAISE EXCEPTION 'User does not have access to tenant %', p_tenant_id;
        END IF;
        v_tenant_filter := ARRAY[p_tenant_id];
    ELSE
        SELECT ARRAY_AGG(tenant_id) INTO v_tenant_filter
        FROM auth_user_tenants 
        WHERE user_id = p_user_id AND is_active = true;
    END IF;
    
    -- Return coverage analysis for all quantities found
    RETURN QUERY
    WITH quantity_device_matrix AS (
        SELECT 
            q.id as quantity_id,
            q.quantity_code,
            q.quantity_name,
            q.unit,
            q.category,
            td.device_id,
            COUNT(td.id) as measurement_count,
            MAX(td.recorded_timestamp) as last_measurement
        FROM quantities q
        INNER JOIN telemetry_data td ON q.id = td.quantity_id
        WHERE td.device_id = ANY(p_device_ids)
          AND td.tenant_id = ANY(v_tenant_filter)
          AND td.recorded_timestamp >= v_cutoff_timestamp
          AND q.is_active = true
        GROUP BY q.id, q.quantity_code, q.quantity_name, q.unit, q.category, td.device_id
    ),
    coverage_summary AS (
        SELECT 
            quantity_id,
            quantity_code,
            quantity_name,
            unit,
            category,
            COUNT(DISTINCT device_id) as devices_with_data,
            ARRAY_AGG(DISTINCT device_id ORDER BY device_id) as devices_covered,
            SUM(measurement_count) as total_measurements
        FROM quantity_device_matrix
        GROUP BY quantity_id, quantity_code, quantity_name, unit, category
    )
    SELECT 
        jsonb_build_object(
            'id', cs.quantity_id,
            'code', cs.quantity_code,
            'name', cs.quantity_name,
            'unit', cs.unit,
            'category', cs.category
        ),
        jsonb_build_object(
            'devices_with_data', cs.devices_with_data,
            'total_measurements', cs.total_measurements,
            'devices_covered', cs.devices_covered
        ),
        -- Calculate missing devices
        (SELECT ARRAY(
            SELECT unnest(p_device_ids) 
            EXCEPT 
            SELECT unnest(cs.devices_covered)
        )),
        ROUND((cs.devices_with_data::decimal / v_total_devices) * 100, 2)
    FROM coverage_summary cs
    ORDER BY cs.devices_with_data DESC, cs.total_measurements DESC;
END;
$$;


--
-- Name: get_downstream_assets(integer, character varying, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_downstream_assets(source_asset_id integer, target_utility character varying DEFAULT NULL::character varying, max_depth integer DEFAULT NULL::integer) RETURNS TABLE(asset_id integer, asset_name character varying, utility_type character varying, distance_levels integer, asset_depth integer, connection_path text, traversal_method character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE downstream_trace AS (
        -- Non-recursive term: Start from source asset
        SELECT 
            a.id, 
            a.asset_name, 
            a.utility_type, 
            0 as level,
            0 as depth,  -- Asset hierarchy depth (excludes connections)
            a.asset_name::TEXT as path,
            'SOURCE'::VARCHAR(20) as method
        FROM assets a 
        WHERE a.id = source_asset_id
        
        UNION ALL
        
        -- Recursive term: Follow hierarchy and connections with depth logic
        SELECT 
            a.id, 
            a.asset_name, 
            a.utility_type, 
            dt.level + 1,
            CASE 
                -- Direct hierarchy: increment depth
                WHEN a.parent_id = dt.id AND a.utility_type = dt.utility_type THEN dt.depth + 1
                -- Connection traversal: maintain same depth for target asset
                WHEN EXISTS (
                    SELECT 1 FROM asset_connections ac 
                    WHERE ac.source_asset_id = dt.id 
                    AND ac.target_asset_id = a.id 
                    AND ac.is_active = true
                ) THEN dt.depth  -- Connection doesn't increase depth
                ELSE dt.depth + 1
            END,
            (dt.path || ' -> ' || a.asset_name)::TEXT,
            CASE 
                WHEN a.parent_id = dt.id AND a.utility_type = dt.utility_type THEN 'HIERARCHY'::VARCHAR(20)
                WHEN EXISTS (
                    SELECT 1 FROM asset_connections ac 
                    WHERE ac.source_asset_id = dt.id 
                    AND ac.target_asset_id = a.id 
                    AND ac.is_active = true
                ) THEN 'CONNECTION'::VARCHAR(20)
                ELSE 'MIXED'::VARCHAR(20)
            END
        FROM assets a
        JOIN downstream_trace dt ON (
            -- Follow children within same utility hierarchy
            (a.parent_id = dt.id AND a.utility_type = dt.utility_type)
            OR
            -- Follow connection targets (cross-utility distribution)
            EXISTS (
                SELECT 1 FROM asset_connections ac 
                WHERE ac.source_asset_id = dt.id 
                AND ac.target_asset_id = a.id 
                AND ac.is_active = true
            )
        )
        WHERE dt.level < 20 -- Prevent infinite loops
        -- Apply depth restriction if specified
        AND (max_depth IS NULL OR (
            CASE 
                WHEN a.parent_id = dt.id AND a.utility_type = dt.utility_type THEN dt.depth + 1
                WHEN EXISTS (
                    SELECT 1 FROM asset_connections ac 
                    WHERE ac.source_asset_id = dt.id 
                    AND ac.target_asset_id = a.id 
                    AND ac.is_active = true
                ) THEN dt.depth
                ELSE dt.depth + 1
            END
        ) <= max_depth)
    )
    SELECT 
        dt.id, 
        dt.asset_name, 
        dt.utility_type, 
        dt.level,
        dt.depth,
        dt.path,
        dt.method
    FROM downstream_trace dt
    WHERE dt.id != source_asset_id -- Exclude the starting asset
    AND (target_utility IS NULL OR dt.utility_type = target_utility)
    ORDER BY dt.depth, dt.level, dt.utility_type, dt.asset_name;
END;
$$;


--
-- Name: get_downstream_connections(integer, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_downstream_connections(source_asset_id integer, target_utility character varying DEFAULT NULL::character varying) RETURNS TABLE(asset_id integer, asset_name character varying, utility_type character varying, distance_levels integer, connection_type character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE connection_trace AS (
        SELECT 
            a.id, 
            a.asset_name, 
            a.utility_type, 
            0 as level,
            'SOURCE'::VARCHAR(50) as connection_type
        FROM assets a 
        WHERE a.id = source_asset_id
        
        UNION ALL
        
        SELECT 
            a.id, 
            a.asset_name, 
            a.utility_type, 
            ct.level + 1,
            ac.connection_type
        FROM assets a
        JOIN asset_connections ac ON ac.target_asset_id = a.id
        JOIN connection_trace ct ON ac.source_asset_id = ct.id
        WHERE ac.is_active = true
        AND ct.level < 20
    )
    SELECT ct.id, ct.asset_name, ct.utility_type, ct.level, ct.connection_type
    FROM connection_trace ct
    WHERE ct.id != source_asset_id
    AND (target_utility IS NULL OR ct.utility_type = target_utility)
    ORDER BY ct.level, ct.utility_type, ct.asset_name;
END;
$$;


--
-- Name: get_downstream_devices_by_depth(integer, integer, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_downstream_devices_by_depth(source_device_id integer, target_depth integer, target_utility character varying DEFAULT NULL::character varying) RETURNS TABLE(device_id integer, device_code character varying, device_name character varying, device_type character varying, display_name character varying, alias character varying, asset_id integer, asset_name character varying, asset_type character varying, utility_type character varying, asset_depth integer, is_connected_asset boolean, tenant_id integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Validate that the source device exists
    IF NOT EXISTS (SELECT 1 FROM devices WHERE id = source_device_id AND is_active = true) THEN
        RAISE EXCEPTION 'Source device with ID % not found or inactive', source_device_id;
    END IF;

    RETURN QUERY
    WITH RECURSIVE asset_trace AS (
        -- Start from the asset associated with the source device
        SELECT 
            a.id as asset_id, 
            a.asset_name, 
            a.asset_type,
            a.utility_type,
            a.tenant_id,
            0 as depth,
            false as is_connected
        FROM devices d
        JOIN assets a ON d.asset_id = a.id
        WHERE d.id = source_device_id
        AND a.is_active = true
        
        UNION ALL
        
        -- Recursive traversal following the same logic as get_downstream_assets_by_depth
        SELECT 
            a.id,
            a.asset_name,
            a.asset_type,
            a.utility_type,
            a.tenant_id,
            CASE 
                -- Direct hierarchy child: increment depth
                WHEN a.parent_id = at.asset_id AND a.utility_type = at.utility_type THEN at.depth + 1
                -- Connected asset: same depth as source of connection
                ELSE at.depth
            END,
            -- Mark if this asset came through a connection
            EXISTS (
                SELECT 1 FROM asset_connections ac 
                WHERE ac.source_asset_id = at.asset_id 
                AND ac.target_asset_id = a.id 
                AND ac.is_active = true
            )
        FROM assets a
        JOIN asset_trace at ON (
            -- Follow hierarchy within same utility
            (a.parent_id = at.asset_id AND a.utility_type = at.utility_type)
            OR
            -- Follow connections across utilities
            EXISTS (
                SELECT 1 FROM asset_connections ac 
                WHERE ac.source_asset_id = at.asset_id 
                AND ac.target_asset_id = a.id 
                AND ac.is_active = true
            )
        )
        WHERE (
            CASE 
                WHEN a.parent_id = at.asset_id AND a.utility_type = at.utility_type THEN at.depth + 1
                ELSE at.depth
            END
        ) <= target_depth
        AND a.is_active = true
        AND at.depth < 20 -- Safety limit to prevent infinite loops
    ),
    -- Second pass: get children of connected assets within depth limit
    extended_asset_trace AS (
        SELECT * FROM asset_trace
        
        UNION ALL
        
        SELECT 
            a.id,
            a.asset_name,
            a.asset_type,
            a.utility_type,
            a.tenant_id,
            at.depth + 1,
            false -- These are hierarchy children, not direct connections
        FROM assets a
        JOIN asset_trace at ON a.parent_id = at.asset_id
        WHERE at.is_connected = true -- Only extend from connected assets
        AND a.utility_type = at.utility_type -- Same utility hierarchy
        AND at.depth + 1 <= target_depth -- Respect depth limit
        AND a.is_active = true
        AND NOT EXISTS (SELECT 1 FROM asset_trace at2 WHERE at2.asset_id = a.id) -- Avoid duplicates
    )
    -- Final selection: join with devices to get device information
    SELECT 
        d.id,
        d.device_code,
        d.device_name,
        d.device_type,
        d.display_name,
        d.alias,
        eat.asset_id,
        eat.asset_name,
        eat.asset_type,
        eat.utility_type,
        eat.depth,
        eat.is_connected,
        eat.tenant_id
    FROM extended_asset_trace eat
    JOIN devices d ON d.asset_id = eat.asset_id
    WHERE d.id != source_device_id -- Exclude the source device
    AND d.is_active = true
    AND (target_utility IS NULL OR eat.utility_type = target_utility)
    ORDER BY eat.depth, eat.utility_type, d.device_name;
END;
$$;


--
-- Name: get_downstream_hierarchy(integer, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_downstream_hierarchy(source_asset_id integer, target_utility character varying DEFAULT NULL::character varying) RETURNS TABLE(asset_id integer, asset_name character varying, utility_type character varying, distance_levels integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE hierarchy_trace AS (
        SELECT a.id, a.asset_name, a.utility_type, 0 as level
        FROM assets a 
        WHERE a.id = source_asset_id
        
        UNION ALL
        
        SELECT a.id, a.asset_name, a.utility_type, ht.level + 1
        FROM assets a
        JOIN hierarchy_trace ht ON a.parent_id = ht.id
        WHERE a.utility_type = ht.utility_type
        AND ht.level < 20
    )
    SELECT ht.id, ht.asset_name, ht.utility_type, ht.level
    FROM hierarchy_trace ht
    WHERE ht.id != source_asset_id
    AND (target_utility IS NULL OR ht.utility_type = target_utility)
    ORDER BY ht.level, ht.utility_type, ht.asset_name;
END;
$$;


--
-- Name: get_facility_hotspots(integer, integer, character varying, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_facility_hotspots(p_tenant_id integer, p_asset_id integer DEFAULT NULL::integer, p_hotspot_type character varying DEFAULT NULL::character varying, p_level integer DEFAULT NULL::integer) RETURNS TABLE(hotspot_id integer, asset_id integer, device_id integer, file_id integer, coordinate_type character varying, x_coordinate numeric, y_coordinate numeric, z_coordinate numeric, yaw numeric, pitch numeric, hotspot_label character varying, hotspot_color character varying, hotspot_type character varying, level integer, navigation_target_id integer, chart_data_source_id integer, is_active boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    -- Validate tenant exists and is active
    IF NOT EXISTS (SELECT 1 FROM tenants WHERE id = p_tenant_id AND is_active = true) THEN
        RAISE EXCEPTION 'Invalid or inactive tenant: %', p_tenant_id;
    END IF;
    
    -- Validate asset ownership if asset filter provided
    IF p_asset_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM assets 
            WHERE id = p_asset_id AND tenant_id = p_tenant_id AND is_active = true
        ) THEN
            RAISE EXCEPTION 'Asset not found or access denied';
        END IF;
    END IF;
    
    -- Return hotspot data with new fields
    RETURN QUERY
    SELECT 
        hc.id,
        hc.asset_id,
        hc.device_id,
        hc.file_id,
        hc.coordinate_type,
        hc.x_coordinate,
        hc.y_coordinate,
        hc.z_coordinate,
        hc.yaw,
        hc.pitch,
        hc.hotspot_label,
        hc.hotspot_color,
        hc.hotspot_type,
        hc.level,
        hc.navigation_target_id,
        hc.chart_data_source_id,
        hc.is_active
    FROM hotspot_coordinates hc
    LEFT JOIN assets a ON hc.asset_id = a.id
    LEFT JOIN devices d ON hc.device_id = d.id
    WHERE hc.is_active = true
      AND (
          (hc.asset_id IS NOT NULL AND a.tenant_id = p_tenant_id) OR
          (hc.device_id IS NOT NULL AND d.tenant_id = p_tenant_id)
      )
      AND (p_asset_id IS NULL OR hc.asset_id = p_asset_id OR hc.device_id IN (
          SELECT id FROM devices WHERE asset_id = p_asset_id
      ))
      AND (p_hotspot_type IS NULL OR hc.hotspot_type = p_hotspot_type)
      AND (p_level IS NULL OR hc.level = p_level)
    ORDER BY hc.level, hc.hotspot_type, hc.id;
END;
$$;


--
-- Name: FUNCTION get_facility_hotspots(p_tenant_id integer, p_asset_id integer, p_hotspot_type character varying, p_level integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.get_facility_hotspots(p_tenant_id integer, p_asset_id integer, p_hotspot_type character varying, p_level integer) IS 'Enhanced hotspot data access with new coordinate types and navigation features';


--
-- Name: get_gap_corrected_intervals(integer, integer[], timestamp without time zone, timestamp without time zone, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_gap_corrected_intervals(p_tenant_id integer, p_device_ids integer[], p_start_time timestamp without time zone, p_end_time timestamp without time zone, p_gap_threshold_hours numeric DEFAULT 2.0) RETURNS TABLE(bucket timestamp without time zone, tenant_id integer, device_id integer, quantity_id integer, quantity_code character varying, quantity_name character varying, unit character varying, cumulative_value numeric, interval_value numeric, sample_count bigint, source_system character varying, is_reset boolean, is_register_correction boolean, is_unrealistic_spike boolean, is_tiny_negative boolean, is_extreme_interval boolean, interval_classification text, data_quality_flag text, is_redistributed boolean, redistribution_method character varying, original_interval_value numeric, gap_confidence_score numeric)
    LANGUAGE plpgsql
    AS $$
DECLARE
    gap_rec RECORD;
    processed_gap_id INTEGER;
BEGIN
    -- Process any new gaps found (execute immediately)
    FOR gap_rec IN 
        SELECT dg.*
        FROM detect_gaps_in_timerange(
            p_tenant_id, 
            p_device_ids, 
            p_start_time, 
            p_end_time, 
            p_gap_threshold_hours
        ) dg
        LEFT JOIN processed_gaps pg ON (
            pg.tenant_id = dg.tenant_id 
            AND pg.device_id = dg.device_id 
            AND pg.quantity_id = dg.quantity_id
            AND pg.gap_start = dg.gap_start 
            AND pg.gap_end = dg.gap_end
        )
        WHERE pg.id IS NULL  -- Not already processed
    LOOP
        -- Process each new gap immediately
        SELECT process_detected_gap(
            gap_rec.tenant_id,
            gap_rec.device_id, 
            gap_rec.quantity_id,
            gap_rec.gap_start,
            gap_rec.gap_end,
            gap_rec.suspected_accumulated_bucket,
            gap_rec.suspected_accumulated_value,
            'DASHBOARD_AUTO'
        ) INTO processed_gap_id;
        
        RAISE NOTICE 'Processed gap ID: % for device % from % to %', 
            processed_gap_id, gap_rec.device_id, gap_rec.gap_start, gap_rec.gap_end;
    END LOOP;
    
    -- Return the corrected dataset
    RETURN QUERY
    WITH base_data AS (
        SELECT 
            tc.bucket,
            tc.tenant_id,
            tc.device_id,
            tc.quantity_id,
            tc.quantity_code,
            tc.quantity_name,
            tc.unit,
            tc.cumulative_value,
            tc.interval_value as original_interval_value,
            tc.sample_count,
            tc.source_system,
            tc.is_reset,
            tc.is_register_correction,
            tc.is_unrealistic_spike,
            tc.is_tiny_negative,
            tc.is_extreme_interval,
            tc.interval_classification,
            tc.data_quality_flag
        FROM telemetry_intervals_cumulative tc
        WHERE tc.tenant_id = p_tenant_id
          AND tc.device_id = ANY(p_device_ids)
          AND tc.bucket BETWEEN p_start_time AND p_end_time
    ),
    all_redistributed_data AS (
        SELECT 
            ri.bucket,
            pg.tenant_id,
            pg.device_id,
            pg.quantity_id,
            ri.redistributed_value,
            pg.redistribution_method,
            pg.original_interval_value,
            ri.confidence_score,
            pg.gap_start,
            pg.gap_end,
            pg.original_bucket  -- The specific bucket that had accumulated value
        FROM redistributed_intervals ri
        JOIN processed_gaps pg ON ri.gap_id = pg.id
        WHERE pg.tenant_id = p_tenant_id
          AND pg.device_id = ANY(p_device_ids)
          AND ri.bucket BETWEEN p_start_time AND p_end_time
    ),
    final_dataset AS (
        -- Original data that's NOT in any gap period
        SELECT 
            bd.bucket,
            bd.tenant_id,
            bd.device_id,
            bd.quantity_id,
            bd.quantity_code,
            bd.quantity_name,
            bd.unit,
            bd.cumulative_value,
            bd.original_interval_value as interval_value,
            bd.sample_count,
            bd.source_system,
            bd.is_reset,
            bd.is_register_correction,
            bd.is_unrealistic_spike,
            bd.is_tiny_negative,
            bd.is_extreme_interval,
            bd.interval_classification,
            bd.data_quality_flag,
            false as is_redistributed,
            ''::VARCHAR as redistribution_method,
            NULL::NUMERIC as gap_original_value,
            0.0 as confidence_score
        FROM base_data bd
        WHERE NOT EXISTS (
            -- Exclude any data within gap periods (including the accumulated reading)
            SELECT 1 FROM all_redistributed_data ard 
            WHERE ard.tenant_id = bd.tenant_id
              AND ard.device_id = bd.device_id
              AND ard.quantity_id = bd.quantity_id
              AND bd.bucket BETWEEN ard.gap_start AND ard.gap_end
        )
        
        UNION ALL
        
        -- Redistributed intervals (including the accumulated reading slot)
        SELECT 
            ard.bucket,
            ard.tenant_id,
            ard.device_id,
            ard.quantity_id,
            q.quantity_code,
            q.quantity_name, 
            q.unit::CHARACTER VARYING(50),
            NULL as cumulative_value,  -- Don't recalculate cumulative for redistributed data
            ard.redistributed_value as interval_value,
            1::BIGINT as sample_count,
            'GAP_CORRECTION'::VARCHAR as source_system,
            false as is_reset,
            false as is_register_correction, 
            false as is_unrealistic_spike,
            false as is_tiny_negative,
            false as is_extreme_interval,
            'REDISTRIBUTED_CONSUMPTION'::TEXT as interval_classification,
            'GAP_CORRECTED'::TEXT as data_quality_flag,
            true as is_redistributed,
            ard.redistribution_method::VARCHAR,
            ard.original_interval_value,
            ard.confidence_score
        FROM all_redistributed_data ard
        JOIN quantities q ON ard.quantity_id = q.id
    )
    SELECT 
        fd.bucket,
        fd.tenant_id,
        fd.device_id,
        fd.quantity_id,
        fd.quantity_code,
        fd.quantity_name,
        fd.unit,
        fd.cumulative_value,
        fd.interval_value,
        fd.sample_count,
        fd.source_system,
        fd.is_reset,
        fd.is_register_correction,
        fd.is_unrealistic_spike,
        fd.is_tiny_negative,
        fd.is_extreme_interval,
        fd.interval_classification,
        fd.data_quality_flag,
        fd.is_redistributed,
        fd.redistribution_method,
        fd.gap_original_value,
        fd.confidence_score
    FROM final_dataset fd
    ORDER BY fd.bucket;
END;
$$;


--
-- Name: get_latest_telemetry_for_user(integer, integer[], integer[], integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_latest_telemetry_for_user(p_user_id integer, p_device_ids integer[] DEFAULT NULL::integer[], p_quantity_ids integer[] DEFAULT NULL::integer[], p_tenant_id integer DEFAULT NULL::integer) RETURNS TABLE("timestamp" timestamp without time zone, tenant_id integer, device_id integer, quantity_id integer, value numeric, quality integer, source_system character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    accessible_tenant_ids INTEGER[];
    filtered_device_ids INTEGER[];
BEGIN
    -- Validate user and get accessible tenants
    IF NOT EXISTS (
        SELECT 1 FROM auth_users 
        WHERE id = p_user_id AND is_active = true
    ) THEN
        RAISE EXCEPTION 'Invalid or inactive user: %', p_user_id;
    END IF;
    
    SELECT ARRAY_AGG(DISTINCT ut.tenant_id) INTO accessible_tenant_ids
    FROM auth_user_tenants ut
    JOIN auth_products p ON ut.product_id = p.id
    WHERE ut.user_id = p_user_id 
    AND ut.is_active = true
    AND (ut.expires_at IS NULL OR ut.expires_at > CURRENT_TIMESTAMP)
    AND p.is_active = true
    AND (
        'read_telemetry' = ANY(ut.permissions) OR
        'api_read' = ANY(ut.permissions)
    );
    
    IF accessible_tenant_ids IS NULL OR array_length(accessible_tenant_ids, 1) = 0 THEN
        RETURN;
    END IF;
    
    -- Filter by specific tenant if requested
    IF p_tenant_id IS NOT NULL THEN
        IF NOT (p_tenant_id = ANY(accessible_tenant_ids)) THEN
            RETURN;
        END IF;
        accessible_tenant_ids := ARRAY[p_tenant_id];
    END IF;
    
    -- Filter devices
    IF p_device_ids IS NOT NULL THEN
        SELECT ARRAY_AGG(d.id) INTO filtered_device_ids
        FROM devices d
        WHERE d.id = ANY(p_device_ids)
        AND d.tenant_id = ANY(accessible_tenant_ids)
        AND d.is_active = true;
        
        IF filtered_device_ids IS NULL OR array_length(filtered_device_ids, 1) = 0 THEN
            RETURN;
        END IF;
    END IF;
    
    -- Get latest values using window function
    RETURN QUERY
    WITH latest_data AS (
        SELECT 
            td.timestamp,
            d.tenant_id,
            td.device_id,
            td.quantity_id,
            td.value,
            td.quality,
            td.source_system,
            ROW_NUMBER() OVER (
                PARTITION BY td.device_id, td.quantity_id 
                ORDER BY td.timestamp DESC
            ) as rn
        FROM telemetry_data td
        JOIN devices d ON td.device_id = d.id
        WHERE d.tenant_id = ANY(accessible_tenant_ids)
          AND (filtered_device_ids IS NULL OR td.device_id = ANY(filtered_device_ids))
          AND (p_quantity_ids IS NULL OR td.quantity_id = ANY(p_quantity_ids))
          AND d.is_active = true
          AND td.timestamp >= NOW() - INTERVAL '24 hours'  -- Only recent data
    )
    SELECT 
        ld.timestamp,
        ld.tenant_id,
        ld.device_id,
        ld.quantity_id,
        ld.value,
        ld.quality,
        ld.source_system
    FROM latest_data ld
    WHERE ld.rn = 1
    ORDER BY ld.timestamp DESC;
    
END;
$$;


--
-- Name: FUNCTION get_latest_telemetry_for_user(p_user_id integer, p_device_ids integer[], p_quantity_ids integer[], p_tenant_id integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.get_latest_telemetry_for_user(p_user_id integer, p_device_ids integer[], p_quantity_ids integer[], p_tenant_id integer) IS 'Get latest telemetry values with user-based authentication';


--
-- Name: get_power_quality_index(integer, timestamp without time zone, timestamp without time zone, character varying, numeric, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_power_quality_index(p_device_id integer, p_start_time timestamp without time zone, p_end_time timestamp without time zone, p_equipment_type character varying DEFAULT 'standard'::character varying, p_nominal_voltage numeric DEFAULT 400, p_custom_weights jsonb DEFAULT NULL::jsonb) RETURNS TABLE("timestamp" timestamp without time zone, device_id integer, total_active_power numeric, total_reactive_power numeric, total_apparent_power numeric, avg_voltage_ln numeric, avg_voltage_ll numeric, avg_current numeric, avg_power_factor numeric, avg_thd_voltage_ln numeric, avg_thd_voltage_ll numeric, avg_thd_current numeric, voltage_deviation_score numeric, voltage_unbalance_score numeric, voltage_thd_score numeric, current_unbalance_score numeric, current_thd_score numeric, power_factor_score numeric, power_factor_consistency_score numeric, power_balance_score numeric, system_efficiency_score numeric, harmonic_distortion_score numeric, voltage_quality_category numeric, current_quality_category numeric, power_factor_category numeric, power_balance_category numeric, efficiency_category numeric, harmonic_distortion_category numeric, power_quality_index numeric, pqi_rating character varying, equipment_type character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_voltage_tolerance_excellent NUMERIC;
    v_voltage_tolerance_good NUMERIC;
    v_voltage_tolerance_fair NUMERIC;
    v_voltage_thd_excellent NUMERIC;
    v_voltage_thd_good NUMERIC;
    v_voltage_thd_fair NUMERIC;
    v_current_thd_excellent NUMERIC;
    v_current_thd_good NUMERIC;
    v_current_thd_fair NUMERIC;
    v_pf_excellent NUMERIC;
    v_pf_good NUMERIC;
    v_pf_fair NUMERIC;
    
    -- Weight variables (with v_ prefix)
    v_w_voltage_deviation NUMERIC;
    v_w_voltage_unbalance NUMERIC;
    v_w_voltage_thd NUMERIC;
    v_w_current_unbalance NUMERIC;
    v_w_current_thd NUMERIC;
    v_w_power_factor NUMERIC;
    v_w_power_factor_consistency NUMERIC;
    v_w_power_balance NUMERIC;
    v_w_system_efficiency NUMERIC;
    v_w_harmonic_distortion NUMERIC;
BEGIN
    -- Set equipment-specific thresholds
    CASE p_equipment_type
        WHEN 'variable_frequency_drive' THEN
            v_voltage_tolerance_excellent := 2.0;  -- ±2% for VFDs
            v_voltage_tolerance_good := 5.0;
            v_voltage_tolerance_fair := 8.0;
            v_voltage_thd_excellent := 2.0;        -- Stricter THD for VFDs
            v_voltage_thd_good := 3.0;
            v_voltage_thd_fair := 5.0;
            v_current_thd_excellent := 8.0;
            v_current_thd_good := 12.0;
            v_current_thd_fair := 15.0;
            v_pf_excellent := 0.95;
            v_pf_good := 0.90;
            v_pf_fair := 0.85;
            
        WHEN 'server_equipment' THEN
            v_voltage_tolerance_excellent := 1.0;  -- Very strict for servers
            v_voltage_tolerance_good := 3.0;
            v_voltage_tolerance_fair := 5.0;
            v_voltage_thd_excellent := 3.0;
            v_voltage_thd_good := 5.0;
            v_voltage_thd_fair := 8.0;
            v_current_thd_excellent := 5.0;
            v_current_thd_good := 8.0;
            v_current_thd_fair := 12.0;
            v_pf_excellent := 0.90;
            v_pf_good := 0.85;
            v_pf_fair := 0.80;
            
        WHEN 'led_lighting' THEN
            v_voltage_tolerance_excellent := 5.0;  -- More tolerant
            v_voltage_tolerance_good := 8.0;
            v_voltage_tolerance_fair := 12.0;
            v_voltage_thd_excellent := 5.0;
            v_voltage_thd_good := 8.0;
            v_voltage_thd_fair := 12.0;
            v_current_thd_excellent := 15.0;
            v_current_thd_good := 20.0;
            v_current_thd_fair := 30.0;
            v_pf_excellent := 0.85;              -- LED drivers often have lower PF
            v_pf_good := 0.80;
            v_pf_fair := 0.75;
            
        WHEN 'motor_load' THEN
            v_voltage_tolerance_excellent := 3.0;
            v_voltage_tolerance_good := 5.0;
            v_voltage_tolerance_fair := 8.0;
            v_voltage_thd_excellent := 3.0;
            v_voltage_thd_good := 5.0;
            v_voltage_thd_fair := 8.0;
            v_current_thd_excellent := 8.0;
            v_current_thd_good := 12.0;
            v_current_thd_fair := 20.0;
            v_pf_excellent := 0.90;
            v_pf_good := 0.85;
            v_pf_fair := 0.80;
            
        ELSE -- 'standard' or any other type
            v_voltage_tolerance_excellent := 3.0;  -- ±3% standard
            v_voltage_tolerance_good := 5.0;
            v_voltage_tolerance_fair := 8.0;
            v_voltage_thd_excellent := 3.0;
            v_voltage_thd_good := 5.0;
            v_voltage_thd_fair := 8.0;
            v_current_thd_excellent := 5.0;
            v_current_thd_good := 8.0;
            v_current_thd_fair := 12.0;
            v_pf_excellent := 0.95;
            v_pf_good := 0.90;
            v_pf_fair := 0.85;
    END CASE;
    
    -- Set default weights (can be overridden by custom_weights)
    v_w_voltage_deviation := 0.10;
    v_w_voltage_unbalance := 0.05;
    v_w_voltage_thd := 0.05;
    v_w_current_unbalance := 0.15;
    v_w_current_thd := 0.10;
    v_w_power_factor := 0.12;
    v_w_power_factor_consistency := 0.08;
    v_w_power_balance := 0.15;
    v_w_system_efficiency := 0.10;
    v_w_harmonic_distortion := 0.10;
    
    -- Override weights if custom weights provided
    IF p_custom_weights IS NOT NULL THEN
        v_w_voltage_deviation := COALESCE((p_custom_weights->>'voltage_deviation')::NUMERIC, w_voltage_deviation);
        v_w_voltage_unbalance := COALESCE((p_custom_weights->>'voltage_unbalance')::NUMERIC, w_voltage_unbalance);
        v_w_voltage_thd := COALESCE((p_custom_weights->>'voltage_thd')::NUMERIC, w_voltage_thd);
        v_w_current_unbalance := COALESCE((p_custom_weights->>'current_unbalance')::NUMERIC, w_current_unbalance);
        v_w_current_thd := COALESCE((p_custom_weights->>'current_thd')::NUMERIC, w_current_thd);
        v_w_power_factor := COALESCE((p_custom_weights->>'power_factor')::NUMERIC, w_power_factor);
        v_w_power_factor_consistency := COALESCE((p_custom_weights->>'power_factor_consistency')::NUMERIC, w_power_factor_consistency);
        v_w_power_balance := COALESCE((p_custom_weights->>'power_balance')::NUMERIC, w_power_balance);
        v_w_system_efficiency := COALESCE((p_custom_weights->>'system_efficiency')::NUMERIC, w_system_efficiency);
        v_w_harmonic_distortion := COALESCE((p_custom_weights->>'harmonic_distortion')::NUMERIC, w_harmonic_distortion);
    END IF;
    
    -- Return the calculated PQI data
    RETURN QUERY
    WITH latest_readings AS (
      SELECT 
        td.device_id,
        td.timestamp,
        -- Active Power (3 phases)
        MAX(CASE WHEN td.quantity_id = 504 THEN td.value END) as active_power_l1,
        MAX(CASE WHEN td.quantity_id = 505 THEN td.value END) as active_power_l2,
        MAX(CASE WHEN td.quantity_id = 506 THEN td.value END) as active_power_l3,
        
        -- Reactive Power (3 phases)
        MAX(CASE WHEN td.quantity_id = 507 THEN td.value END) as reactive_power_l1,
        MAX(CASE WHEN td.quantity_id = 508 THEN td.value END) as reactive_power_l2,
        MAX(CASE WHEN td.quantity_id = 509 THEN td.value END) as reactive_power_l3,
        
        -- Apparent Power (3 phases)
        MAX(CASE WHEN td.quantity_id = 510 THEN td.value END) as apparent_power_l1,
        MAX(CASE WHEN td.quantity_id = 511 THEN td.value END) as apparent_power_l2,
        MAX(CASE WHEN td.quantity_id = 512 THEN td.value END) as apparent_power_l3,
        
        -- Voltage Line to Line
        MAX(CASE WHEN td.quantity_id = 1057 THEN td.value END) as voltage_l1l2,
        MAX(CASE WHEN td.quantity_id = 1058 THEN td.value END) as voltage_l2l3,
        MAX(CASE WHEN td.quantity_id = 1059 THEN td.value END) as voltage_l3l1,
        
        -- Voltage Line to Neutral
        MAX(CASE WHEN td.quantity_id = 1060 THEN td.value END) as voltage_l1n,
        MAX(CASE WHEN td.quantity_id = 1061 THEN td.value END) as voltage_l2n,
        MAX(CASE WHEN td.quantity_id = 1062 THEN td.value END) as voltage_l3n,
        
        -- Current (3 phases)
        MAX(CASE WHEN td.quantity_id = 501 THEN td.value END) as current_l1,
        MAX(CASE WHEN td.quantity_id = 502 THEN td.value END) as current_l2,
        MAX(CASE WHEN td.quantity_id = 503 THEN td.value END) as current_l3,
        
        -- Power Factor (3 phases)
        MAX(CASE WHEN td.quantity_id = 3325 THEN td.value END) as power_factor_l1,
        MAX(CASE WHEN td.quantity_id = 3326 THEN td.value END) as power_factor_l2,
        MAX(CASE WHEN td.quantity_id = 3327 THEN td.value END) as power_factor_l3,
        
        -- Total Harmonic Distortion - Voltage Line to Line
        MAX(CASE WHEN td.quantity_id = 2034 THEN td.value END) as thd_v_l1l2,
        MAX(CASE WHEN td.quantity_id = 2036 THEN td.value END) as thd_v_l2l3,
        MAX(CASE WHEN td.quantity_id = 2038 THEN td.value END) as thd_v_l3l1,
        
        -- Total Harmonic Distortion - Voltage Line to Neutral
        MAX(CASE WHEN td.quantity_id = 2035 THEN td.value END) as thd_v_l1n,
        MAX(CASE WHEN td.quantity_id = 2037 THEN td.value END) as thd_v_l2n,
        MAX(CASE WHEN td.quantity_id = 2039 THEN td.value END) as thd_v_l3n,
        
        -- Total Harmonic Distortion - Current
        MAX(CASE WHEN td.quantity_id = 2097 THEN td.value END) as thd_i_l1,
        MAX(CASE WHEN td.quantity_id = 2098 THEN td.value END) as thd_i_l2,
        MAX(CASE WHEN td.quantity_id = 2099 THEN td.value END) as thd_i_l3
        
      FROM telemetry_data td
      WHERE td.device_id = p_device_id
        AND td.timestamp >= p_start_time
        AND td.timestamp <= p_end_time
      GROUP BY td.device_id, td.timestamp
    ),
    
    power_calculations AS (
      SELECT 
        *,
        -- Total Power Values
        (COALESCE(active_power_l1, 0) + COALESCE(active_power_l2, 0) + COALESCE(active_power_l3, 0)) as total_active_power,
        (COALESCE(reactive_power_l1, 0) + COALESCE(reactive_power_l2, 0) + COALESCE(reactive_power_l3, 0)) as total_reactive_power,
        (COALESCE(apparent_power_l1, 0) + COALESCE(apparent_power_l2, 0) + COALESCE(apparent_power_l3, 0)) as total_apparent_power,
        
        -- Average Voltage Calculations
        (COALESCE(voltage_l1n, 0) + COALESCE(voltage_l2n, 0) + COALESCE(voltage_l3n, 0)) / 3.0 as avg_voltage_ln,
        (COALESCE(voltage_l1l2, 0) + COALESCE(voltage_l2l3, 0) + COALESCE(voltage_l3l1, 0)) / 3.0 as avg_voltage_ll,
        
        -- Average Current (3 phases only)
        (COALESCE(current_l1, 0) + COALESCE(current_l2, 0) + COALESCE(current_l3, 0)) / 3.0 as avg_current,
        
        -- Average Power Factor
        (COALESCE(power_factor_l1, 0) + COALESCE(power_factor_l2, 0) + COALESCE(power_factor_l3, 0)) / 3.0 as avg_power_factor,
        
        -- Average THD Calculations
        (COALESCE(thd_v_l1n, 0) + COALESCE(thd_v_l2n, 0) + COALESCE(thd_v_l3n, 0)) / 3.0 as avg_thd_voltage_ln,
        (COALESCE(thd_v_l1l2, 0) + COALESCE(thd_v_l2l3, 0) + COALESCE(thd_v_l3l1, 0)) / 3.0 as avg_thd_voltage_ll,
        (COALESCE(thd_i_l1, 0) + COALESCE(thd_i_l2, 0) + COALESCE(thd_i_l3, 0)) / 3.0 as avg_thd_current
        
      FROM latest_readings
    ),
    
    pqi_components AS (
      SELECT 
        pc.*,
        
        -- A. VOLTAGE QUALITY SCORES (20% total weight)
        -- Voltage deviation from nominal (using parameter)
        CASE 
          WHEN pc.avg_voltage_ln BETWEEN (p_nominal_voltage * (1 - v_voltage_tolerance_excellent/100)) 
                                  AND (p_nominal_voltage * (1 + v_voltage_tolerance_excellent/100)) THEN 100
          WHEN pc.avg_voltage_ln BETWEEN (p_nominal_voltage * (1 - v_voltage_tolerance_good/100)) 
                                  AND (p_nominal_voltage * (1 + v_voltage_tolerance_good/100)) THEN 
            90 - (ABS(pc.avg_voltage_ln - p_nominal_voltage) / p_nominal_voltage * 100 * 2)
          WHEN pc.avg_voltage_ln BETWEEN (p_nominal_voltage * (1 - v_voltage_tolerance_fair/100)) 
                                  AND (p_nominal_voltage * (1 + v_voltage_tolerance_fair/100)) THEN 
            70 - (ABS(pc.avg_voltage_ln - p_nominal_voltage) / p_nominal_voltage * 100)
          ELSE 0
        END as voltage_deviation_score,
        
        -- Voltage unbalance score (Line-to-Neutral)
        CASE 
          WHEN pc.voltage_l1n > 0 AND pc.voltage_l2n > 0 AND pc.voltage_l3n > 0 AND pc.avg_voltage_ln > 0 THEN
            GREATEST(0, 100 - (
              (GREATEST(
                ABS(pc.voltage_l1n - pc.avg_voltage_ln),
                ABS(pc.voltage_l2n - pc.avg_voltage_ln),
                ABS(pc.voltage_l3n - pc.avg_voltage_ln)
              ) / pc.avg_voltage_ln * 100) * 10  -- 10x penalty for unbalance
            ))
          ELSE 50 -- Partial penalty if missing phase data
        END as voltage_unbalance_score,
        
        -- Voltage THD score (equipment-specific thresholds)
        CASE 
          WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_excellent THEN 100
          WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_good THEN 90
          WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_fair THEN 75
          WHEN pc.avg_thd_voltage_ln <= (v_voltage_thd_fair * 1.5) THEN 60
          WHEN pc.avg_thd_voltage_ln <= (v_voltage_thd_fair * 2) THEN 40
          ELSE 20
        END as voltage_thd_score,
        
        -- B. CURRENT QUALITY SCORES (25% total weight)
        -- Current unbalance score
        CASE 
          WHEN pc.current_l1 > 0 AND pc.current_l2 > 0 AND pc.current_l3 > 0 AND pc.avg_current > 0 THEN
            GREATEST(0, 100 - (
              (GREATEST(
                ABS(pc.current_l1 - pc.avg_current),
                ABS(pc.current_l2 - pc.avg_current),
                ABS(pc.current_l3 - pc.avg_current)
              ) / pc.avg_current * 100) * 5  -- 5x penalty for current unbalance
            ))
          ELSE 50
        END as current_unbalance_score,
        
        -- Current THD score (equipment-specific thresholds)
        CASE 
          WHEN pc.avg_thd_current <= v_current_thd_excellent THEN 100
          WHEN pc.avg_thd_current <= v_current_thd_good THEN 90
          WHEN pc.avg_thd_current <= v_current_thd_fair THEN 75
          WHEN pc.avg_thd_current <= (v_current_thd_fair * 1.5) THEN 60
          WHEN pc.avg_thd_current <= (v_current_thd_fair * 2) THEN 40
          ELSE 20
        END as current_thd_score,
        
        -- C. POWER FACTOR QUALITY SCORES (20% total weight)
        -- Overall power factor score (equipment-specific thresholds)
        CASE 
          WHEN pc.avg_power_factor >= v_pf_excellent THEN 100
          WHEN pc.avg_power_factor >= v_pf_good THEN 90
          WHEN pc.avg_power_factor >= v_pf_fair THEN 75
          WHEN pc.avg_power_factor >= (v_pf_fair - 0.05) THEN 60
          WHEN pc.avg_power_factor >= (v_pf_fair - 0.10) THEN 40
          WHEN pc.avg_power_factor >= (v_pf_fair - 0.15) THEN 20
          ELSE 0
        END as power_factor_score,
        
        -- Power factor consistency across phases
        CASE 
          WHEN pc.power_factor_l1 > 0 AND pc.power_factor_l2 > 0 AND pc.power_factor_l3 > 0 AND pc.avg_power_factor > 0 THEN
            GREATEST(0, 100 - (
              (GREATEST(
                ABS(pc.power_factor_l1 - pc.avg_power_factor),
                ABS(pc.power_factor_l2 - pc.avg_power_factor),
                ABS(pc.power_factor_l3 - pc.avg_power_factor)
              ) / pc.avg_power_factor * 100) * 20  -- 20x penalty for PF inconsistency
            ))
          ELSE 50
        END as power_factor_consistency_score,
        
        -- D. POWER BALANCE SCORES (15% total weight)
        -- Power balance across phases
        CASE 
          WHEN pc.active_power_l1 > 0 AND pc.active_power_l2 > 0 AND pc.active_power_l3 > 0 AND pc.total_active_power > 0 THEN
            GREATEST(0, 100 - (
              (GREATEST(
                ABS(pc.active_power_l1 - (pc.total_active_power/3)),
                ABS(pc.active_power_l2 - (pc.total_active_power/3)),
                ABS(pc.active_power_l3 - (pc.total_active_power/3))
              ) / (pc.total_active_power/3) * 100) * 3  -- 3x penalty for power imbalance
            ))
          ELSE 50
        END as power_balance_score,
        
        -- E. SYSTEM EFFICIENCY SCORES (10% total weight)
        -- Apparent vs Active power efficiency
        CASE 
          WHEN pc.total_apparent_power > 0 THEN
            (pc.total_active_power / pc.total_apparent_power) * 100
          ELSE 0
        END as system_efficiency_score,
        
        -- F. HARMONIC DISTORTION IMPACT SCORE (10% total weight)
        -- Combined THD impact assessment
        CASE 
          WHEN pc.avg_thd_voltage_ln > 0 AND pc.avg_thd_current > 0 THEN
            -- Weighted combination of voltage and current THD impacts
            ((CASE 
              WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_excellent THEN 100
              WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_good THEN 90
              WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_fair THEN 75
              WHEN pc.avg_thd_voltage_ln <= (v_voltage_thd_fair * 1.5) THEN 60
              ELSE 30
            END * 0.6) + 
            (CASE 
              WHEN pc.avg_thd_current <= v_current_thd_excellent THEN 100
              WHEN pc.avg_thd_current <= v_current_thd_good THEN 80
              WHEN pc.avg_thd_current <= v_current_thd_fair THEN 60
              ELSE 30
            END * 0.4))
          ELSE 50  -- Default if THD data missing
        END as harmonic_distortion_score
        
      FROM power_calculations pc
    ),
    
    weighted_pqi AS (
      SELECT 
        pqic.device_id,
        pqic.timestamp,
        pqic.total_active_power,
        pqic.total_reactive_power,
        pqic.total_apparent_power,
        pqic.avg_voltage_ln,
        pqic.avg_voltage_ll,
        pqic.avg_current,
        pqic.avg_power_factor,
        pqic.avg_thd_voltage_ln,
        pqic.avg_thd_voltage_ll,
        pqic.avg_thd_current,
        pqic.voltage_deviation_score,
        pqic.voltage_unbalance_score,
        pqic.voltage_thd_score,
        pqic.current_unbalance_score,
        pqic.current_thd_score,
        pqic.power_factor_score,
        pqic.power_factor_consistency_score,
        pqic.power_balance_score,
        pqic.system_efficiency_score,
        pqic.harmonic_distortion_score,
        
        -- Calculate weighted category scores using function variables
        (pqic.voltage_deviation_score * v_w_voltage_deviation + pqic.voltage_unbalance_score * v_w_voltage_unbalance + pqic.voltage_thd_score * v_w_voltage_thd) as voltage_quality_category,
        (pqic.current_unbalance_score * v_w_current_unbalance + pqic.current_thd_score * v_w_current_thd) as current_quality_category,
        (pqic.power_factor_score * v_w_power_factor + pqic.power_factor_consistency_score * v_w_power_factor_consistency) as power_factor_category,
        (pqic.power_balance_score * v_w_power_balance) as power_balance_category,
        (pqic.system_efficiency_score * v_w_system_efficiency) as efficiency_category,
        (pqic.harmonic_distortion_score * v_w_harmonic_distortion) as harmonic_distortion_category
        
      FROM pqi_components pqic
    )
    
    SELECT 
      w.timestamp,
      w.device_id,
      ROUND(w.total_active_power::numeric, 2),
      ROUND(w.total_reactive_power::numeric, 2),
      ROUND(w.total_apparent_power::numeric, 2),
      ROUND(w.avg_voltage_ln::numeric, 1),
      ROUND(w.avg_voltage_ll::numeric, 1),
      ROUND(w.avg_current::numeric, 2),
      ROUND(w.avg_power_factor::numeric, 3),
      ROUND(w.avg_thd_voltage_ln::numeric, 2),
      ROUND(w.avg_thd_voltage_ll::numeric, 2),
      ROUND(w.avg_thd_current::numeric, 2),
      ROUND(w.voltage_deviation_score::numeric, 1),
      ROUND(w.voltage_unbalance_score::numeric, 1),
      ROUND(w.voltage_thd_score::numeric, 1),
      ROUND(w.current_unbalance_score::numeric, 1),
      ROUND(w.current_thd_score::numeric, 1),
      ROUND(w.power_factor_score::numeric, 1),
      ROUND(w.power_factor_consistency_score::numeric, 1),
      ROUND(w.power_balance_score::numeric, 1),
      ROUND(w.system_efficiency_score::numeric, 1),
      ROUND(w.harmonic_distortion_score::numeric, 1),
      ROUND(w.voltage_quality_category::numeric, 1),
      ROUND(w.current_quality_category::numeric, 1),
      ROUND(w.power_factor_category::numeric, 1),
      ROUND(w.power_balance_category::numeric, 1),
      ROUND(w.efficiency_category::numeric, 1),
      ROUND(w.harmonic_distortion_category::numeric, 1),
      
      -- FINAL POWER QUALITY INDEX (0-100)
      ROUND((
        w.voltage_quality_category + 
        w.current_quality_category + 
        w.power_factor_category + 
        w.power_balance_category + 
        w.efficiency_category +
        w.harmonic_distortion_category
      )::numeric, 1) as power_quality_index,
      
      -- PQI Rating Classification
      (CASE 
        WHEN (w.voltage_quality_category + w.current_quality_category + w.power_factor_category + 
              w.power_balance_category + w.efficiency_category + w.harmonic_distortion_category) >= 90 THEN 'EXCELLENT'
        WHEN (w.voltage_quality_category + w.current_quality_category + w.power_factor_category + 
              w.power_balance_category + w.efficiency_category + w.harmonic_distortion_category) >= 80 THEN 'GOOD'
        WHEN (w.voltage_quality_category + w.current_quality_category + w.power_factor_category + 
              w.power_balance_category + w.efficiency_category + w.harmonic_distortion_category) >= 70 THEN 'FAIR'
        WHEN (w.voltage_quality_category + w.current_quality_category + w.power_factor_category + 
              w.power_balance_category + w.efficiency_category + w.harmonic_distortion_category) >= 60 THEN 'POOR'
        ELSE 'CRITICAL'
      END)::VARCHAR(20) as pqi_rating,
      
      p_equipment_type as equipment_type
      
    FROM weighted_pqi w
    ORDER BY w.timestamp DESC;

END;
$$;


--
-- Name: get_power_quality_index(integer, timestamp with time zone, timestamp with time zone, character varying, numeric, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_power_quality_index(p_device_id integer, p_start_time timestamp with time zone, p_end_time timestamp with time zone, p_equipment_type character varying DEFAULT 'standard'::character varying, p_nominal_voltage numeric DEFAULT 400, p_custom_weights jsonb DEFAULT NULL::jsonb) RETURNS TABLE("timestamp" timestamp with time zone, device_id integer, total_active_power numeric, total_reactive_power numeric, total_apparent_power numeric, avg_voltage_ln numeric, avg_voltage_ll numeric, avg_current numeric, avg_power_factor numeric, avg_thd_voltage_ln numeric, avg_thd_voltage_ll numeric, avg_thd_current numeric, voltage_deviation_score numeric, voltage_unbalance_score numeric, voltage_thd_score numeric, current_unbalance_score numeric, current_thd_score numeric, power_factor_score numeric, power_factor_consistency_score numeric, power_balance_score numeric, system_efficiency_score numeric, harmonic_distortion_score numeric, voltage_quality_category numeric, current_quality_category numeric, power_factor_category numeric, power_balance_category numeric, efficiency_category numeric, harmonic_distortion_category numeric, power_quality_index numeric, pqi_rating character varying, equipment_type character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_voltage_tolerance_excellent NUMERIC;
    v_voltage_tolerance_good NUMERIC;
    v_voltage_tolerance_fair NUMERIC;
    v_voltage_thd_excellent NUMERIC;
    v_voltage_thd_good NUMERIC;
    v_voltage_thd_fair NUMERIC;
    v_current_thd_excellent NUMERIC;
    v_current_thd_good NUMERIC;
    v_current_thd_fair NUMERIC;
    v_pf_excellent NUMERIC;
    v_pf_good NUMERIC;
    v_pf_fair NUMERIC;
    
    -- Weight variables (with v_ prefix)
    v_w_voltage_deviation NUMERIC;
    v_w_voltage_unbalance NUMERIC;
    v_w_voltage_thd NUMERIC;
    v_w_current_unbalance NUMERIC;
    v_w_current_thd NUMERIC;
    v_w_power_factor NUMERIC;
    v_w_power_factor_consistency NUMERIC;
    v_w_power_balance NUMERIC;
    v_w_system_efficiency NUMERIC;
    v_w_harmonic_distortion NUMERIC;
BEGIN
    -- Set equipment-specific thresholds
    CASE p_equipment_type
        WHEN 'variable_frequency_drive' THEN
            v_voltage_tolerance_excellent := 2.0;  -- ±2% for VFDs
            v_voltage_tolerance_good := 5.0;
            v_voltage_tolerance_fair := 8.0;
            v_voltage_thd_excellent := 2.0;        -- Stricter THD for VFDs
            v_voltage_thd_good := 3.0;
            v_voltage_thd_fair := 5.0;
            v_current_thd_excellent := 8.0;
            v_current_thd_good := 12.0;
            v_current_thd_fair := 15.0;
            v_pf_excellent := 0.95;
            v_pf_good := 0.90;
            v_pf_fair := 0.85;
            
        WHEN 'server_equipment' THEN
            v_voltage_tolerance_excellent := 1.0;  -- Very strict for servers
            v_voltage_tolerance_good := 3.0;
            v_voltage_tolerance_fair := 5.0;
            v_voltage_thd_excellent := 3.0;
            v_voltage_thd_good := 5.0;
            v_voltage_thd_fair := 8.0;
            v_current_thd_excellent := 5.0;
            v_current_thd_good := 8.0;
            v_current_thd_fair := 12.0;
            v_pf_excellent := 0.90;
            v_pf_good := 0.85;
            v_pf_fair := 0.80;
            
        WHEN 'led_lighting' THEN
            v_voltage_tolerance_excellent := 5.0;  -- More tolerant
            v_voltage_tolerance_good := 8.0;
            v_voltage_tolerance_fair := 12.0;
            v_voltage_thd_excellent := 5.0;
            v_voltage_thd_good := 8.0;
            v_voltage_thd_fair := 12.0;
            v_current_thd_excellent := 15.0;
            v_current_thd_good := 20.0;
            v_current_thd_fair := 30.0;
            v_pf_excellent := 0.85;              -- LED drivers often have lower PF
            v_pf_good := 0.80;
            v_pf_fair := 0.75;
            
        WHEN 'motor_load' THEN
            v_voltage_tolerance_excellent := 3.0;
            v_voltage_tolerance_good := 5.0;
            v_voltage_tolerance_fair := 8.0;
            v_voltage_thd_excellent := 3.0;
            v_voltage_thd_good := 5.0;
            v_voltage_thd_fair := 8.0;
            v_current_thd_excellent := 8.0;
            v_current_thd_good := 12.0;
            v_current_thd_fair := 20.0;
            v_pf_excellent := 0.90;
            v_pf_good := 0.85;
            v_pf_fair := 0.80;
            
        ELSE -- 'standard' or any other type
            v_voltage_tolerance_excellent := 3.0;  -- ±3% standard
            v_voltage_tolerance_good := 5.0;
            v_voltage_tolerance_fair := 8.0;
            v_voltage_thd_excellent := 3.0;
            v_voltage_thd_good := 5.0;
            v_voltage_thd_fair := 8.0;
            v_current_thd_excellent := 5.0;
            v_current_thd_good := 8.0;
            v_current_thd_fair := 12.0;
            v_pf_excellent := 0.95;
            v_pf_good := 0.90;
            v_pf_fair := 0.85;
    END CASE;
    
    -- Set default weights (can be overridden by custom_weights)
    v_w_voltage_deviation := 0.10;
    v_w_voltage_unbalance := 0.05;
    v_w_voltage_thd := 0.05;
    v_w_current_unbalance := 0.15;
    v_w_current_thd := 0.10;
    v_w_power_factor := 0.12;
    v_w_power_factor_consistency := 0.08;
    v_w_power_balance := 0.15;
    v_w_system_efficiency := 0.10;
    v_w_harmonic_distortion := 0.10;
    
    -- Override weights if custom weights provided
    IF p_custom_weights IS NOT NULL THEN
        v_w_voltage_deviation := COALESCE((p_custom_weights->>'voltage_deviation')::NUMERIC, w_voltage_deviation);
        v_w_voltage_unbalance := COALESCE((p_custom_weights->>'voltage_unbalance')::NUMERIC, w_voltage_unbalance);
        v_w_voltage_thd := COALESCE((p_custom_weights->>'voltage_thd')::NUMERIC, w_voltage_thd);
        v_w_current_unbalance := COALESCE((p_custom_weights->>'current_unbalance')::NUMERIC, w_current_unbalance);
        v_w_current_thd := COALESCE((p_custom_weights->>'current_thd')::NUMERIC, w_current_thd);
        v_w_power_factor := COALESCE((p_custom_weights->>'power_factor')::NUMERIC, w_power_factor);
        v_w_power_factor_consistency := COALESCE((p_custom_weights->>'power_factor_consistency')::NUMERIC, w_power_factor_consistency);
        v_w_power_balance := COALESCE((p_custom_weights->>'power_balance')::NUMERIC, w_power_balance);
        v_w_system_efficiency := COALESCE((p_custom_weights->>'system_efficiency')::NUMERIC, w_system_efficiency);
        v_w_harmonic_distortion := COALESCE((p_custom_weights->>'harmonic_distortion')::NUMERIC, w_harmonic_distortion);
    END IF;
    
    -- Return the calculated PQI data
    RETURN QUERY
    WITH latest_readings AS (
      SELECT 
        td.device_id,
        td.timestamp,
        -- Active Power (3 phases)
        MAX(CASE WHEN td.quantity_id = 504 THEN td.value END) as active_power_l1,
        MAX(CASE WHEN td.quantity_id = 505 THEN td.value END) as active_power_l2,
        MAX(CASE WHEN td.quantity_id = 506 THEN td.value END) as active_power_l3,
        
        -- Reactive Power (3 phases)
        MAX(CASE WHEN td.quantity_id = 507 THEN td.value END) as reactive_power_l1,
        MAX(CASE WHEN td.quantity_id = 508 THEN td.value END) as reactive_power_l2,
        MAX(CASE WHEN td.quantity_id = 509 THEN td.value END) as reactive_power_l3,
        
        -- Apparent Power (3 phases)
        MAX(CASE WHEN td.quantity_id = 510 THEN td.value END) as apparent_power_l1,
        MAX(CASE WHEN td.quantity_id = 511 THEN td.value END) as apparent_power_l2,
        MAX(CASE WHEN td.quantity_id = 512 THEN td.value END) as apparent_power_l3,
        
        -- Voltage Line to Line
        MAX(CASE WHEN td.quantity_id = 1057 THEN td.value END) as voltage_l1l2,
        MAX(CASE WHEN td.quantity_id = 1058 THEN td.value END) as voltage_l2l3,
        MAX(CASE WHEN td.quantity_id = 1059 THEN td.value END) as voltage_l3l1,
        
        -- Voltage Line to Neutral
        MAX(CASE WHEN td.quantity_id = 1060 THEN td.value END) as voltage_l1n,
        MAX(CASE WHEN td.quantity_id = 1061 THEN td.value END) as voltage_l2n,
        MAX(CASE WHEN td.quantity_id = 1062 THEN td.value END) as voltage_l3n,
        
        -- Current (3 phases)
        MAX(CASE WHEN td.quantity_id = 501 THEN td.value END) as current_l1,
        MAX(CASE WHEN td.quantity_id = 502 THEN td.value END) as current_l2,
        MAX(CASE WHEN td.quantity_id = 503 THEN td.value END) as current_l3,
        
        -- Power Factor (3 phases)
        MAX(CASE WHEN td.quantity_id = 3325 THEN td.value END) as power_factor_l1,
        MAX(CASE WHEN td.quantity_id = 3326 THEN td.value END) as power_factor_l2,
        MAX(CASE WHEN td.quantity_id = 3327 THEN td.value END) as power_factor_l3,
		MAX(CASE WHEN td.quantity_id = 1072 THEN td.value END) as power_factor_total,
		
        -- Total Harmonic Distortion - Voltage Line to Line
        MAX(CASE WHEN td.quantity_id = 2034 THEN td.value END) as thd_v_l1l2,
        MAX(CASE WHEN td.quantity_id = 2036 THEN td.value END) as thd_v_l2l3,
        MAX(CASE WHEN td.quantity_id = 2038 THEN td.value END) as thd_v_l3l1,
        
        -- Total Harmonic Distortion - Voltage Line to Neutral
        MAX(CASE WHEN td.quantity_id = 2035 THEN td.value END) as thd_v_l1n,
        MAX(CASE WHEN td.quantity_id = 2037 THEN td.value END) as thd_v_l2n,
        MAX(CASE WHEN td.quantity_id = 2039 THEN td.value END) as thd_v_l3n,
        
        -- Total Harmonic Distortion - Current
        MAX(CASE WHEN td.quantity_id = 2097 THEN td.value END) as thd_i_l1,
        MAX(CASE WHEN td.quantity_id = 2098 THEN td.value END) as thd_i_l2,
        MAX(CASE WHEN td.quantity_id = 2099 THEN td.value END) as thd_i_l3
        
      FROM telemetry_data td
      WHERE td.device_id = p_device_id
        AND td.timestamp >= p_start_time
        AND td.timestamp <= p_end_time
      GROUP BY td.device_id, td.timestamp
    ),
    
    power_calculations AS (
      SELECT 
        *,
        -- Total Power Values
        (COALESCE(active_power_l1, 0) + COALESCE(active_power_l2, 0) + COALESCE(active_power_l3, 0)) as total_active_power,
        (COALESCE(reactive_power_l1, 0) + COALESCE(reactive_power_l2, 0) + COALESCE(reactive_power_l3, 0)) as total_reactive_power,
        (COALESCE(apparent_power_l1, 0) + COALESCE(apparent_power_l2, 0) + COALESCE(apparent_power_l3, 0)) as total_apparent_power,
        
        -- Average Voltage Calculations
        (COALESCE(voltage_l1n, 0) + COALESCE(voltage_l2n, 0) + COALESCE(voltage_l3n, 0)) / 3.0 as avg_voltage_ln,
        (COALESCE(voltage_l1l2, 0) + COALESCE(voltage_l2l3, 0) + COALESCE(voltage_l3l1, 0)) / 3.0 as avg_voltage_ll,
        
        -- Average Current (3 phases only)
        (COALESCE(current_l1, 0) + COALESCE(current_l2, 0) + COALESCE(current_l3, 0)) / 3.0 as avg_current,
        
        -- Average Power Factor
		CASE 
		  WHEN power_factor_l1 IS NOT NULL OR power_factor_l2 IS NOT NULL OR power_factor_l3 IS NOT NULL THEN
		    -- Use per-phase average when available
		    (COALESCE(power_factor_l1, 0) + COALESCE(power_factor_l2, 0) + COALESCE(power_factor_l3, 0)) / 
		    GREATEST(1, (CASE WHEN power_factor_l1 IS NOT NULL THEN 1 ELSE 0 END + 
		                 CASE WHEN power_factor_l2 IS NOT NULL THEN 1 ELSE 0 END + 
		                 CASE WHEN power_factor_l3 IS NOT NULL THEN 1 ELSE 0 END))
		  ELSE 
		    -- Fallback to overall power factor
		    COALESCE(power_factor_total, 0)
		END as avg_power_factor,       
		
        -- Average THD Calculations
        (COALESCE(thd_v_l1n, 0) + COALESCE(thd_v_l2n, 0) + COALESCE(thd_v_l3n, 0)) / 3.0 as avg_thd_voltage_ln,
        (COALESCE(thd_v_l1l2, 0) + COALESCE(thd_v_l2l3, 0) + COALESCE(thd_v_l3l1, 0)) / 3.0 as avg_thd_voltage_ll,
        (COALESCE(thd_i_l1, 0) + COALESCE(thd_i_l2, 0) + COALESCE(thd_i_l3, 0)) / 3.0 as avg_thd_current
        
      FROM latest_readings
    ),
    
    pqi_components AS (
      SELECT 
        pc.*,
        
        -- A. VOLTAGE QUALITY SCORES (20% total weight)
        -- Voltage deviation from nominal (using parameter)
        CASE 
          WHEN pc.avg_voltage_ln BETWEEN (p_nominal_voltage * (1 - v_voltage_tolerance_excellent/100)) 
                                  AND (p_nominal_voltage * (1 + v_voltage_tolerance_excellent/100)) THEN 100
          WHEN pc.avg_voltage_ln BETWEEN (p_nominal_voltage * (1 - v_voltage_tolerance_good/100)) 
                                  AND (p_nominal_voltage * (1 + v_voltage_tolerance_good/100)) THEN 
            90 - (ABS(pc.avg_voltage_ln - p_nominal_voltage) / p_nominal_voltage * 100 * 2)
          WHEN pc.avg_voltage_ln BETWEEN (p_nominal_voltage * (1 - v_voltage_tolerance_fair/100)) 
                                  AND (p_nominal_voltage * (1 + v_voltage_tolerance_fair/100)) THEN 
            70 - (ABS(pc.avg_voltage_ln - p_nominal_voltage) / p_nominal_voltage * 100)
          ELSE 0
        END as voltage_deviation_score,
        
        -- Voltage unbalance score (Line-to-Neutral)
        CASE 
          WHEN pc.voltage_l1n > 0 AND pc.voltage_l2n > 0 AND pc.voltage_l3n > 0 AND pc.avg_voltage_ln > 0 THEN
            GREATEST(0, 100 - (
              (GREATEST(
                ABS(pc.voltage_l1n - pc.avg_voltage_ln),
                ABS(pc.voltage_l2n - pc.avg_voltage_ln),
                ABS(pc.voltage_l3n - pc.avg_voltage_ln)
              ) / pc.avg_voltage_ln * 100) * 10  -- 10x penalty for unbalance
            ))
          ELSE 50 -- Partial penalty if missing phase data
        END as voltage_unbalance_score,
        
        -- Voltage THD score (equipment-specific thresholds)
        CASE 
          WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_excellent THEN 100
          WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_good THEN 90
          WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_fair THEN 75
          WHEN pc.avg_thd_voltage_ln <= (v_voltage_thd_fair * 1.5) THEN 60
          WHEN pc.avg_thd_voltage_ln <= (v_voltage_thd_fair * 2) THEN 40
          ELSE 20
        END as voltage_thd_score,
        
        -- B. CURRENT QUALITY SCORES (25% total weight)
        -- Current unbalance score
        CASE 
          WHEN pc.current_l1 > 0 AND pc.current_l2 > 0 AND pc.current_l3 > 0 AND pc.avg_current > 0 THEN
            GREATEST(0, 100 - (
              (GREATEST(
                ABS(pc.current_l1 - pc.avg_current),
                ABS(pc.current_l2 - pc.avg_current),
                ABS(pc.current_l3 - pc.avg_current)
              ) / pc.avg_current * 100) * 5  -- 5x penalty for current unbalance
            ))
          ELSE 50
        END as current_unbalance_score,
        
        -- Current THD score (equipment-specific thresholds)
        CASE 
          WHEN pc.avg_thd_current <= v_current_thd_excellent THEN 100
          WHEN pc.avg_thd_current <= v_current_thd_good THEN 90
          WHEN pc.avg_thd_current <= v_current_thd_fair THEN 75
          WHEN pc.avg_thd_current <= (v_current_thd_fair * 1.5) THEN 60
          WHEN pc.avg_thd_current <= (v_current_thd_fair * 2) THEN 40
          ELSE 20
        END as current_thd_score,
        
        -- C. POWER FACTOR QUALITY SCORES (20% total weight)
        -- Overall power factor score (equipment-specific thresholds)
        CASE 
          WHEN pc.avg_power_factor >= v_pf_excellent THEN 100
          WHEN pc.avg_power_factor >= v_pf_good THEN 90
          WHEN pc.avg_power_factor >= v_pf_fair THEN 75
          WHEN pc.avg_power_factor >= (v_pf_fair - 0.05) THEN 60
          WHEN pc.avg_power_factor >= (v_pf_fair - 0.10) THEN 40
          WHEN pc.avg_power_factor >= (v_pf_fair - 0.15) THEN 20
          ELSE 0
        END as power_factor_score,
        
        -- Power factor consistency across phases
		CASE 
		  WHEN pc.power_factor_l1 IS NOT NULL AND pc.power_factor_l2 IS NOT NULL AND pc.power_factor_l3 IS NOT NULL AND pc.avg_power_factor != 0 THEN
		    -- Calculate consistency only when all phases available
		    GREATEST(0, 100 - (
		      (GREATEST(
		        ABS(pc.power_factor_l1 - pc.avg_power_factor),
		        ABS(pc.power_factor_l2 - pc.avg_power_factor),
		        ABS(pc.power_factor_l3 - pc.avg_power_factor)
		      ) / ABS(pc.avg_power_factor) * 100) * 20  -- 20x penalty for PF inconsistency
		    ))
		  ELSE 
		    -- Give full score when using overall PF (no consistency to measure)
		    100
		END as power_factor_consistency_score,
		
        -- D. POWER BALANCE SCORES (15% total weight)
        -- Power balance across phases
        CASE 
          WHEN pc.active_power_l1 > 0 AND pc.active_power_l2 > 0 AND pc.active_power_l3 > 0 AND pc.total_active_power > 0 THEN
            GREATEST(0, 100 - (
              (GREATEST(
                ABS(pc.active_power_l1 - (pc.total_active_power/3)),
                ABS(pc.active_power_l2 - (pc.total_active_power/3)),
                ABS(pc.active_power_l3 - (pc.total_active_power/3))
              ) / (pc.total_active_power/3) * 100) * 3  -- 3x penalty for power imbalance
            ))
          ELSE 50
        END as power_balance_score,
        
        -- E. SYSTEM EFFICIENCY SCORES (10% total weight)
        -- Apparent vs Active power efficiency
        CASE 
          WHEN pc.total_apparent_power > 0 THEN
            (pc.total_active_power / pc.total_apparent_power) * 100
          ELSE 0
        END as system_efficiency_score,
        
        -- F. HARMONIC DISTORTION IMPACT SCORE (10% total weight)
        -- Combined THD impact assessment
        CASE 
          WHEN pc.avg_thd_voltage_ln > 0 AND pc.avg_thd_current > 0 THEN
            -- Weighted combination of voltage and current THD impacts
            ((CASE 
              WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_excellent THEN 100
              WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_good THEN 90
              WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_fair THEN 75
              WHEN pc.avg_thd_voltage_ln <= (v_voltage_thd_fair * 1.5) THEN 60
              ELSE 30
            END * 0.6) + 
            (CASE 
              WHEN pc.avg_thd_current <= v_current_thd_excellent THEN 100
              WHEN pc.avg_thd_current <= v_current_thd_good THEN 80
              WHEN pc.avg_thd_current <= v_current_thd_fair THEN 60
              ELSE 30
            END * 0.4))
          ELSE 50  -- Default if THD data missing
        END as harmonic_distortion_score
        
      FROM power_calculations pc
    ),
    
    weighted_pqi AS (
      SELECT 
        pqic.device_id,
        pqic.timestamp,
        pqic.total_active_power,
        pqic.total_reactive_power,
        pqic.total_apparent_power,
        pqic.avg_voltage_ln,
        pqic.avg_voltage_ll,
        pqic.avg_current,
        pqic.avg_power_factor,
        pqic.avg_thd_voltage_ln,
        pqic.avg_thd_voltage_ll,
        pqic.avg_thd_current,
        pqic.voltage_deviation_score,
        pqic.voltage_unbalance_score,
        pqic.voltage_thd_score,
        pqic.current_unbalance_score,
        pqic.current_thd_score,
        pqic.power_factor_score,
        pqic.power_factor_consistency_score,
        pqic.power_balance_score,
        pqic.system_efficiency_score,
        pqic.harmonic_distortion_score,
        
        -- Calculate weighted category scores using function variables
        (pqic.voltage_deviation_score * v_w_voltage_deviation + pqic.voltage_unbalance_score * v_w_voltage_unbalance + pqic.voltage_thd_score * v_w_voltage_thd) as voltage_quality_category,
        (pqic.current_unbalance_score * v_w_current_unbalance + pqic.current_thd_score * v_w_current_thd) as current_quality_category,
        (pqic.power_factor_score * v_w_power_factor + pqic.power_factor_consistency_score * v_w_power_factor_consistency) as power_factor_category,
        (pqic.power_balance_score * v_w_power_balance) as power_balance_category,
        (pqic.system_efficiency_score * v_w_system_efficiency) as efficiency_category,
        (pqic.harmonic_distortion_score * v_w_harmonic_distortion) as harmonic_distortion_category
        
      FROM pqi_components pqic
    )
    
    SELECT 
      w.timestamp::TIMESTAMP WITH TIME ZONE,
      w.device_id,
      ROUND(w.total_active_power::numeric, 2),
      ROUND(w.total_reactive_power::numeric, 2),
      ROUND(w.total_apparent_power::numeric, 2),
      ROUND(w.avg_voltage_ln::numeric, 1),
      ROUND(w.avg_voltage_ll::numeric, 1),
      ROUND(w.avg_current::numeric, 2),
      ROUND(w.avg_power_factor::numeric, 3),
      ROUND(w.avg_thd_voltage_ln::numeric, 2),
      ROUND(w.avg_thd_voltage_ll::numeric, 2),
      ROUND(w.avg_thd_current::numeric, 2),
      ROUND(w.voltage_deviation_score::numeric, 1),
      ROUND(w.voltage_unbalance_score::numeric, 1),
      ROUND(w.voltage_thd_score::numeric, 1),
      ROUND(w.current_unbalance_score::numeric, 1),
      ROUND(w.current_thd_score::numeric, 1),
      ROUND(w.power_factor_score::numeric, 1),
      ROUND(w.power_factor_consistency_score::numeric, 1),
      ROUND(w.power_balance_score::numeric, 1),
      ROUND(w.system_efficiency_score::numeric, 1),
      ROUND(w.harmonic_distortion_score::numeric, 1),
      ROUND(w.voltage_quality_category::numeric, 1),
      ROUND(w.current_quality_category::numeric, 1),
      ROUND(w.power_factor_category::numeric, 1),
      ROUND(w.power_balance_category::numeric, 1),
      ROUND(w.efficiency_category::numeric, 1),
      ROUND(w.harmonic_distortion_category::numeric, 1),
      
      -- FINAL POWER QUALITY INDEX (0-100)
      ROUND((
        w.voltage_quality_category + 
        w.current_quality_category + 
        w.power_factor_category + 
        w.power_balance_category + 
        w.efficiency_category +
        w.harmonic_distortion_category
      )::numeric, 1) as power_quality_index,
      
      -- PQI Rating Classification
      (CASE 
        WHEN (w.voltage_quality_category + w.current_quality_category + w.power_factor_category + 
              w.power_balance_category + w.efficiency_category + w.harmonic_distortion_category) >= 90 THEN 'EXCELLENT'
        WHEN (w.voltage_quality_category + w.current_quality_category + w.power_factor_category + 
              w.power_balance_category + w.efficiency_category + w.harmonic_distortion_category) >= 80 THEN 'GOOD'
        WHEN (w.voltage_quality_category + w.current_quality_category + w.power_factor_category + 
              w.power_balance_category + w.efficiency_category + w.harmonic_distortion_category) >= 70 THEN 'FAIR'
        WHEN (w.voltage_quality_category + w.current_quality_category + w.power_factor_category + 
              w.power_balance_category + w.efficiency_category + w.harmonic_distortion_category) >= 60 THEN 'POOR'
        ELSE 'CRITICAL'
      END)::VARCHAR(20) as pqi_rating,
      
      p_equipment_type as equipment_type
      
    FROM weighted_pqi w
    ORDER BY w.timestamp DESC;

END;
$$;


--
-- Name: get_power_quality_index(integer, integer[], timestamp with time zone, timestamp with time zone, character varying, numeric, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_power_quality_index(p_tenant_id integer, p_device_ids integer[], p_start_time timestamp with time zone, p_end_time timestamp with time zone, p_equipment_type character varying DEFAULT 'standard'::character varying, p_nominal_voltage numeric DEFAULT 230, p_custom_weights jsonb DEFAULT NULL::jsonb) RETURNS TABLE(device_id integer, device_name character varying, "timestamp" timestamp with time zone, total_active_power numeric, total_reactive_power numeric, total_apparent_power numeric, avg_voltage_ln numeric, avg_voltage_ll numeric, avg_current numeric, avg_power_factor numeric, avg_thd_voltage_ln numeric, avg_thd_voltage_ll numeric, avg_thd_current numeric, voltage_deviation_score numeric, voltage_unbalance_score numeric, voltage_thd_score numeric, current_unbalance_score numeric, current_thd_score numeric, power_factor_score numeric, power_factor_consistency_score numeric, power_balance_score numeric, system_efficiency_score numeric, harmonic_distortion_score numeric, voltage_quality_category numeric, current_quality_category numeric, power_factor_category numeric, power_balance_category numeric, efficiency_category numeric, harmonic_distortion_category numeric, power_quality_index numeric, pqi_rating character varying, equipment_type character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    -- Equipment-specific thresholds
    v_voltage_tolerance_excellent NUMERIC;
    v_voltage_tolerance_good NUMERIC;
    v_voltage_tolerance_fair NUMERIC;
    v_voltage_thd_excellent NUMERIC;
    v_voltage_thd_good NUMERIC;
    v_voltage_thd_fair NUMERIC;
    v_current_thd_excellent NUMERIC;
    v_current_thd_good NUMERIC;
    v_current_thd_fair NUMERIC;
    v_pf_excellent NUMERIC;
    v_pf_good NUMERIC;
    v_pf_fair NUMERIC;
    
    -- Weight variables
    v_w_voltage_deviation NUMERIC;
    v_w_voltage_unbalance NUMERIC;
    v_w_voltage_thd NUMERIC;
    v_w_current_unbalance NUMERIC;
    v_w_current_thd NUMERIC;
    v_w_power_factor NUMERIC;
    v_w_power_factor_consistency NUMERIC;
    v_w_power_balance NUMERIC;
    v_w_system_efficiency NUMERIC;
    v_w_harmonic_distortion NUMERIC;
BEGIN
    -- Set equipment-specific thresholds
    CASE p_equipment_type
        WHEN 'variable_frequency_drive' THEN
            v_voltage_tolerance_excellent := 2.0;
            v_voltage_tolerance_good := 5.0;
            v_voltage_tolerance_fair := 8.0;
            v_voltage_thd_excellent := 2.0;
            v_voltage_thd_good := 3.0;
            v_voltage_thd_fair := 5.0;
            v_current_thd_excellent := 8.0;
            v_current_thd_good := 12.0;
            v_current_thd_fair := 15.0;
            v_pf_excellent := 0.95;
            v_pf_good := 0.90;
            v_pf_fair := 0.85;
            
        WHEN 'server_equipment' THEN
            v_voltage_tolerance_excellent := 1.0;
            v_voltage_tolerance_good := 3.0;
            v_voltage_tolerance_fair := 5.0;
            v_voltage_thd_excellent := 3.0;
            v_voltage_thd_good := 5.0;
            v_voltage_thd_fair := 8.0;
            v_current_thd_excellent := 5.0;
            v_current_thd_good := 8.0;
            v_current_thd_fair := 12.0;
            v_pf_excellent := 0.90;
            v_pf_good := 0.85;
            v_pf_fair := 0.80;
            
        WHEN 'led_lighting' THEN
            v_voltage_tolerance_excellent := 5.0;
            v_voltage_tolerance_good := 8.0;
            v_voltage_tolerance_fair := 12.0;
            v_voltage_thd_excellent := 5.0;
            v_voltage_thd_good := 8.0;
            v_voltage_thd_fair := 12.0;
            v_current_thd_excellent := 15.0;
            v_current_thd_good := 20.0;
            v_current_thd_fair := 30.0;
            v_pf_excellent := 0.85;
            v_pf_good := 0.80;
            v_pf_fair := 0.75;
            
        WHEN 'motor_load' THEN
            v_voltage_tolerance_excellent := 3.0;
            v_voltage_tolerance_good := 5.0;
            v_voltage_tolerance_fair := 8.0;
            v_voltage_thd_excellent := 3.0;
            v_voltage_thd_good := 5.0;
            v_voltage_thd_fair := 8.0;
            v_current_thd_excellent := 8.0;
            v_current_thd_good := 12.0;
            v_current_thd_fair := 20.0;
            v_pf_excellent := 0.90;
            v_pf_good := 0.85;
            v_pf_fair := 0.80;
            
        WHEN 'medium_voltage' THEN
            v_voltage_tolerance_excellent := 2.0;
            v_voltage_tolerance_good := 5.0;
            v_voltage_tolerance_fair := 8.0;
            v_voltage_thd_excellent := 2.0;
            v_voltage_thd_good := 3.0;
            v_voltage_thd_fair := 5.0;
            v_current_thd_excellent := 5.0;
            v_current_thd_good := 8.0;
            v_current_thd_fair := 12.0;
            v_pf_excellent := 0.95;
            v_pf_good := 0.90;
            v_pf_fair := 0.85;
            
        WHEN 'mixed_distribution' THEN
            v_voltage_tolerance_excellent := 5.0;
            v_voltage_tolerance_good := 8.0;
            v_voltage_tolerance_fair := 12.0;
            v_voltage_thd_excellent := 5.0;
            v_voltage_thd_good := 8.0;
            v_voltage_thd_fair := 12.0;
            v_current_thd_excellent := 15.0;
            v_current_thd_good := 20.0;
            v_current_thd_fair := 30.0;
            v_pf_excellent := 0.85;
            v_pf_good := 0.80;
            v_pf_fair := 0.75;
            
        ELSE -- 'standard' or any other type
            v_voltage_tolerance_excellent := 3.0;
            v_voltage_tolerance_good := 5.0;
            v_voltage_tolerance_fair := 8.0;
            v_voltage_thd_excellent := 3.0;
            v_voltage_thd_good := 5.0;
            v_voltage_thd_fair := 8.0;
            v_current_thd_excellent := 5.0;
            v_current_thd_good := 8.0;
            v_current_thd_fair := 12.0;
            v_pf_excellent := 0.95;
            v_pf_good := 0.90;
            v_pf_fair := 0.85;
    END CASE;
    
    -- Set default weights
    v_w_voltage_deviation := 0.10;
    v_w_voltage_unbalance := 0.05;
    v_w_voltage_thd := 0.05;
    v_w_current_unbalance := 0.15;
    v_w_current_thd := 0.10;
    v_w_power_factor := 0.12;
    v_w_power_factor_consistency := 0.08;
    v_w_power_balance := 0.15;
    v_w_system_efficiency := 0.10;
    v_w_harmonic_distortion := 0.10;
    
    -- Override weights if custom weights provided
    IF p_custom_weights IS NOT NULL THEN
        v_w_voltage_deviation := COALESCE((p_custom_weights->>'voltage_deviation')::NUMERIC, v_w_voltage_deviation);
        v_w_voltage_unbalance := COALESCE((p_custom_weights->>'voltage_unbalance')::NUMERIC, v_w_voltage_unbalance);
        v_w_voltage_thd := COALESCE((p_custom_weights->>'voltage_thd')::NUMERIC, v_w_voltage_thd);
        v_w_current_unbalance := COALESCE((p_custom_weights->>'current_unbalance')::NUMERIC, v_w_current_unbalance);
        v_w_current_thd := COALESCE((p_custom_weights->>'current_thd')::NUMERIC, v_w_current_thd);
        v_w_power_factor := COALESCE((p_custom_weights->>'power_factor')::NUMERIC, v_w_power_factor);
        v_w_power_factor_consistency := COALESCE((p_custom_weights->>'power_factor_consistency')::NUMERIC, v_w_power_factor_consistency);
        v_w_power_balance := COALESCE((p_custom_weights->>'power_balance')::NUMERIC, v_w_power_balance);
        v_w_system_efficiency := COALESCE((p_custom_weights->>'system_efficiency')::NUMERIC, v_w_system_efficiency);
        v_w_harmonic_distortion := COALESCE((p_custom_weights->>'harmonic_distortion')::NUMERIC, v_w_harmonic_distortion);
    END IF;
    
    -- Return the calculated PQI data
    RETURN QUERY
    WITH latest_readings AS (
      SELECT 
        td.device_id,
        td.timestamp,
        d.device_name,
        -- Active Power (3 phases)
        MAX(CASE WHEN td.quantity_id = 504 THEN td.value END) as active_power_l1,
        MAX(CASE WHEN td.quantity_id = 505 THEN td.value END) as active_power_l2,
        MAX(CASE WHEN td.quantity_id = 506 THEN td.value END) as active_power_l3,
        
        -- Reactive Power (3 phases)
        MAX(CASE WHEN td.quantity_id = 507 THEN td.value END) as reactive_power_l1,
        MAX(CASE WHEN td.quantity_id = 508 THEN td.value END) as reactive_power_l2,
        MAX(CASE WHEN td.quantity_id = 509 THEN td.value END) as reactive_power_l3,
        
        -- Apparent Power (3 phases)
        MAX(CASE WHEN td.quantity_id = 510 THEN td.value END) as apparent_power_l1,
        MAX(CASE WHEN td.quantity_id = 511 THEN td.value END) as apparent_power_l2,
        MAX(CASE WHEN td.quantity_id = 512 THEN td.value END) as apparent_power_l3,
        
        -- Voltage Line to Line
        MAX(CASE WHEN td.quantity_id = 1057 THEN td.value END) as voltage_l1l2,
        MAX(CASE WHEN td.quantity_id = 1058 THEN td.value END) as voltage_l2l3,
        MAX(CASE WHEN td.quantity_id = 1059 THEN td.value END) as voltage_l3l1,
        
        -- Voltage Line to Neutral
        MAX(CASE WHEN td.quantity_id = 1060 THEN td.value END) as voltage_l1n,
        MAX(CASE WHEN td.quantity_id = 1061 THEN td.value END) as voltage_l2n,
        MAX(CASE WHEN td.quantity_id = 1062 THEN td.value END) as voltage_l3n,
        
        -- Current (3 phases)
        MAX(CASE WHEN td.quantity_id = 501 THEN td.value END) as current_l1,
        MAX(CASE WHEN td.quantity_id = 502 THEN td.value END) as current_l2,
        MAX(CASE WHEN td.quantity_id = 503 THEN td.value END) as current_l3,
        
        -- Power Factor (3 phases)
        MAX(CASE WHEN td.quantity_id = 3325 THEN td.value END) as power_factor_l1,
        MAX(CASE WHEN td.quantity_id = 3326 THEN td.value END) as power_factor_l2,
        MAX(CASE WHEN td.quantity_id = 3327 THEN td.value END) as power_factor_l3,
        
        -- Overall/True Power Factor
        MAX(CASE WHEN td.quantity_id = 1072 THEN td.value END) as power_factor_total,
        
        -- Total Harmonic Distortion - Voltage Line to Line
        MAX(CASE WHEN td.quantity_id = 2034 THEN td.value END) as thd_v_l1l2,
        MAX(CASE WHEN td.quantity_id = 2036 THEN td.value END) as thd_v_l2l3,
        MAX(CASE WHEN td.quantity_id = 2038 THEN td.value END) as thd_v_l3l1,
        
        -- Total Harmonic Distortion - Voltage Line to Neutral
        MAX(CASE WHEN td.quantity_id = 2035 THEN td.value END) as thd_v_l1n,
        MAX(CASE WHEN td.quantity_id = 2037 THEN td.value END) as thd_v_l2n,
        MAX(CASE WHEN td.quantity_id = 2039 THEN td.value END) as thd_v_l3n,
        
        -- Total Harmonic Distortion - Current
        MAX(CASE WHEN td.quantity_id = 2097 THEN td.value END) as thd_i_l1,
        MAX(CASE WHEN td.quantity_id = 2098 THEN td.value END) as thd_i_l2,
        MAX(CASE WHEN td.quantity_id = 2099 THEN td.value END) as thd_i_l3
        
      FROM telemetry_data td
      JOIN devices d ON td.device_id = d.id
      WHERE td.tenant_id = p_tenant_id
        AND td.device_id = ANY(p_device_ids)
        AND d.tenant_id = p_tenant_id
        AND d.is_active = true
        AND td.timestamp >= p_start_time
        AND td.timestamp <= p_end_time
      GROUP BY td.device_id, td.timestamp, d.device_name
    ),
    
    power_calculations AS (
      SELECT 
        lr.*,
        -- Total Power Values
        (COALESCE(lr.active_power_l1, 0) + COALESCE(lr.active_power_l2, 0) + COALESCE(lr.active_power_l3, 0)) as total_active_power,
        (COALESCE(lr.reactive_power_l1, 0) + COALESCE(lr.reactive_power_l2, 0) + COALESCE(lr.reactive_power_l3, 0)) as total_reactive_power,
        (COALESCE(lr.apparent_power_l1, 0) + COALESCE(lr.apparent_power_l2, 0) + COALESCE(lr.apparent_power_l3, 0)) as total_apparent_power,
        
        -- Average Voltage Calculations
        (COALESCE(lr.voltage_l1n, 0) + COALESCE(lr.voltage_l2n, 0) + COALESCE(lr.voltage_l3n, 0)) / 3.0 as avg_voltage_ln,
        (COALESCE(lr.voltage_l1l2, 0) + COALESCE(lr.voltage_l2l3, 0) + COALESCE(lr.voltage_l3l1, 0)) / 3.0 as avg_voltage_ll,
        
        -- Average Current (3 phases only)
        (COALESCE(lr.current_l1, 0) + COALESCE(lr.current_l2, 0) + COALESCE(lr.current_l3, 0)) / 3.0 as avg_current,
        
        -- Average Power Factor (with fallback to overall PF)
        CASE 
          WHEN lr.power_factor_l1 IS NOT NULL OR lr.power_factor_l2 IS NOT NULL OR lr.power_factor_l3 IS NOT NULL THEN
            (COALESCE(lr.power_factor_l1, 0) + COALESCE(lr.power_factor_l2, 0) + COALESCE(lr.power_factor_l3, 0)) / 
            GREATEST(1, (CASE WHEN lr.power_factor_l1 IS NOT NULL THEN 1 ELSE 0 END + 
                         CASE WHEN lr.power_factor_l2 IS NOT NULL THEN 1 ELSE 0 END + 
                         CASE WHEN lr.power_factor_l3 IS NOT NULL THEN 1 ELSE 0 END))
          ELSE 
            COALESCE(lr.power_factor_total, 0)
        END as avg_power_factor,
        
        -- Average THD Calculations
        (COALESCE(lr.thd_v_l1n, 0) + COALESCE(lr.thd_v_l2n, 0) + COALESCE(lr.thd_v_l3n, 0)) / 3.0 as avg_thd_voltage_ln,
        (COALESCE(lr.thd_v_l1l2, 0) + COALESCE(lr.thd_v_l2l3, 0) + COALESCE(lr.thd_v_l3l1, 0)) / 3.0 as avg_thd_voltage_ll,
        (COALESCE(lr.thd_i_l1, 0) + COALESCE(lr.thd_i_l2, 0) + COALESCE(lr.thd_i_l3, 0)) / 3.0 as avg_thd_current
        
      FROM latest_readings lr
    ),
    
    pqi_components AS (
      SELECT 
        pc.*,
        
        -- A. VOLTAGE QUALITY SCORES (20% total weight)
        CASE 
          WHEN pc.avg_voltage_ln BETWEEN (p_nominal_voltage * (1 - v_voltage_tolerance_excellent/100)) 
                                  AND (p_nominal_voltage * (1 + v_voltage_tolerance_excellent/100)) THEN 100
          WHEN pc.avg_voltage_ln BETWEEN (p_nominal_voltage * (1 - v_voltage_tolerance_good/100)) 
                                  AND (p_nominal_voltage * (1 + v_voltage_tolerance_good/100)) THEN 
            90 - (ABS(pc.avg_voltage_ln - p_nominal_voltage) / p_nominal_voltage * 100 * 2)
          WHEN pc.avg_voltage_ln BETWEEN (p_nominal_voltage * (1 - v_voltage_tolerance_fair/100)) 
                                  AND (p_nominal_voltage * (1 + v_voltage_tolerance_fair/100)) THEN 
            70 - (ABS(pc.avg_voltage_ln - p_nominal_voltage) / p_nominal_voltage * 100)
          ELSE 0
        END as voltage_deviation_score,
        
        CASE 
          WHEN pc.voltage_l1n > 0 AND pc.voltage_l2n > 0 AND pc.voltage_l3n > 0 AND pc.avg_voltage_ln > 0 THEN
            GREATEST(0, 100 - (
              (GREATEST(
                ABS(pc.voltage_l1n - pc.avg_voltage_ln),
                ABS(pc.voltage_l2n - pc.avg_voltage_ln),
                ABS(pc.voltage_l3n - pc.avg_voltage_ln)
              ) / pc.avg_voltage_ln * 100) * 10
            ))
          ELSE 50
        END as voltage_unbalance_score,
        
        CASE 
          WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_excellent THEN 100
          WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_good THEN 90
          WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_fair THEN 75
          WHEN pc.avg_thd_voltage_ln <= (v_voltage_thd_fair * 1.5) THEN 60
          WHEN pc.avg_thd_voltage_ln <= (v_voltage_thd_fair * 2) THEN 40
          ELSE 20
        END as voltage_thd_score,
        
        -- B. CURRENT QUALITY SCORES (25% total weight)
        CASE 
          WHEN pc.current_l1 > 0 AND pc.current_l2 > 0 AND pc.current_l3 > 0 AND pc.avg_current > 0 THEN
            GREATEST(0, 100 - (
              (GREATEST(
                ABS(pc.current_l1 - pc.avg_current),
                ABS(pc.current_l2 - pc.avg_current),
                ABS(pc.current_l3 - pc.avg_current)
              ) / pc.avg_current * 100) * 5
            ))
          ELSE 50
        END as current_unbalance_score,
        
        CASE 
          WHEN pc.avg_thd_current <= v_current_thd_excellent THEN 100
          WHEN pc.avg_thd_current <= v_current_thd_good THEN 90
          WHEN pc.avg_thd_current <= v_current_thd_fair THEN 75
          WHEN pc.avg_thd_current <= (v_current_thd_fair * 1.5) THEN 60
          WHEN pc.avg_thd_current <= (v_current_thd_fair * 2) THEN 40
          ELSE 20
        END as current_thd_score,
        
        -- C. POWER FACTOR QUALITY SCORES (20% total weight)
        CASE 
          WHEN pc.avg_power_factor >= v_pf_excellent THEN 100
          WHEN pc.avg_power_factor >= v_pf_good THEN 90
          WHEN pc.avg_power_factor >= v_pf_fair THEN 75
          WHEN pc.avg_power_factor >= (v_pf_fair - 0.05) THEN 60
          WHEN pc.avg_power_factor >= (v_pf_fair - 0.10) THEN 40
          WHEN pc.avg_power_factor >= (v_pf_fair - 0.15) THEN 20
          ELSE 0
        END as power_factor_score,
        
        CASE 
          WHEN pc.power_factor_l1 IS NOT NULL AND pc.power_factor_l2 IS NOT NULL AND pc.power_factor_l3 IS NOT NULL AND pc.avg_power_factor != 0 THEN
            GREATEST(0, 100 - (
              (GREATEST(
                ABS(pc.power_factor_l1 - pc.avg_power_factor),
                ABS(pc.power_factor_l2 - pc.avg_power_factor),
                ABS(pc.power_factor_l3 - pc.avg_power_factor)
              ) / ABS(pc.avg_power_factor) * 100) * 20
            ))
          ELSE 100
        END as power_factor_consistency_score,
        
        -- D. POWER BALANCE SCORES (15% total weight)
        CASE 
          WHEN pc.active_power_l1 > 0 AND pc.active_power_l2 > 0 AND pc.active_power_l3 > 0 AND pc.total_active_power > 0 THEN
            GREATEST(0, 100 - (
              (GREATEST(
                ABS(pc.active_power_l1 - (pc.total_active_power/3)),
                ABS(pc.active_power_l2 - (pc.total_active_power/3)),
                ABS(pc.active_power_l3 - (pc.total_active_power/3))
              ) / (pc.total_active_power/3) * 100) * 3
            ))
          ELSE 50
        END as power_balance_score,
        
        -- E. SYSTEM EFFICIENCY SCORES (10% total weight)
        CASE 
          WHEN pc.total_apparent_power > 0 THEN
            (pc.total_active_power / pc.total_apparent_power) * 100
          ELSE 0
        END as system_efficiency_score,
        
        -- F. HARMONIC DISTORTION IMPACT SCORE (10% total weight)
        CASE 
          WHEN pc.avg_thd_voltage_ln > 0 AND pc.avg_thd_current > 0 THEN
            ((CASE 
              WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_excellent THEN 100
              WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_good THEN 90
              WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_fair THEN 75
              WHEN pc.avg_thd_voltage_ln <= (v_voltage_thd_fair * 1.5) THEN 60
              ELSE 30
            END * 0.6) + 
            (CASE 
              WHEN pc.avg_thd_current <= v_current_thd_excellent THEN 100
              WHEN pc.avg_thd_current <= v_current_thd_good THEN 80
              WHEN pc.avg_thd_current <= v_current_thd_fair THEN 60
              ELSE 30
            END * 0.4))
          ELSE 50
        END as harmonic_distortion_score
        
      FROM power_calculations pc
    ),
    
    weighted_pqi AS (
      SELECT 
        pqic.*,
        
        -- Calculate weighted category scores using function variables
        (pqic.voltage_deviation_score * v_w_voltage_deviation + pqic.voltage_unbalance_score * v_w_voltage_unbalance + pqic.voltage_thd_score * v_w_voltage_thd) as voltage_quality_category,
        (pqic.current_unbalance_score * v_w_current_unbalance + pqic.current_thd_score * v_w_current_thd) as current_quality_category,
        (pqic.power_factor_score * v_w_power_factor + pqic.power_factor_consistency_score * v_w_power_factor_consistency) as power_factor_category,
        (pqic.power_balance_score * v_w_power_balance) as power_balance_category,
        (pqic.system_efficiency_score * v_w_system_efficiency) as efficiency_category,
        (pqic.harmonic_distortion_score * v_w_harmonic_distortion) as harmonic_distortion_category
        
      FROM pqi_components pqic
    )
    
    SELECT 
      w.device_id,
      w.device_name,
      w.timestamp::TIMESTAMP WITH TIME ZONE,
      ROUND(w.total_active_power::numeric, 2),
      ROUND(w.total_reactive_power::numeric, 2),
      ROUND(w.total_apparent_power::numeric, 2),
      ROUND(w.avg_voltage_ln::numeric, 1),
      ROUND(w.avg_voltage_ll::numeric, 1),
      ROUND(w.avg_current::numeric, 2),
      ROUND(w.avg_power_factor::numeric, 3),
      ROUND(w.avg_thd_voltage_ln::numeric, 2),
      ROUND(w.avg_thd_voltage_ll::numeric, 2),
      ROUND(w.avg_thd_current::numeric, 2),
      ROUND(w.voltage_deviation_score::numeric, 1),
      ROUND(w.voltage_unbalance_score::numeric, 1),
      ROUND(w.voltage_thd_score::numeric, 1),
      ROUND(w.current_unbalance_score::numeric, 1),
      ROUND(w.current_thd_score::numeric, 1),
      ROUND(w.power_factor_score::numeric, 1),
      ROUND(w.power_factor_consistency_score::numeric, 1),
      ROUND(w.power_balance_score::numeric, 1),
      ROUND(w.system_efficiency_score::numeric, 1),
      ROUND(w.harmonic_distortion_score::numeric, 1),
      ROUND(w.voltage_quality_category::numeric, 1),
      ROUND(w.current_quality_category::numeric, 1),
      ROUND(w.power_factor_category::numeric, 1),
      ROUND(w.power_balance_category::numeric, 1),
      ROUND(w.efficiency_category::numeric, 1),
      ROUND(w.harmonic_distortion_category::numeric, 1),
      
      -- FINAL POWER QUALITY INDEX (0-100)
      ROUND((
        w.voltage_quality_category + 
        w.current_quality_category + 
        w.power_factor_category + 
        w.power_balance_category + 
        w.efficiency_category +
        w.harmonic_distortion_category
      )::numeric, 1) as power_quality_index,
      
      -- PQI Rating Classification
      (CASE 
        WHEN (w.voltage_quality_category + w.current_quality_category + w.power_factor_category + 
              w.power_balance_category + w.efficiency_category + w.harmonic_distortion_category) >= 90 THEN 'EXCELLENT'
        WHEN (w.voltage_quality_category + w.current_quality_category + w.power_factor_category + 
              w.power_balance_category + w.efficiency_category + w.harmonic_distortion_category) >= 80 THEN 'GOOD'
        WHEN (w.voltage_quality_category + w.current_quality_category + w.power_factor_category + 
              w.power_balance_category + w.efficiency_category + w.harmonic_distortion_category) >= 70 THEN 'FAIR'
        WHEN (w.voltage_quality_category + w.current_quality_category + w.power_factor_category + 
              w.power_balance_category + w.efficiency_category + w.harmonic_distortion_category) >= 60 THEN 'POOR'
        ELSE 'CRITICAL'
      END)::VARCHAR(20) as pqi_rating,
      
      p_equipment_type as equipment_type
      
    FROM weighted_pqi w
    ORDER BY w.device_id, w.timestamp DESC;

END;
$$;


--
-- Name: get_power_quality_index(integer, integer, timestamp with time zone, timestamp with time zone, character varying, numeric, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_power_quality_index(p_tenant_id integer, p_device_id integer, p_start_time timestamp with time zone, p_end_time timestamp with time zone, p_equipment_type character varying DEFAULT 'standard'::character varying, p_nominal_voltage numeric DEFAULT 400, p_custom_weights jsonb DEFAULT NULL::jsonb) RETURNS TABLE("timestamp" timestamp with time zone, device_id integer, total_active_power numeric, total_reactive_power numeric, total_apparent_power numeric, avg_voltage_ln numeric, avg_voltage_ll numeric, avg_current numeric, avg_power_factor numeric, avg_thd_voltage_ln numeric, avg_thd_voltage_ll numeric, avg_thd_current numeric, voltage_deviation_score numeric, voltage_unbalance_score numeric, voltage_thd_score numeric, current_unbalance_score numeric, current_thd_score numeric, power_factor_score numeric, power_factor_consistency_score numeric, power_balance_score numeric, system_efficiency_score numeric, harmonic_distortion_score numeric, voltage_quality_category numeric, current_quality_category numeric, power_factor_category numeric, power_balance_category numeric, efficiency_category numeric, harmonic_distortion_category numeric, power_quality_index numeric, pqi_rating character varying, equipment_type character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_voltage_tolerance_excellent NUMERIC;
    v_voltage_tolerance_good NUMERIC;
    v_voltage_tolerance_fair NUMERIC;
    v_voltage_thd_excellent NUMERIC;
    v_voltage_thd_good NUMERIC;
    v_voltage_thd_fair NUMERIC;
    v_current_thd_excellent NUMERIC;
    v_current_thd_good NUMERIC;
    v_current_thd_fair NUMERIC;
    v_pf_excellent NUMERIC;
    v_pf_good NUMERIC;
    v_pf_fair NUMERIC;
    
    -- Weight variables (with v_ prefix)
    v_w_voltage_deviation NUMERIC;
    v_w_voltage_unbalance NUMERIC;
    v_w_voltage_thd NUMERIC;
    v_w_current_unbalance NUMERIC;
    v_w_current_thd NUMERIC;
    v_w_power_factor NUMERIC;
    v_w_power_factor_consistency NUMERIC;
    v_w_power_balance NUMERIC;
    v_w_system_efficiency NUMERIC;
    v_w_harmonic_distortion NUMERIC;
BEGIN
    -- Set equipment-specific thresholds
    CASE p_equipment_type
        WHEN 'variable_frequency_drive' THEN
            v_voltage_tolerance_excellent := 2.0;  -- ±2% for VFDs
            v_voltage_tolerance_good := 5.0;
            v_voltage_tolerance_fair := 8.0;
            v_voltage_thd_excellent := 2.0;        -- Stricter THD for VFDs
            v_voltage_thd_good := 3.0;
            v_voltage_thd_fair := 5.0;
            v_current_thd_excellent := 8.0;
            v_current_thd_good := 12.0;
            v_current_thd_fair := 15.0;
            v_pf_excellent := 0.95;
            v_pf_good := 0.90;
            v_pf_fair := 0.85;
            
        WHEN 'server_equipment' THEN
            v_voltage_tolerance_excellent := 1.0;  -- Very strict for servers
            v_voltage_tolerance_good := 3.0;
            v_voltage_tolerance_fair := 5.0;
            v_voltage_thd_excellent := 3.0;
            v_voltage_thd_good := 5.0;
            v_voltage_thd_fair := 8.0;
            v_current_thd_excellent := 5.0;
            v_current_thd_good := 8.0;
            v_current_thd_fair := 12.0;
            v_pf_excellent := 0.90;
            v_pf_good := 0.85;
            v_pf_fair := 0.80;
            
        WHEN 'led_lighting' THEN
            v_voltage_tolerance_excellent := 5.0;  -- More tolerant
            v_voltage_tolerance_good := 8.0;
            v_voltage_tolerance_fair := 12.0;
            v_voltage_thd_excellent := 5.0;
            v_voltage_thd_good := 8.0;
            v_voltage_thd_fair := 12.0;
            v_current_thd_excellent := 15.0;
            v_current_thd_good := 20.0;
            v_current_thd_fair := 30.0;
            v_pf_excellent := 0.85;              -- LED drivers often have lower PF
            v_pf_good := 0.80;
            v_pf_fair := 0.75;
            
        WHEN 'motor_load' THEN
            v_voltage_tolerance_excellent := 3.0;
            v_voltage_tolerance_good := 5.0;
            v_voltage_tolerance_fair := 8.0;
            v_voltage_thd_excellent := 3.0;
            v_voltage_thd_good := 5.0;
            v_voltage_thd_fair := 8.0;
            v_current_thd_excellent := 8.0;
            v_current_thd_good := 12.0;
            v_current_thd_fair := 20.0;
            v_pf_excellent := 0.90;
            v_pf_good := 0.85;
            v_pf_fair := 0.80;
            
        ELSE -- 'standard' or any other type
            v_voltage_tolerance_excellent := 3.0;  -- ±3% standard
            v_voltage_tolerance_good := 5.0;
            v_voltage_tolerance_fair := 8.0;
            v_voltage_thd_excellent := 3.0;
            v_voltage_thd_good := 5.0;
            v_voltage_thd_fair := 8.0;
            v_current_thd_excellent := 5.0;
            v_current_thd_good := 8.0;
            v_current_thd_fair := 12.0;
            v_pf_excellent := 0.95;
            v_pf_good := 0.90;
            v_pf_fair := 0.85;
    END CASE;
    
    -- Set default weights (can be overridden by custom_weights)
    v_w_voltage_deviation := 0.10;
    v_w_voltage_unbalance := 0.05;
    v_w_voltage_thd := 0.05;
    v_w_current_unbalance := 0.15;
    v_w_current_thd := 0.10;
    v_w_power_factor := 0.12;
    v_w_power_factor_consistency := 0.08;
    v_w_power_balance := 0.15;
    v_w_system_efficiency := 0.10;
    v_w_harmonic_distortion := 0.10;
    
    -- Override weights if custom weights provided
    IF p_custom_weights IS NOT NULL THEN
        v_w_voltage_deviation := COALESCE((p_custom_weights->>'voltage_deviation')::NUMERIC, w_voltage_deviation);
        v_w_voltage_unbalance := COALESCE((p_custom_weights->>'voltage_unbalance')::NUMERIC, w_voltage_unbalance);
        v_w_voltage_thd := COALESCE((p_custom_weights->>'voltage_thd')::NUMERIC, w_voltage_thd);
        v_w_current_unbalance := COALESCE((p_custom_weights->>'current_unbalance')::NUMERIC, w_current_unbalance);
        v_w_current_thd := COALESCE((p_custom_weights->>'current_thd')::NUMERIC, w_current_thd);
        v_w_power_factor := COALESCE((p_custom_weights->>'power_factor')::NUMERIC, w_power_factor);
        v_w_power_factor_consistency := COALESCE((p_custom_weights->>'power_factor_consistency')::NUMERIC, w_power_factor_consistency);
        v_w_power_balance := COALESCE((p_custom_weights->>'power_balance')::NUMERIC, w_power_balance);
        v_w_system_efficiency := COALESCE((p_custom_weights->>'system_efficiency')::NUMERIC, w_system_efficiency);
        v_w_harmonic_distortion := COALESCE((p_custom_weights->>'harmonic_distortion')::NUMERIC, w_harmonic_distortion);
    END IF;
    
    -- Return the calculated PQI data
    RETURN QUERY
    WITH latest_readings AS (
      SELECT 
        td.device_id,
        td.timestamp,
        -- Active Power (3 phases)
        MAX(CASE WHEN td.quantity_id = 504 THEN td.value END) as active_power_l1,
        MAX(CASE WHEN td.quantity_id = 505 THEN td.value END) as active_power_l2,
        MAX(CASE WHEN td.quantity_id = 506 THEN td.value END) as active_power_l3,
        
        -- Reactive Power (3 phases)
        MAX(CASE WHEN td.quantity_id = 507 THEN td.value END) as reactive_power_l1,
        MAX(CASE WHEN td.quantity_id = 508 THEN td.value END) as reactive_power_l2,
        MAX(CASE WHEN td.quantity_id = 509 THEN td.value END) as reactive_power_l3,
        
        -- Apparent Power (3 phases)
        MAX(CASE WHEN td.quantity_id = 510 THEN td.value END) as apparent_power_l1,
        MAX(CASE WHEN td.quantity_id = 511 THEN td.value END) as apparent_power_l2,
        MAX(CASE WHEN td.quantity_id = 512 THEN td.value END) as apparent_power_l3,
        
        -- Voltage Line to Line
        MAX(CASE WHEN td.quantity_id = 1057 THEN td.value END) as voltage_l1l2,
        MAX(CASE WHEN td.quantity_id = 1058 THEN td.value END) as voltage_l2l3,
        MAX(CASE WHEN td.quantity_id = 1059 THEN td.value END) as voltage_l3l1,
        
        -- Voltage Line to Neutral
        MAX(CASE WHEN td.quantity_id = 1060 THEN td.value END) as voltage_l1n,
        MAX(CASE WHEN td.quantity_id = 1061 THEN td.value END) as voltage_l2n,
        MAX(CASE WHEN td.quantity_id = 1062 THEN td.value END) as voltage_l3n,
        
        -- Current (3 phases)
        MAX(CASE WHEN td.quantity_id = 501 THEN td.value END) as current_l1,
        MAX(CASE WHEN td.quantity_id = 502 THEN td.value END) as current_l2,
        MAX(CASE WHEN td.quantity_id = 503 THEN td.value END) as current_l3,
        
        -- Power Factor (3 phases)
        MAX(CASE WHEN td.quantity_id = 3325 THEN td.value END) as power_factor_l1,
        MAX(CASE WHEN td.quantity_id = 3326 THEN td.value END) as power_factor_l2,
        MAX(CASE WHEN td.quantity_id = 3327 THEN td.value END) as power_factor_l3,
		MAX(CASE WHEN td.quantity_id = 1072 THEN td.value END) as power_factor_total,
		
        -- Total Harmonic Distortion - Voltage Line to Line
        MAX(CASE WHEN td.quantity_id = 2034 THEN td.value END) as thd_v_l1l2,
        MAX(CASE WHEN td.quantity_id = 2036 THEN td.value END) as thd_v_l2l3,
        MAX(CASE WHEN td.quantity_id = 2038 THEN td.value END) as thd_v_l3l1,
        
        -- Total Harmonic Distortion - Voltage Line to Neutral
        MAX(CASE WHEN td.quantity_id = 2035 THEN td.value END) as thd_v_l1n,
        MAX(CASE WHEN td.quantity_id = 2037 THEN td.value END) as thd_v_l2n,
        MAX(CASE WHEN td.quantity_id = 2039 THEN td.value END) as thd_v_l3n,
        
        -- Total Harmonic Distortion - Current
        MAX(CASE WHEN td.quantity_id = 2097 THEN td.value END) as thd_i_l1,
        MAX(CASE WHEN td.quantity_id = 2098 THEN td.value END) as thd_i_l2,
        MAX(CASE WHEN td.quantity_id = 2099 THEN td.value END) as thd_i_l3
        
      FROM telemetry_data td
      WHERE td.device_id = p_device_id
	  	AND td.tenant_id = p_tenant_id
        AND td.timestamp >= p_start_time
        AND td.timestamp <= p_end_time
      GROUP BY td.device_id, td.timestamp
    ),
    
    power_calculations AS (
      SELECT 
        *,
        -- Total Power Values
        (COALESCE(active_power_l1, 0) + COALESCE(active_power_l2, 0) + COALESCE(active_power_l3, 0)) as total_active_power,
        (COALESCE(reactive_power_l1, 0) + COALESCE(reactive_power_l2, 0) + COALESCE(reactive_power_l3, 0)) as total_reactive_power,
        (COALESCE(apparent_power_l1, 0) + COALESCE(apparent_power_l2, 0) + COALESCE(apparent_power_l3, 0)) as total_apparent_power,
        
        -- Average Voltage Calculations
        (COALESCE(voltage_l1n, 0) + COALESCE(voltage_l2n, 0) + COALESCE(voltage_l3n, 0)) / 3.0 as avg_voltage_ln,
        (COALESCE(voltage_l1l2, 0) + COALESCE(voltage_l2l3, 0) + COALESCE(voltage_l3l1, 0)) / 3.0 as avg_voltage_ll,
        
        -- Average Current (3 phases only)
        (COALESCE(current_l1, 0) + COALESCE(current_l2, 0) + COALESCE(current_l3, 0)) / 3.0 as avg_current,
        
        -- Average Power Factor
		CASE 
		  WHEN power_factor_l1 IS NOT NULL OR power_factor_l2 IS NOT NULL OR power_factor_l3 IS NOT NULL THEN
		    -- Use per-phase average when available
		    (COALESCE(power_factor_l1, 0) + COALESCE(power_factor_l2, 0) + COALESCE(power_factor_l3, 0)) / 
		    GREATEST(1, (CASE WHEN power_factor_l1 IS NOT NULL THEN 1 ELSE 0 END + 
		                 CASE WHEN power_factor_l2 IS NOT NULL THEN 1 ELSE 0 END + 
		                 CASE WHEN power_factor_l3 IS NOT NULL THEN 1 ELSE 0 END))
		  ELSE 
		    -- Fallback to overall power factor
		    COALESCE(power_factor_total, 0)
		END as avg_power_factor,       
		
        -- Average THD Calculations
        (COALESCE(thd_v_l1n, 0) + COALESCE(thd_v_l2n, 0) + COALESCE(thd_v_l3n, 0)) / 3.0 as avg_thd_voltage_ln,
        (COALESCE(thd_v_l1l2, 0) + COALESCE(thd_v_l2l3, 0) + COALESCE(thd_v_l3l1, 0)) / 3.0 as avg_thd_voltage_ll,
        (COALESCE(thd_i_l1, 0) + COALESCE(thd_i_l2, 0) + COALESCE(thd_i_l3, 0)) / 3.0 as avg_thd_current
        
      FROM latest_readings
    ),
    
    pqi_components AS (
      SELECT 
        pc.*,
        
        -- A. VOLTAGE QUALITY SCORES (20% total weight)
        -- Voltage deviation from nominal (using parameter)
        CASE 
          WHEN pc.avg_voltage_ln BETWEEN (p_nominal_voltage * (1 - v_voltage_tolerance_excellent/100)) 
                                  AND (p_nominal_voltage * (1 + v_voltage_tolerance_excellent/100)) THEN 100
          WHEN pc.avg_voltage_ln BETWEEN (p_nominal_voltage * (1 - v_voltage_tolerance_good/100)) 
                                  AND (p_nominal_voltage * (1 + v_voltage_tolerance_good/100)) THEN 
            90 - (ABS(pc.avg_voltage_ln - p_nominal_voltage) / p_nominal_voltage * 100 * 2)
          WHEN pc.avg_voltage_ln BETWEEN (p_nominal_voltage * (1 - v_voltage_tolerance_fair/100)) 
                                  AND (p_nominal_voltage * (1 + v_voltage_tolerance_fair/100)) THEN 
            70 - (ABS(pc.avg_voltage_ln - p_nominal_voltage) / p_nominal_voltage * 100)
          ELSE 0
        END as voltage_deviation_score,
        
        -- Voltage unbalance score (Line-to-Neutral)
        CASE 
          WHEN pc.voltage_l1n > 0 AND pc.voltage_l2n > 0 AND pc.voltage_l3n > 0 AND pc.avg_voltage_ln > 0 THEN
            GREATEST(0, 100 - (
              (GREATEST(
                ABS(pc.voltage_l1n - pc.avg_voltage_ln),
                ABS(pc.voltage_l2n - pc.avg_voltage_ln),
                ABS(pc.voltage_l3n - pc.avg_voltage_ln)
              ) / pc.avg_voltage_ln * 100) * 10  -- 10x penalty for unbalance
            ))
          ELSE 50 -- Partial penalty if missing phase data
        END as voltage_unbalance_score,
        
        -- Voltage THD score (equipment-specific thresholds)
        CASE 
          WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_excellent THEN 100
          WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_good THEN 90
          WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_fair THEN 75
          WHEN pc.avg_thd_voltage_ln <= (v_voltage_thd_fair * 1.5) THEN 60
          WHEN pc.avg_thd_voltage_ln <= (v_voltage_thd_fair * 2) THEN 40
          ELSE 20
        END as voltage_thd_score,
        
        -- B. CURRENT QUALITY SCORES (25% total weight)
        -- Current unbalance score
        CASE 
          WHEN pc.current_l1 > 0 AND pc.current_l2 > 0 AND pc.current_l3 > 0 AND pc.avg_current > 0 THEN
            GREATEST(0, 100 - (
              (GREATEST(
                ABS(pc.current_l1 - pc.avg_current),
                ABS(pc.current_l2 - pc.avg_current),
                ABS(pc.current_l3 - pc.avg_current)
              ) / pc.avg_current * 100) * 5  -- 5x penalty for current unbalance
            ))
          ELSE 50
        END as current_unbalance_score,
        
        -- Current THD score (equipment-specific thresholds)
        CASE 
          WHEN pc.avg_thd_current <= v_current_thd_excellent THEN 100
          WHEN pc.avg_thd_current <= v_current_thd_good THEN 90
          WHEN pc.avg_thd_current <= v_current_thd_fair THEN 75
          WHEN pc.avg_thd_current <= (v_current_thd_fair * 1.5) THEN 60
          WHEN pc.avg_thd_current <= (v_current_thd_fair * 2) THEN 40
          ELSE 20
        END as current_thd_score,
        
        -- C. POWER FACTOR QUALITY SCORES (20% total weight)
        -- Overall power factor score (equipment-specific thresholds)
        CASE 
          WHEN pc.avg_power_factor >= v_pf_excellent THEN 100
          WHEN pc.avg_power_factor >= v_pf_good THEN 90
          WHEN pc.avg_power_factor >= v_pf_fair THEN 75
          WHEN pc.avg_power_factor >= (v_pf_fair - 0.05) THEN 60
          WHEN pc.avg_power_factor >= (v_pf_fair - 0.10) THEN 40
          WHEN pc.avg_power_factor >= (v_pf_fair - 0.15) THEN 20
          ELSE 0
        END as power_factor_score,
        
        -- Power factor consistency across phases
		CASE 
		  WHEN pc.power_factor_l1 IS NOT NULL AND pc.power_factor_l2 IS NOT NULL AND pc.power_factor_l3 IS NOT NULL AND pc.avg_power_factor != 0 THEN
		    -- Calculate consistency only when all phases available
		    GREATEST(0, 100 - (
		      (GREATEST(
		        ABS(pc.power_factor_l1 - pc.avg_power_factor),
		        ABS(pc.power_factor_l2 - pc.avg_power_factor),
		        ABS(pc.power_factor_l3 - pc.avg_power_factor)
		      ) / ABS(pc.avg_power_factor) * 100) * 20  -- 20x penalty for PF inconsistency
		    ))
		  ELSE 
		    -- Give full score when using overall PF (no consistency to measure)
		    100
		END as power_factor_consistency_score,
		
        -- D. POWER BALANCE SCORES (15% total weight)
        -- Power balance across phases
        CASE 
          WHEN pc.active_power_l1 > 0 AND pc.active_power_l2 > 0 AND pc.active_power_l3 > 0 AND pc.total_active_power > 0 THEN
            GREATEST(0, 100 - (
              (GREATEST(
                ABS(pc.active_power_l1 - (pc.total_active_power/3)),
                ABS(pc.active_power_l2 - (pc.total_active_power/3)),
                ABS(pc.active_power_l3 - (pc.total_active_power/3))
              ) / (pc.total_active_power/3) * 100) * 3  -- 3x penalty for power imbalance
            ))
          ELSE 50
        END as power_balance_score,
        
        -- E. SYSTEM EFFICIENCY SCORES (10% total weight)
        -- Apparent vs Active power efficiency
        CASE 
          WHEN pc.total_apparent_power > 0 THEN
            (pc.total_active_power / pc.total_apparent_power) * 100
          ELSE 0
        END as system_efficiency_score,
        
        -- F. HARMONIC DISTORTION IMPACT SCORE (10% total weight)
        -- Combined THD impact assessment
        CASE 
          WHEN pc.avg_thd_voltage_ln > 0 AND pc.avg_thd_current > 0 THEN
            -- Weighted combination of voltage and current THD impacts
            ((CASE 
              WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_excellent THEN 100
              WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_good THEN 90
              WHEN pc.avg_thd_voltage_ln <= v_voltage_thd_fair THEN 75
              WHEN pc.avg_thd_voltage_ln <= (v_voltage_thd_fair * 1.5) THEN 60
              ELSE 30
            END * 0.6) + 
            (CASE 
              WHEN pc.avg_thd_current <= v_current_thd_excellent THEN 100
              WHEN pc.avg_thd_current <= v_current_thd_good THEN 80
              WHEN pc.avg_thd_current <= v_current_thd_fair THEN 60
              ELSE 30
            END * 0.4))
          ELSE 50  -- Default if THD data missing
        END as harmonic_distortion_score
        
      FROM power_calculations pc
    ),
    
    weighted_pqi AS (
      SELECT 
        pqic.device_id,
        pqic.timestamp,
        pqic.total_active_power,
        pqic.total_reactive_power,
        pqic.total_apparent_power,
        pqic.avg_voltage_ln,
        pqic.avg_voltage_ll,
        pqic.avg_current,
        pqic.avg_power_factor,
        pqic.avg_thd_voltage_ln,
        pqic.avg_thd_voltage_ll,
        pqic.avg_thd_current,
        pqic.voltage_deviation_score,
        pqic.voltage_unbalance_score,
        pqic.voltage_thd_score,
        pqic.current_unbalance_score,
        pqic.current_thd_score,
        pqic.power_factor_score,
        pqic.power_factor_consistency_score,
        pqic.power_balance_score,
        pqic.system_efficiency_score,
        pqic.harmonic_distortion_score,
        
        -- Calculate weighted category scores using function variables
        (pqic.voltage_deviation_score * v_w_voltage_deviation + pqic.voltage_unbalance_score * v_w_voltage_unbalance + pqic.voltage_thd_score * v_w_voltage_thd) as voltage_quality_category,
        (pqic.current_unbalance_score * v_w_current_unbalance + pqic.current_thd_score * v_w_current_thd) as current_quality_category,
        (pqic.power_factor_score * v_w_power_factor + pqic.power_factor_consistency_score * v_w_power_factor_consistency) as power_factor_category,
        (pqic.power_balance_score * v_w_power_balance) as power_balance_category,
        (pqic.system_efficiency_score * v_w_system_efficiency) as efficiency_category,
        (pqic.harmonic_distortion_score * v_w_harmonic_distortion) as harmonic_distortion_category
        
      FROM pqi_components pqic
    )
    
    SELECT 
      w.timestamp::TIMESTAMP WITH TIME ZONE,
      w.device_id,
      ROUND(w.total_active_power::numeric, 2),
      ROUND(w.total_reactive_power::numeric, 2),
      ROUND(w.total_apparent_power::numeric, 2),
      ROUND(w.avg_voltage_ln::numeric, 1),
      ROUND(w.avg_voltage_ll::numeric, 1),
      ROUND(w.avg_current::numeric, 2),
      ROUND(w.avg_power_factor::numeric, 3),
      ROUND(w.avg_thd_voltage_ln::numeric, 2),
      ROUND(w.avg_thd_voltage_ll::numeric, 2),
      ROUND(w.avg_thd_current::numeric, 2),
      ROUND(w.voltage_deviation_score::numeric, 1),
      ROUND(w.voltage_unbalance_score::numeric, 1),
      ROUND(w.voltage_thd_score::numeric, 1),
      ROUND(w.current_unbalance_score::numeric, 1),
      ROUND(w.current_thd_score::numeric, 1),
      ROUND(w.power_factor_score::numeric, 1),
      ROUND(w.power_factor_consistency_score::numeric, 1),
      ROUND(w.power_balance_score::numeric, 1),
      ROUND(w.system_efficiency_score::numeric, 1),
      ROUND(w.harmonic_distortion_score::numeric, 1),
      ROUND(w.voltage_quality_category::numeric, 1),
      ROUND(w.current_quality_category::numeric, 1),
      ROUND(w.power_factor_category::numeric, 1),
      ROUND(w.power_balance_category::numeric, 1),
      ROUND(w.efficiency_category::numeric, 1),
      ROUND(w.harmonic_distortion_category::numeric, 1),
      
      -- FINAL POWER QUALITY INDEX (0-100)
      ROUND((
        w.voltage_quality_category + 
        w.current_quality_category + 
        w.power_factor_category + 
        w.power_balance_category + 
        w.efficiency_category +
        w.harmonic_distortion_category
      )::numeric, 1) as power_quality_index,
      
      -- PQI Rating Classification
      (CASE 
        WHEN (w.voltage_quality_category + w.current_quality_category + w.power_factor_category + 
              w.power_balance_category + w.efficiency_category + w.harmonic_distortion_category) >= 90 THEN 'EXCELLENT'
        WHEN (w.voltage_quality_category + w.current_quality_category + w.power_factor_category + 
              w.power_balance_category + w.efficiency_category + w.harmonic_distortion_category) >= 80 THEN 'GOOD'
        WHEN (w.voltage_quality_category + w.current_quality_category + w.power_factor_category + 
              w.power_balance_category + w.efficiency_category + w.harmonic_distortion_category) >= 70 THEN 'FAIR'
        WHEN (w.voltage_quality_category + w.current_quality_category + w.power_factor_category + 
              w.power_balance_category + w.efficiency_category + w.harmonic_distortion_category) >= 60 THEN 'POOR'
        ELSE 'CRITICAL'
      END)::VARCHAR(20) as pqi_rating,
      
      p_equipment_type as equipment_type
      
    FROM weighted_pqi w
    ORDER BY w.timestamp DESC;

END;
$$;


--
-- Name: get_quantities_interval(integer, integer[], timestamp without time zone, timestamp without time zone, integer[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_quantities_interval(p_tenant_id integer, p_device_ids integer[] DEFAULT NULL::integer[], p_start_time timestamp without time zone DEFAULT NULL::timestamp without time zone, p_end_time timestamp without time zone DEFAULT NULL::timestamp without time zone, p_quantity_ids integer[] DEFAULT NULL::integer[]) RETURNS TABLE(bucket timestamp without time zone, device_id integer, quantity_id integer, quantity_code character varying, interval_energy numeric, cumulative_energy numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        tc.bucket,
        tc.device_id,
        tc.quantity_id,
        tc.quantity_code,
        tc.interval_value as interval_energy,
        tc.cumulative_value as cumulative_energy
    FROM telemetry_intervals_cumulative tc
    WHERE tc.tenant_id = p_tenant_id
      AND (p_device_ids IS NULL OR tc.device_id = ANY(p_device_ids))
      AND (p_start_time IS NULL OR tc.bucket >= p_start_time)
      AND (p_end_time IS NULL OR tc.bucket <= p_end_time)
      AND (p_quantity_ids IS NULL OR tc.quantity_id = ANY(p_quantity_ids))
      AND tc.interval_value IS NOT NULL -- Exclude NULL intervals
    ORDER BY tc.bucket DESC, tc.device_id, tc.quantity_id;
END;
$$;


--
-- Name: get_raw_telemetry_for_user(integer, integer[], timestamp without time zone, timestamp without time zone, integer[], integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_raw_telemetry_for_user(p_user_id integer, p_device_ids integer[] DEFAULT NULL::integer[], p_start_time timestamp without time zone DEFAULT NULL::timestamp without time zone, p_end_time timestamp without time zone DEFAULT NULL::timestamp without time zone, p_quantity_ids integer[] DEFAULT NULL::integer[], p_limit integer DEFAULT 10000, p_tenant_id integer DEFAULT NULL::integer) RETURNS TABLE("timestamp" timestamp without time zone, tenant_id integer, device_id integer, quantity_id integer, value numeric, quality integer, source_system character varying, created_at timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    accessible_tenant_ids INTEGER[];
    filtered_device_ids INTEGER[];
    device_tenant_map JSONB;
    has_permission BOOLEAN;
BEGIN
    -- 1. Validate user exists and is active
    IF NOT EXISTS (
        SELECT 1 FROM auth_users 
        WHERE id = p_user_id AND is_active = true
    ) THEN
        RAISE EXCEPTION 'Invalid or inactive user: %', p_user_id;
    END IF;
    
    -- 2. Get user's accessible tenant IDs with telemetry read permission
    SELECT ARRAY_AGG(DISTINCT ut.tenant_id) INTO accessible_tenant_ids
    FROM auth_user_tenants ut
    JOIN auth_products p ON ut.product_id = p.id
    WHERE ut.user_id = p_user_id 
    AND ut.is_active = true
    AND (ut.expires_at IS NULL OR ut.expires_at > CURRENT_TIMESTAMP)
    AND p.is_active = true
    AND (
        'read_telemetry' = ANY(ut.permissions) OR
        'api_read' = ANY(ut.permissions) OR
        'api_access' = ANY(ut.permissions)
    );
    
    -- Check if user has any tenant access
    IF accessible_tenant_ids IS NULL OR array_length(accessible_tenant_ids, 1) = 0 THEN
        RAISE EXCEPTION 'User % has no telemetry access to any tenants', p_user_id;
    END IF;
    
    -- 3. If specific tenant requested, validate access
    IF p_tenant_id IS NOT NULL THEN
        IF NOT (p_tenant_id = ANY(accessible_tenant_ids)) THEN
            RAISE EXCEPTION 'User % does not have access to tenant %', p_user_id, p_tenant_id;
        END IF;
        -- Restrict to single tenant
        accessible_tenant_ids := ARRAY[p_tenant_id];
    END IF;
    
    -- 4. Validate device ownership and filter to accessible devices
    IF p_device_ids IS NOT NULL THEN
        -- Get device-tenant mapping for requested devices
        SELECT json_object_agg(d.id, d.tenant_id) INTO device_tenant_map
        FROM devices d
        WHERE d.id = ANY(p_device_ids) AND d.is_active = true;
        
        -- Filter devices to only those in accessible tenants
        SELECT ARRAY_AGG(d.id) INTO filtered_device_ids
        FROM devices d
        WHERE d.id = ANY(p_device_ids)
        AND d.tenant_id = ANY(accessible_tenant_ids)
        AND d.is_active = true;
        
        -- Check if any valid devices found
        IF filtered_device_ids IS NULL OR array_length(filtered_device_ids, 1) = 0 THEN
            RAISE EXCEPTION 'No accessible devices found for user %', p_user_id;
        END IF;
        
        -- Log if some devices were filtered out
        IF array_length(filtered_device_ids, 1) < array_length(p_device_ids, 1) THEN
            RAISE NOTICE 'Some devices filtered due to access restrictions for user %', p_user_id;
        END IF;
    ELSE
        -- No device filter provided - will filter by tenant in main query
        filtered_device_ids := NULL;
    END IF;
    
    -- 5. Log data access for audit
    INSERT INTO audit_logs (tenant_id, user_id, action_type, resource_type, action_description)
    SELECT 
        unnest(accessible_tenant_ids),
        p_user_id,
        'DATA_ACCESS',
        'TELEMETRY',
        format('User telemetry access - Devices: %s, Time: %s to %s', 
               COALESCE(array_to_string(filtered_device_ids, ','), 'ALL'),
               p_start_time, p_end_time);
    
    -- 6. Return filtered telemetry data
    RETURN QUERY
    SELECT 
        td.timestamp,
        d.tenant_id,
        td.device_id,
        td.quantity_id,
        td.value,
        td.quality,
        td.source_system,
        td.created_at
    FROM telemetry_data td
    JOIN devices d ON td.device_id = d.id
    WHERE d.tenant_id = ANY(accessible_tenant_ids)
      AND (filtered_device_ids IS NULL OR td.device_id = ANY(filtered_device_ids))
      AND (p_start_time IS NULL OR td.timestamp >= p_start_time)
      AND (p_end_time IS NULL OR td.timestamp <= p_end_time)
      AND (p_quantity_ids IS NULL OR td.quantity_id = ANY(p_quantity_ids))
      AND d.is_active = true
    ORDER BY td.timestamp DESC
    LIMIT p_limit;
    
EXCEPTION
    WHEN OTHERS THEN
        -- Log error for debugging
        INSERT INTO audit_logs (user_id, action_type, resource_type, action_description)
        VALUES (p_user_id, 'DATA_ACCESS_ERROR', 'TELEMETRY', 
                format('Telemetry access failed: %s', SQLERRM));
        RAISE;
END;
$$;


--
-- Name: FUNCTION get_raw_telemetry_for_user(p_user_id integer, p_device_ids integer[], p_start_time timestamp without time zone, p_end_time timestamp without time zone, p_quantity_ids integer[], p_limit integer, p_tenant_id integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.get_raw_telemetry_for_user(p_user_id integer, p_device_ids integer[], p_start_time timestamp without time zone, p_end_time timestamp without time zone, p_quantity_ids integer[], p_limit integer, p_tenant_id integer) IS 'Get telemetry data with user-based authentication and tenant filtering';


--
-- Name: get_sankey_auto_flow(integer, integer, integer, text[], timestamp without time zone, timestamp without time zone, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_sankey_auto_flow(p_tenant_id integer, p_start_level integer, p_end_level integer, p_asset_types text[] DEFAULT NULL::text[], p_start_time timestamp without time zone DEFAULT NULL::timestamp without time zone, p_end_time timestamp without time zone DEFAULT NULL::timestamp without time zone, p_include_external_sources boolean DEFAULT false) RETURNS TABLE(nodes jsonb, links jsonb, metadata jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_nodes JSONB;
    v_links JSONB;
    v_metadata JSONB;
BEGIN
    -- Generate nodes from asset hierarchy
    WITH hierarchy_nodes AS (
        SELECT 
            a.id,
            a.asset_name,
            a.asset_type,
            a.level_depth,
            ROW_NUMBER() OVER (ORDER BY a.level_depth, a.asset_name) - 1 as node_index
        FROM assets a
        WHERE a.tenant_id = p_tenant_id
          AND a.is_active = true
          AND a.level_depth BETWEEN p_start_level AND p_end_level
          AND (p_asset_types IS NULL OR a.asset_type = ANY(p_asset_types))
    ),
    node_array AS (
        SELECT JSON_AGG(
            JSON_BUILD_OBJECT(
                'name', hn.asset_name,
                'id', hn.id,
                'level', hn.level_depth,
                'metadata', JSON_BUILD_OBJECT(
                    'assetId', hn.id,
                    'assetType', hn.asset_type,
                    'nodeIndex', hn.node_index
                )
            )
            ORDER BY hn.node_index
        ) as nodes
        FROM hierarchy_nodes hn
    ),
    -- Generate links from parent-child relationships
    hierarchy_links AS (
        SELECT 
            parent_nodes.node_index as source,
            child_nodes.node_index as target,
            0.0 as value -- Will be populated with actual telemetry data
        FROM hierarchy_nodes parent_nodes
        JOIN assets child_assets ON child_assets.parent_id = parent_nodes.id
        JOIN hierarchy_nodes child_nodes ON child_nodes.id = child_assets.id
        WHERE child_assets.tenant_id = p_tenant_id
          AND child_assets.is_active = true
    ),
    link_array AS (
        SELECT JSON_AGG(
            JSON_BUILD_OBJECT(
                'source', hl.source,
                'target', hl.target,
                'value', hl.value,
                'quantity', 'energy' -- Default quantity type
            )
        ) as links
        FROM hierarchy_links hl
    )
    SELECT 
        na.nodes,
        la.links,
        JSON_BUILD_OBJECT(
            'generatedAt', NOW(),
            'dataSource', 'asset_hierarchy',
            'timeRange', JSON_BUILD_OBJECT(
                'start', p_start_time,
                'end', p_end_time
            ),
            'totalFlow', 0.0, -- To be calculated with actual telemetry
            'nodeCount', JSON_ARRAY_LENGTH(na.nodes),
            'linkCount', JSON_ARRAY_LENGTH(COALESCE(la.links, '[]'::jsonb))
        ) as metadata
    INTO v_nodes, v_links, v_metadata
    FROM node_array na
    CROSS JOIN link_array la;
    
    RETURN QUERY SELECT v_nodes, v_links, v_metadata;
END;
$$;


--
-- Name: get_sankey_hierarchy_preview(integer, integer, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_sankey_hierarchy_preview(p_tenant_id integer, p_max_depth integer DEFAULT 5, p_include_device_counts boolean DEFAULT true) RETURNS TABLE(depth integer, asset_types text[], asset_count bigint, device_count bigint, sample_assets jsonb)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH hierarchy_levels AS (
        SELECT 
            a.level_depth as depth,
            ARRAY_AGG(DISTINCT a.asset_type) as asset_types,
            COUNT(*) as asset_count,
            COALESCE(SUM(device_counts.device_count), 0) as device_count,
            JSON_AGG(
                JSON_BUILD_OBJECT(
                    'id', a.id,
                    'name', a.asset_name,
                    'assetType', a.asset_type,
                    'hasDevices', device_counts.device_count > 0,
                    'deviceCount', COALESCE(device_counts.device_count, 0)
                ) 
                ORDER BY a.asset_name
            ) as sample_assets
        FROM assets a
        LEFT JOIN (
            SELECT 
                d.asset_id,
                COUNT(*) as device_count
            FROM devices d
            WHERE d.tenant_id = p_tenant_id
              AND d.is_active = true
            GROUP BY d.asset_id
        ) device_counts ON a.id = device_counts.asset_id
        WHERE a.tenant_id = p_tenant_id
          AND a.is_active = true
          AND a.level_depth <= p_max_depth
        GROUP BY a.level_depth
    )
    SELECT 
        hl.depth,
        hl.asset_types,
        hl.asset_count,
        CASE WHEN p_include_device_counts THEN hl.device_count ELSE 0 END,
        hl.sample_assets
    FROM hierarchy_levels hl
    ORDER BY hl.depth;
END;
$$;


--
-- Name: get_shared_quantities_for_user(integer, integer[], integer, boolean, numeric, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_shared_quantities_for_user(p_user_id integer, p_device_ids integer[], p_tenant_id integer DEFAULT NULL::integer, p_include_inactive boolean DEFAULT false, p_min_data_quality_score numeric DEFAULT 0.0, p_time_window_hours integer DEFAULT 8760) RETURNS TABLE(quantity jsonb, sharing_stats jsonb, data_quality jsonb, coverage_analysis jsonb)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_accessible_device_count integer;
    v_total_requested_devices integer;
    v_cutoff_timestamp timestamp;
    v_tenant_filter integer[];
BEGIN
    -- Input validation
    IF p_device_ids IS NULL OR array_length(p_device_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'Device IDs array cannot be null or empty';
    END IF;
    
    IF array_length(p_device_ids, 1) > 100 THEN
        RAISE EXCEPTION 'Maximum 100 device IDs allowed per query';
    END IF;
    
    -- Set time window for analysis
    v_cutoff_timestamp := CURRENT_TIMESTAMP - (p_time_window_hours || ' hours')::INTERVAL;
    v_total_requested_devices := array_length(p_device_ids, 1);
    
    -- Determine tenant filtering strategy
    IF p_tenant_id IS NOT NULL THEN
        -- Single tenant mode - validate user access to specific tenant
        IF NOT EXISTS (
            SELECT 1 FROM auth_user_tenants 
            WHERE user_id = p_user_id 
              AND tenant_id = p_tenant_id 
              AND is_active = true
        ) THEN
            RAISE EXCEPTION 'User does not have access to tenant %', p_tenant_id;
        END IF;
        v_tenant_filter := ARRAY[p_tenant_id];
    ELSE
        -- Multi-tenant mode - get all accessible tenants for user
        SELECT ARRAY_AGG(tenant_id) INTO v_tenant_filter
        FROM auth_user_tenants 
        WHERE user_id = p_user_id AND is_active = true;
        
        IF v_tenant_filter IS NULL THEN
            RAISE EXCEPTION 'User has no accessible tenants';
        END IF;
    END IF;
    
    -- Validate user access to all requested devices
    SELECT COUNT(*) INTO v_accessible_device_count
    FROM devices d
    WHERE d.id = ANY(p_device_ids)
      AND d.tenant_id = ANY(v_tenant_filter)
      AND (p_include_inactive = true OR d.is_active = true);
    
    IF v_accessible_device_count != v_total_requested_devices THEN
        RAISE EXCEPTION 'User lacks access to % out of % requested devices', 
            (v_total_requested_devices - v_accessible_device_count), 
            v_total_requested_devices;
    END IF;
    
    -- Log audit entry for shared quantities query
    --INSERT INTO audit_logs (user_id, action_type, table_name, details, created_at)
    --VALUES (
    --    p_user_id, 
    --    'shared_quantities_query', 
    --    'telemetry_data',
    --    jsonb_build_object(
    --        'device_count', v_total_requested_devices,
    --        'tenant_id', p_tenant_id,
    --        'time_window_hours', p_time_window_hours,
    --        'min_quality_score', p_min_data_quality_score
    --    ),
    --    CURRENT_TIMESTAMP
    --);
    
    -- Main query: Find quantities that exist on ALL specified devices
    RETURN QUERY
    WITH device_quantity_analysis AS (
        -- Get telemetry data for all devices and quantities within time window
        SELECT 
            td.quantity_id,
            td.device_id,
            q.quantity_code,
            q.quantity_name,
            q.unit,
            q.category,
            q.data_type,
            q.aggregation_method,
            q.description,
            q.is_active as quantity_active,
            COUNT(*) as measurement_count,
            AVG(COALESCE(td.quality, 1.0)) as avg_quality_score,
            MIN(td.timestamp) as first_measurement,
            MAX(td.timestamp) as last_measurement,
            COUNT(DISTINCT DATE(td.timestamp)) as days_with_data
        FROM telemetry_data td
        INNER JOIN quantities q ON td.quantity_id = q.id
        WHERE td.device_id = ANY(p_device_ids)
          AND td.tenant_id = ANY(v_tenant_filter)
          AND td.timestamp >= v_cutoff_timestamp
          AND (p_include_inactive = true OR q.is_active = true)
          AND COALESCE(td.quality, 1.0) >= p_min_data_quality_score
        GROUP BY 
            td.quantity_id, td.device_id, q.quantity_code, q.quantity_name, 
            q.unit, q.category, q.data_type, q.aggregation_method, 
            q.description, q.is_active
    ),
    shared_quantities AS (
        -- Find quantities that appear on ALL requested devices
        SELECT 
            quantity_id,
            quantity_code,
            quantity_name,
            unit,
            category,
            data_type,
            aggregation_method,
            description,
            quantity_active,
            COUNT(DISTINCT device_id) as device_count,
            SUM(measurement_count) as total_measurements,
            AVG(avg_quality_score) as overall_quality_score,
            MIN(first_measurement) as earliest_measurement,
            MAX(last_measurement) as latest_measurement,
            SUM(days_with_data) as total_days_with_data,
            ARRAY_AGG(DISTINCT device_id ORDER BY device_id) as devices_with_data
        FROM device_quantity_analysis
        GROUP BY 
            quantity_id, quantity_code, quantity_name, unit, category, 
            data_type, aggregation_method, description, quantity_active
        HAVING COUNT(DISTINCT device_id) = v_total_requested_devices
    ),
    coverage_stats AS (
        -- Calculate coverage statistics for each shared quantity
        SELECT 
            sq.*,
            ROUND(
                (sq.total_days_with_data::decimal / 
                 (v_total_requested_devices * EXTRACT(DAYS FROM (CURRENT_TIMESTAMP - v_cutoff_timestamp))::integer)
                ) * 100, 2
            ) as data_coverage_percentage,
            CASE 
                WHEN sq.overall_quality_score >= 0.9 THEN 'excellent'
                WHEN sq.overall_quality_score >= 0.7 THEN 'good'
                WHEN sq.overall_quality_score >= 0.5 THEN 'fair'
                ELSE 'poor'
            END as quality_classification
        FROM shared_quantities sq
    )
    SELECT 
        -- Quantity information as JSONB
        jsonb_build_object(
            'id', cs.quantity_id,
            'code', cs.quantity_code,
            'name', cs.quantity_name,
            'unit', cs.unit,
            'category', cs.category,
            'data_type', cs.data_type,
            'aggregation_method', cs.aggregation_method,
            'description', cs.description,
            'is_active', cs.quantity_active
        ) as quantity,
        
        -- Sharing statistics as JSONB
        jsonb_build_object(
            'total_devices_checked', v_total_requested_devices,
            'devices_with_data', cs.device_count,
            'sharing_percentage', 100.0, -- Always 100% for shared quantities
            'total_measurements', cs.total_measurements,
            'measurements_per_device', ROUND(cs.total_measurements::decimal / cs.device_count, 2),
            'devices_with_data_ids', cs.devices_with_data
        ) as sharing_stats,
        
        -- Data quality information as JSONB
        jsonb_build_object(
            'overall_quality_score', ROUND(cs.overall_quality_score, 3),
            'quality_classification', cs.quality_classification,
            'meets_quality_threshold', cs.overall_quality_score >= p_min_data_quality_score,
            'data_coverage_percentage', cs.data_coverage_percentage
        ) as data_quality,
        
        -- Coverage analysis as JSONB
        jsonb_build_object(
            'time_window_hours', p_time_window_hours,
            'earliest_measurement', cs.earliest_measurement,
            'latest_measurement', cs.latest_measurement,
            'total_days_with_data', cs.total_days_with_data,
            'data_freshness_hours', EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - cs.latest_measurement)) / 3600,
            'data_span_days', EXTRACT(DAYS FROM (cs.latest_measurement - cs.earliest_measurement))
        ) as coverage_analysis
        
    FROM coverage_stats cs
    ORDER BY cs.overall_quality_score DESC, cs.total_measurements DESC;
    
END;
$$;


--
-- Name: get_shared_quantities_stats(integer, integer[], integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_shared_quantities_stats(p_user_id integer, p_device_ids integer[], p_tenant_id integer DEFAULT NULL::integer, p_time_window_hours integer DEFAULT 168) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_result jsonb;
    v_tenant_filter integer[];
    v_cutoff_timestamp timestamp;
    v_total_devices integer;
    v_total_quantities integer;
    v_fully_shared_quantities integer;
    v_partially_shared_quantities integer;
    v_unique_categories text[];
    v_avg_data_quality decimal;
BEGIN
    -- Setup and validation
    v_cutoff_timestamp := CURRENT_TIMESTAMP - (p_time_window_hours || ' hours')::INTERVAL;
    v_total_devices := array_length(p_device_ids, 1);
    
    -- Tenant validation
    IF p_tenant_id IS NOT NULL THEN
        v_tenant_filter := ARRAY[p_tenant_id];
    ELSE
        SELECT ARRAY_AGG(tenant_id) INTO v_tenant_filter
        FROM auth_user_tenants 
        WHERE user_id = p_user_id AND is_active = true;
    END IF;
    
    -- Calculate statistics
    WITH quantity_stats AS (
        SELECT 
            td.quantity_id,
            q.category,
            COUNT(DISTINCT td.device_id) as device_count,
            AVG(COALESCE(td.data_quality_score, 1.0)) as avg_quality
        FROM telemetry_data td
        INNER JOIN quantities q ON td.quantity_id = q.id
        WHERE td.device_id = ANY(p_device_ids)
          AND td.tenant_id = ANY(v_tenant_filter)
          AND td.recorded_timestamp >= v_cutoff_timestamp
          AND q.is_active = true
        GROUP BY td.quantity_id, q.category
    )
    SELECT 
        COUNT(DISTINCT quantity_id),
        COUNT(DISTINCT quantity_id) FILTER (WHERE device_count = v_total_devices),
        COUNT(DISTINCT quantity_id) FILTER (WHERE device_count > 1 AND device_count < v_total_devices),
        ARRAY_AGG(DISTINCT category),
        AVG(avg_quality)
    INTO 
        v_total_quantities,
        v_fully_shared_quantities,
        v_partially_shared_quantities,
        v_unique_categories,
        v_avg_data_quality
    FROM quantity_stats;
    
    -- Build result JSON
    v_result := jsonb_build_object(
        'analysis_timestamp', CURRENT_TIMESTAMP,
        'time_window_hours', p_time_window_hours,
        'devices_analyzed', v_total_devices,
        'total_quantities_found', COALESCE(v_total_quantities, 0),
        'fully_shared_quantities', COALESCE(v_fully_shared_quantities, 0),
        'partially_shared_quantities', COALESCE(v_partially_shared_quantities, 0),
        'unique_categories', COALESCE(v_unique_categories, ARRAY[]::text[]),
        'average_data_quality', ROUND(COALESCE(v_avg_data_quality, 0), 3),
        'sharing_completeness_percentage', 
            CASE 
                WHEN v_total_quantities > 0 THEN 
                    ROUND((v_fully_shared_quantities::decimal / v_total_quantities) * 100, 2)
                ELSE 0 
            END
    );
    
    RETURN v_result;
END;
$$;


--
-- Name: get_shared_quantities_summary(integer, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_shared_quantities_summary(p_user_id integer, p_tenant_id integer DEFAULT NULL::integer, p_days_back integer DEFAULT 30) RETURNS TABLE(category character varying, data_type character varying, total_quantities bigint, devices_using_category bigint, avg_quality_score numeric, total_measurements bigint, earliest_measurement timestamp without time zone, latest_measurement timestamp without time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
    v_tenant_filter integer[];
    v_cutoff_timestamp timestamp;
BEGIN
    -- Input validation
    IF p_days_back < 1 OR p_days_back > 365 THEN
        RAISE EXCEPTION 'Days back must be between 1 and 365';
    END IF;
    
    v_cutoff_timestamp := CURRENT_TIMESTAMP - (p_days_back || ' days')::INTERVAL;
    
    -- Tenant validation and filtering
    IF p_tenant_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM auth_user_tenants 
            WHERE user_id = p_user_id AND tenant_id = p_tenant_id AND is_active = true
        ) THEN
            RAISE EXCEPTION 'User does not have access to tenant %', p_tenant_id;
        END IF;
        v_tenant_filter := ARRAY[p_tenant_id];
    ELSE
        SELECT ARRAY_AGG(tenant_id) INTO v_tenant_filter
        FROM auth_user_tenants 
        WHERE user_id = p_user_id AND is_active = true;
        
        IF v_tenant_filter IS NULL THEN
            RAISE EXCEPTION 'User has no accessible tenants';
        END IF;
    END IF;
    
    -- Return summary data
    RETURN QUERY
    SELECT 
        q.category,
        q.data_type,
        COUNT(DISTINCT q.id) as total_quantities,
        COUNT(DISTINCT td.device_id) as devices_using_category,
        ROUND(AVG(COALESCE(td.quality, 1.0)), 3) as avg_quality_score,
        COUNT(*) as total_measurements,
        MIN(td.timestamp) as earliest_measurement,
        MAX(td.timestamp) as latest_measurement
    FROM quantities q
    LEFT JOIN telemetry_data td ON q.id = td.quantity_id
    WHERE q.is_active = true
      AND td.timestamp >= v_cutoff_timestamp
      AND td.tenant_id = ANY(v_tenant_filter)
    GROUP BY q.category, q.data_type
    HAVING COUNT(*) > 0
    ORDER BY total_measurements DESC;
END;
$$;


--
-- Name: get_shift_period(integer, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_shift_period(p_tenant_id integer, p_timestamp timestamp without time zone) RETURNS character varying
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    local_hour INTEGER;
    shift_name VARCHAR(50);
BEGIN
    -- Convert to local time (assuming Asia/Jakarta timezone)
    local_hour := EXTRACT(HOUR FROM (p_timestamp AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Jakarta'));
    
    -- Look up shift based on hour - handle cross-midnight shifts properly
    SELECT tsp.shift_name INTO shift_name
    FROM tenant_shift_periods tsp
    WHERE tsp.tenant_id = p_tenant_id
      AND tsp.is_active = true
      AND (tsp.effective_to IS NULL OR tsp.effective_to >= CURRENT_DATE)
      AND tsp.effective_from <= CURRENT_DATE
      AND (
          -- Normal shift: start_hour < end_hour (e.g., 7 to 15)
          (tsp.start_hour < tsp.end_hour AND local_hour >= tsp.start_hour AND local_hour < tsp.end_hour)
          OR
          -- Cross-midnight shift: start_hour > end_hour (e.g., 23 to 7)  
          (tsp.start_hour > tsp.end_hour AND (local_hour >= tsp.start_hour OR local_hour < tsp.end_hour))
          OR
          -- Edge case: start_hour = end_hour (24-hour shift)
          (tsp.start_hour = tsp.end_hour)
      )
    ORDER BY 
        -- Prioritize more specific (shorter) shifts over longer ones
        CASE 
            WHEN tsp.start_hour < tsp.end_hour THEN tsp.end_hour - tsp.start_hour
            WHEN tsp.start_hour > tsp.end_hour THEN (24 - tsp.start_hour) + tsp.end_hour
            ELSE 24
        END ASC
    LIMIT 1;
    
    RETURN COALESCE(shift_name, 'UNKNOWN');
END;
$$;


--
-- Name: get_telemetry_aggregation_for_user(integer, integer, integer, character varying, timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_telemetry_aggregation_for_user(p_user_id integer, p_device_id integer, p_quantity_id integer, p_aggregation_method character varying, p_start_time timestamp with time zone, p_end_time timestamp with time zone) RETURNS TABLE(device_id integer, quantity_id integer, aggregation_method character varying, aggregated_value double precision, sample_count integer, start_time timestamp with time zone, end_time timestamp with time zone, data_source character varying, unit character varying, quality_average double precision)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    user_tenant_ids INTEGER[];
    device_tenant_id INTEGER;
    quantity_info RECORD;
    is_cumulative_quantity BOOLEAN := FALSE;
    cumulative_quantity_ids INTEGER[] := ARRAY[62, 89, 96, 124, 130];
BEGIN
    -- Get user's accessible tenant IDs
    SELECT ARRAY(
        SELECT tenant_id 
        FROM auth_user_tenant 
        WHERE user_id = p_user_id AND is_active = true
    ) INTO user_tenant_ids;
    
    -- Validate user has tenants
    IF array_length(user_tenant_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'User has no accessible tenants';
    END IF;
    
    -- Get device tenant and validate access
    SELECT tenant_id INTO device_tenant_id
    FROM devices 
    WHERE id = p_device_id;
    
    IF device_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Device not found';
    END IF;
    
    IF NOT (device_tenant_id = ANY(user_tenant_ids)) THEN
        RAISE EXCEPTION 'Access denied to device';
    END IF;
    
    -- Get quantity information
    SELECT q.unit, q.quantity_code
    INTO quantity_info
    FROM quantities q
    WHERE q.id = p_quantity_id;
    
    IF quantity_info IS NULL THEN
        RAISE EXCEPTION 'Quantity not found';
    END IF;
    
    -- Check if this is a cumulative quantity
    is_cumulative_quantity := p_quantity_id = ANY(cumulative_quantity_ids);
    
    -- Validate aggregation method
    IF p_aggregation_method NOT IN ('sum', 'avg', 'min', 'max') THEN
        RAISE EXCEPTION 'Invalid aggregation method. Must be: sum, avg, min, max';
    END IF;
    
    -- Perform aggregation based on data source
    IF is_cumulative_quantity THEN
        -- Use consumption interval data for cumulative quantities
        RETURN QUERY
        WITH interval_data AS (
            SELECT 
                qi.bucket as timestamp,
                qi.interval_energy as value,
                1 as quality -- Consumption intervals have quality of 1
            FROM get_quantities_interval(
                p_user_id,
                ARRAY[p_device_id],
                ARRAY[p_quantity_id],
                p_start_time,
                p_end_time,
                false, -- auto_adjust_start
                false  -- fill_missing_intervals
            ) qi
            WHERE qi.device_id = p_device_id 
            AND qi.quantity_id = p_quantity_id
            AND qi.interval_energy IS NOT NULL
        )
        SELECT 
            p_device_id,
            p_quantity_id,
            p_aggregation_method,
            CASE 
                WHEN p_aggregation_method = 'sum' THEN COALESCE(SUM(id.value), 0)
                WHEN p_aggregation_method = 'avg' THEN COALESCE(AVG(id.value), 0)
                WHEN p_aggregation_method = 'min' THEN COALESCE(MIN(id.value), 0)
                WHEN p_aggregation_method = 'max' THEN COALESCE(MAX(id.value), 0)
            END::DOUBLE PRECISION,
            COUNT(*)::INTEGER,
            p_start_time,
            p_end_time,
            'consumption'::VARCHAR(20),
            quantity_info.unit,
            AVG(id.quality)::DOUBLE PRECISION
        FROM interval_data id;
        
    ELSE
        -- Use 15-minute aggregated data for standard quantities
        RETURN QUERY
        WITH aggregated_data AS (
            SELECT 
                at.bucket as timestamp,
                at.aggregated_value as value,
                at.sample_count,
                1.0 as quality -- 15-min aggregated data has quality of 1
            FROM get_aggregated_telemetry_for_user(
                p_user_id,
                ARRAY[p_device_id],
                ARRAY[p_quantity_id],
                p_start_time,
                p_end_time,
                NULL, -- limit
                NULL  -- offset
            ) at
            WHERE at.device_id = p_device_id 
            AND at.quantity_id = p_quantity_id
            AND at.aggregated_value IS NOT NULL
        )
        SELECT 
            p_device_id,
            p_quantity_id,
            p_aggregation_method,
            CASE 
                WHEN p_aggregation_method = 'sum' THEN COALESCE(SUM(ad.value), 0)
                WHEN p_aggregation_method = 'avg' THEN COALESCE(AVG(ad.value), 0)
                WHEN p_aggregation_method = 'min' THEN COALESCE(MIN(ad.value), 0)
                WHEN p_aggregation_method = 'max' THEN COALESCE(MAX(ad.value), 0)
            END::DOUBLE PRECISION,
            SUM(ad.sample_count)::INTEGER,
            p_start_time,
            p_end_time,
            '15min'::VARCHAR(20),
            quantity_info.unit,
            AVG(ad.quality)::DOUBLE PRECISION
        FROM aggregated_data ad;
        
    END IF;
    
EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Telemetry aggregation failed: %', SQLERRM;
END;
$$;


--
-- Name: FUNCTION get_telemetry_aggregation_for_user(p_user_id integer, p_device_id integer, p_quantity_id integer, p_aggregation_method character varying, p_start_time timestamp with time zone, p_end_time timestamp with time zone); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.get_telemetry_aggregation_for_user(p_user_id integer, p_device_id integer, p_quantity_id integer, p_aggregation_method character varying, p_start_time timestamp with time zone, p_end_time timestamp with time zone) IS 'Aggregates telemetry data for a device/quantity with configurable method (sum/avg/min/max). Uses 15-minute intervals for standard quantities and consumption intervals for cumulative quantities.';


--
-- Name: get_telemetry_statistics_for_user(integer, integer[], integer[], timestamp without time zone, timestamp without time zone, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_telemetry_statistics_for_user(p_user_id integer, p_device_ids integer[] DEFAULT NULL::integer[], p_quantity_ids integer[] DEFAULT NULL::integer[], p_start_time timestamp without time zone DEFAULT NULL::timestamp without time zone, p_end_time timestamp without time zone DEFAULT NULL::timestamp without time zone, p_tenant_id integer DEFAULT NULL::integer) RETURNS TABLE(device_count bigint, data_points_count bigint, earliest_timestamp timestamp without time zone, latest_timestamp timestamp without time zone, tenant_count bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    accessible_tenant_ids INTEGER[];
    filtered_device_ids INTEGER[];
BEGIN
    -- Validate user and get accessible tenants
    IF NOT EXISTS (
        SELECT 1 FROM auth_users 
        WHERE id = p_user_id AND is_active = true
    ) THEN
        RAISE EXCEPTION 'Invalid or inactive user: %', p_user_id;
    END IF;
    
    SELECT ARRAY_AGG(DISTINCT ut.tenant_id) INTO accessible_tenant_ids
    FROM auth_user_tenants ut
    JOIN auth_products p ON ut.product_id = p.id
    WHERE ut.user_id = p_user_id 
    AND ut.is_active = true
    AND (ut.expires_at IS NULL OR ut.expires_at > CURRENT_TIMESTAMP)
    AND p.is_active = true
    AND (
        'read_telemetry' = ANY(ut.permissions) OR
        'api_read' = ANY(ut.permissions)
    );
    
    IF accessible_tenant_ids IS NULL OR array_length(accessible_tenant_ids, 1) = 0 THEN
        -- Return empty statistics
        RETURN QUERY SELECT 0::BIGINT, 0::BIGINT, NULL::TIMESTAMP, NULL::TIMESTAMP, 0::BIGINT;
        RETURN;
    END IF;
    
    -- Filter by specific tenant if requested
    IF p_tenant_id IS NOT NULL THEN
        IF NOT (p_tenant_id = ANY(accessible_tenant_ids)) THEN
            RETURN QUERY SELECT 0::BIGINT, 0::BIGINT, NULL::TIMESTAMP, NULL::TIMESTAMP, 0::BIGINT;
            RETURN;
        END IF;
        accessible_tenant_ids := ARRAY[p_tenant_id];
    END IF;
    
    -- Filter devices
    IF p_device_ids IS NOT NULL THEN
        SELECT ARRAY_AGG(d.id) INTO filtered_device_ids
        FROM devices d
        WHERE d.id = ANY(p_device_ids)
        AND d.tenant_id = ANY(accessible_tenant_ids)
        AND d.is_active = true;
    END IF;
    
    -- Calculate statistics
    RETURN QUERY
    SELECT 
        COUNT(DISTINCT td.device_id) as device_count,
        COUNT(*) as data_points_count,
        MIN(td.timestamp) as earliest_timestamp,
        MAX(td.timestamp) as latest_timestamp,
        COUNT(DISTINCT d.tenant_id) as tenant_count
    FROM telemetry_data td
    JOIN devices d ON td.device_id = d.id
    WHERE d.tenant_id = ANY(accessible_tenant_ids)
      AND (filtered_device_ids IS NULL OR td.device_id = ANY(filtered_device_ids))
      AND (p_start_time IS NULL OR td.timestamp >= p_start_time)
      AND (p_end_time IS NULL OR td.timestamp <= p_end_time)
      AND (p_quantity_ids IS NULL OR td.quantity_id = ANY(p_quantity_ids))
      AND d.is_active = true;
    
END;
$$;


--
-- Name: FUNCTION get_telemetry_statistics_for_user(p_user_id integer, p_device_ids integer[], p_quantity_ids integer[], p_start_time timestamp without time zone, p_end_time timestamp without time zone, p_tenant_id integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.get_telemetry_statistics_for_user(p_user_id integer, p_device_ids integer[], p_quantity_ids integer[], p_start_time timestamp without time zone, p_end_time timestamp without time zone, p_tenant_id integer) IS 'Get telemetry statistics with user-based authentication';


--
-- Name: get_tenant_devices(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_tenant_devices(p_tenant_id integer) RETURNS TABLE(device_id integer, device_name character varying, device_type character varying, asset_name character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    -- Validate tenant
    IF NOT EXISTS (SELECT 1 FROM tenants WHERE id = p_tenant_id AND is_active = true) THEN
        RAISE EXCEPTION 'Invalid or inactive tenant: %', p_tenant_id;
    END IF;
    
    RETURN QUERY
    SELECT 
        d.id,
        d.device_name,
        d.device_type,
        a.asset_name
    FROM devices d
    LEFT JOIN assets a ON d.asset_id = a.id
    WHERE d.tenant_id = p_tenant_id 
      AND d.is_active = true
    ORDER BY d.device_name;
END;
$$;


--
-- Name: get_time_boundaries(character varying, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_time_boundaries(p_period character varying DEFAULT 'today'::character varying, p_timezone_offset integer DEFAULT 7) RETURNS TABLE(period_name character varying, period_start timestamp without time zone, period_end timestamp without time zone, shift1_start timestamp without time zone, shift1_end timestamp without time zone, shift2_start timestamp without time zone, shift2_end timestamp without time zone, shift3_part1_start timestamp without time zone, shift3_part1_end timestamp without time zone, shift3_part2_start timestamp without time zone, shift3_part2_end timestamp without time zone, peak_start timestamp without time zone, peak_end timestamp without time zone, offpeak1_start timestamp without time zone, offpeak1_end timestamp without time zone, offpeak2_start timestamp without time zone, offpeak2_end timestamp without time zone, scan_start timestamp without time zone, scan_end timestamp without time zone)
    LANGUAGE plpgsql
    AS $$
DECLARE
    day_offset INTEGER;
    is_week_to_date BOOLEAN := FALSE;
    base_date TIMESTAMP WITHOUT TIME ZONE;
    tz_interval INTERVAL;
    now_time TIMESTAMP WITHOUT TIME ZONE;
BEGIN
    -- Convert timezone offset to interval
    tz_interval := (p_timezone_offset || ' hours')::INTERVAL;
    
    -- Get current time without timezone for consistent handling
    now_time := NOW()::TIMESTAMP WITHOUT TIME ZONE;
    
    -- Determine day offset and period type
    CASE p_period
        WHEN 'today' THEN 
            day_offset := 0;
        WHEN 'yesterday' THEN 
            day_offset := 1;
        WHEN 'day_before_yesterday' THEN 
            day_offset := 2;
        WHEN 'week_to_date' THEN 
            day_offset := 0; 
            is_week_to_date := TRUE;
        WHEN 'month_to_date' THEN
            day_offset := 0;
            is_week_to_date := FALSE; -- Will add month logic
        ELSE 
            RAISE EXCEPTION 'Invalid period: %. Valid options: today, yesterday, day_before_yesterday, week_to_date, month_to_date', p_period;
    END CASE;
    
    IF is_week_to_date THEN
        -- Week-to-date boundaries
        RETURN QUERY
        SELECT 
            p_period::VARCHAR(20),
            -- Period boundaries (start of week in local time, converted to UTC)
            (DATE_TRUNC('week', now_time + tz_interval) - tz_interval)::TIMESTAMP WITHOUT TIME ZONE as period_start,
            now_time::TIMESTAMP WITHOUT TIME ZONE as period_end,
            -- Shifts (will be calculated dynamically using EXTRACT in main query)
            NULL::TIMESTAMP WITHOUT TIME ZONE as shift1_start,
            NULL::TIMESTAMP WITHOUT TIME ZONE as shift1_end,
            NULL::TIMESTAMP WITHOUT TIME ZONE as shift2_start,
            NULL::TIMESTAMP WITHOUT TIME ZONE as shift2_end,
            NULL::TIMESTAMP WITHOUT TIME ZONE as shift3_part1_start,
            NULL::TIMESTAMP WITHOUT TIME ZONE as shift3_part1_end,
            NULL::TIMESTAMP WITHOUT TIME ZONE as shift3_part2_start,
            NULL::TIMESTAMP WITHOUT TIME ZONE as shift3_part2_end,
            NULL::TIMESTAMP WITHOUT TIME ZONE as peak_start,
            NULL::TIMESTAMP WITHOUT TIME ZONE as peak_end,
            NULL::TIMESTAMP WITHOUT TIME ZONE as offpeak1_start,
            NULL::TIMESTAMP WITHOUT TIME ZONE as offpeak1_end,
            NULL::TIMESTAMP WITHOUT TIME ZONE as offpeak2_start,
            NULL::TIMESTAMP WITHOUT TIME ZONE as offpeak2_end,
            -- Scan boundaries
            (DATE_TRUNC('week', now_time + tz_interval) - tz_interval)::TIMESTAMP WITHOUT TIME ZONE as scan_start,
            now_time::TIMESTAMP WITHOUT TIME ZONE as scan_end;
    ELSE
        -- Daily period boundaries (today, yesterday, day_before_yesterday)
        base_date := (DATE_TRUNC('day', now_time + tz_interval) - (day_offset || ' days')::INTERVAL - tz_interval)::TIMESTAMP WITHOUT TIME ZONE;
        
        RETURN QUERY
        SELECT 
            p_period::VARCHAR(20),
            -- Period boundaries (full day in UTC)
            base_date::TIMESTAMP WITHOUT TIME ZONE as period_start,
            (base_date + INTERVAL '1 day')::TIMESTAMP WITHOUT TIME ZONE as period_end,
            -- Shift 1: 07:00 - 15:00 local = 00:00 - 08:00 UTC
            (base_date + tz_interval)::TIMESTAMP WITHOUT TIME ZONE as shift1_start,
            (base_date + tz_interval + INTERVAL '8 hours')::TIMESTAMP WITHOUT TIME ZONE as shift1_end,
            -- Shift 2: 15:00 - 23:00 local = 08:00 - 16:00 UTC  
            (base_date + tz_interval + INTERVAL '8 hours')::TIMESTAMP WITHOUT TIME ZONE as shift2_start,
            (base_date + tz_interval + INTERVAL '16 hours')::TIMESTAMP WITHOUT TIME ZONE as shift2_end,
            -- Shift 3 Part 1: 00:00 - 07:00 local = 17:00 UTC prev day to 00:00 UTC target day
            base_date::TIMESTAMP WITHOUT TIME ZONE as shift3_part1_start,
            (base_date + tz_interval)::TIMESTAMP WITHOUT TIME ZONE as shift3_part1_end,
            -- Shift 3 Part 2: 23:00 - 23:59 local = 16:00 - 17:00 UTC target day
            (base_date + tz_interval + INTERVAL '16 hours')::TIMESTAMP WITHOUT TIME ZONE as shift3_part2_start,
            (base_date + tz_interval + INTERVAL '17 hours')::TIMESTAMP WITHOUT TIME ZONE as shift3_part2_end,
            -- Peak: 18:00 - 22:00 local = 11:00 - 15:00 UTC
            (base_date + tz_interval + INTERVAL '11 hours')::TIMESTAMP WITHOUT TIME ZONE as peak_start,
            (base_date + tz_interval + INTERVAL '15 hours')::TIMESTAMP WITHOUT TIME ZONE as peak_end,
            -- Off Peak Part 1: 00:00 - 18:00 local = 17:00 UTC prev day to 11:00 UTC target day
            base_date::TIMESTAMP WITHOUT TIME ZONE as offpeak1_start,
            (base_date + tz_interval + INTERVAL '11 hours')::TIMESTAMP WITHOUT TIME ZONE as offpeak1_end,
            -- Off Peak Part 2: 22:00 - 23:59 local = 15:00 - 17:00 UTC target day
            (base_date + tz_interval + INTERVAL '15 hours')::TIMESTAMP WITHOUT TIME ZONE as offpeak2_start,
            (base_date + tz_interval + INTERVAL '17 hours')::TIMESTAMP WITHOUT TIME ZONE as offpeak2_end,
            -- Scan boundaries (include full day range)
            base_date::TIMESTAMP WITHOUT TIME ZONE as scan_start,
            (base_date + INTERVAL '1 day')::TIMESTAMP WITHOUT TIME ZONE as scan_end;
    END IF;
END;
$$;


--
-- Name: get_unified_telemetry_for_user(integer, integer[], timestamp without time zone, timestamp without time zone, integer[], integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_unified_telemetry_for_user(p_user_id integer, p_device_ids integer[] DEFAULT NULL::integer[], p_start_time timestamp without time zone DEFAULT NULL::timestamp without time zone, p_end_time timestamp without time zone DEFAULT NULL::timestamp without time zone, p_quantity_ids integer[] DEFAULT NULL::integer[], p_limit integer DEFAULT 10000, p_tenant_id integer DEFAULT NULL::integer) RETURNS TABLE("timestamp" timestamp without time zone, tenant_id integer, device_id integer, device_name character varying, quantity_id integer, quantity_code character varying, quantity_name character varying, unit character varying, display_value numeric, raw_value numeric, quality integer, sample_count bigint, source_system character varying, is_cumulative boolean, data_source character varying)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    accessible_tenant_ids INTEGER[];
    filtered_device_ids INTEGER[];
    time_range_hours NUMERIC;
    use_raw_data BOOLEAN := FALSE;
BEGIN
    -- 1. Validate user exists and is active
    IF NOT EXISTS (
        SELECT 1 FROM auth_users 
        WHERE id = p_user_id AND is_active = true
    ) THEN
        RAISE EXCEPTION 'Invalid or inactive user: %', p_user_id;
    END IF;
    
    -- 2. Get user's accessible tenant IDs with telemetry read permission
    SELECT ARRAY_AGG(DISTINCT ut.tenant_id) INTO accessible_tenant_ids
    FROM auth_user_tenants ut
    JOIN auth_products p ON ut.product_id = p.id
    WHERE ut.user_id = p_user_id 
    AND ut.is_active = true
    AND (ut.expires_at IS NULL OR ut.expires_at > CURRENT_TIMESTAMP)
    AND p.is_active = true
    AND (
        'read_telemetry' = ANY(ut.permissions) OR
        'api_read' = ANY(ut.permissions) OR
        'api_access' = ANY(ut.permissions)
    );
    
    -- Check if user has any tenant access
    IF accessible_tenant_ids IS NULL OR array_length(accessible_tenant_ids, 1) = 0 THEN
        RAISE EXCEPTION 'User % has no telemetry access to any tenants', p_user_id;
    END IF;
    
    -- 3. If specific tenant requested, validate access
    IF p_tenant_id IS NOT NULL THEN
        IF NOT (p_tenant_id = ANY(accessible_tenant_ids)) THEN
            RAISE EXCEPTION 'User % does not have access to tenant %', p_user_id, p_tenant_id;
        END IF;
        accessible_tenant_ids := ARRAY[p_tenant_id];
    END IF;
    
    -- 4. Validate device ownership and filter to accessible devices
    IF p_device_ids IS NOT NULL THEN
        SELECT ARRAY_AGG(d.id) INTO filtered_device_ids
        FROM devices d
        WHERE d.id = ANY(p_device_ids)
        AND d.tenant_id = ANY(accessible_tenant_ids)
        AND d.is_active = true;
        
        IF filtered_device_ids IS NULL OR array_length(filtered_device_ids, 1) = 0 THEN
            RAISE EXCEPTION 'No accessible devices found for user %', p_user_id;
        END IF;
    ELSE
        filtered_device_ids := NULL;
    END IF;
    
    -- 5. Determine data source based on time range
    IF p_start_time IS NOT NULL AND p_end_time IS NOT NULL THEN
        time_range_hours := EXTRACT(EPOCH FROM (p_end_time - p_start_time)) / 3600;
        use_raw_data := time_range_hours <= 1; -- Use raw data for <= 1 hour
    ELSE
        use_raw_data := FALSE; -- Default to aggregated data
    END IF;
    
    -- 6. Log data access for audit
    INSERT INTO audit_logs (tenant_id, user_id, action_type, resource_type, action_description)
    SELECT 
        unnest(accessible_tenant_ids),
        p_user_id,
        'DATA_ACCESS',
        'UNIFIED_TELEMETRY',
        format('Unified telemetry access - Source: %s, Devices: %s, Time: %s to %s', 
               CASE WHEN use_raw_data THEN 'RAW' ELSE '15MIN' END,
               COALESCE(array_to_string(filtered_device_ids, ','), 'ALL'),
               p_start_time, p_end_time);
    
    -- 7. Return data from appropriate source
    IF use_raw_data THEN
        -- Use raw data materialized view with device name join
        RETURN QUERY
        SELECT 
            tur.timestamp,
            tur.tenant_id,
            tur.device_id,
            d.device_name,
            tur.quantity_id,
            tur.quantity_code,
            tur.quantity_name,
            tur.unit,
            tur.display_value,
            tur.raw_value,
            tur.quality,
            1::bigint AS sample_count, -- Raw data always has 1 sample
            tur.source_system,
            tur.is_cumulative,
            'raw'::character varying AS data_source
        FROM telemetry_unified_raw tur
        JOIN devices d ON tur.device_id = d.id
        WHERE tur.tenant_id = ANY(accessible_tenant_ids)
          AND (filtered_device_ids IS NULL OR tur.device_id = ANY(filtered_device_ids))
          AND (p_start_time IS NULL OR tur.timestamp >= p_start_time)
          AND (p_end_time IS NULL OR tur.timestamp <= p_end_time)
          AND (p_quantity_ids IS NULL OR tur.quantity_id = ANY(p_quantity_ids))
        ORDER BY tur.timestamp DESC
        LIMIT p_limit;
    ELSE
        -- Use 15-minute aggregated materialized view with device name join
        RETURN QUERY
        SELECT 
            tu15.bucket AS timestamp,
            tu15.tenant_id,
            tu15.device_id,
            d.device_name,
            tu15.quantity_id,
            tu15.quantity_code,
            tu15.quantity_name,
            tu15.unit,
            tu15.display_value,
            tu15.raw_value,
            NULL::integer AS quality, -- Quality not available in aggregated data
            tu15.sample_count,
            tu15.source_system,
            tu15.is_cumulative,
            '15min'::character varying AS data_source
        FROM telemetry_unified_15min tu15
        JOIN devices d ON tu15.device_id = d.id
        WHERE tu15.tenant_id = ANY(accessible_tenant_ids)
          AND (filtered_device_ids IS NULL OR tu15.device_id = ANY(filtered_device_ids))
          AND (p_start_time IS NULL OR tu15.bucket >= p_start_time)
          AND (p_end_time IS NULL OR tu15.bucket <= p_end_time)
          AND (p_quantity_ids IS NULL OR tu15.quantity_id = ANY(p_quantity_ids))
        ORDER BY tu15.bucket DESC
        LIMIT p_limit;
    END IF;
    
EXCEPTION
    WHEN OTHERS THEN
        -- Log error for debugging
        INSERT INTO audit_logs (user_id, action_type, resource_type, action_description)
        VALUES (p_user_id, 'DATA_ACCESS_ERROR', 'UNIFIED_TELEMETRY', 
                format('Unified telemetry access failed: %s', SQLERRM));
        RAISE;
END;
$$;


--
-- Name: get_upstream_sources(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_upstream_sources(target_asset_id integer) RETURNS TABLE(asset_id integer, asset_name character varying, utility_type character varying, distance_levels integer, connection_path text)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE upstream_trace AS (
        -- Non-recursive term: Start from target asset
        SELECT 
            a.id, 
            a.asset_name, 
            a.utility_type, 
            a.parent_id, 
            0 as level,
            a.asset_name::TEXT as path
        FROM assets a 
        WHERE a.id = target_asset_id
        
        UNION ALL
        
        -- Single recursive term: Follow BOTH hierarchy and connections
        SELECT 
            a.id, 
            a.asset_name, 
            a.utility_type, 
            a.parent_id, 
            ut.level + 1,
            (a.asset_name || ' -> ' || ut.path)::TEXT
        FROM assets a
        JOIN upstream_trace ut ON (
            -- Follow parent hierarchy within same utility
            (a.id = ut.parent_id AND a.utility_type = ut.utility_type)
            OR
            -- Follow connection sources (cross-utility or multi-source)
            EXISTS (
                SELECT 1 FROM asset_connections ac 
                WHERE ac.source_asset_id = a.id 
                AND ac.target_asset_id = ut.id 
                AND ac.is_active = true
            )
        )
        WHERE ut.level < 20 -- Prevent infinite loops
    )
    SELECT 
        DISTINCT ut.id, 
        ut.asset_name, 
        ut.utility_type, 
        ut.level,
        ut.path
    FROM upstream_trace ut
    WHERE ut.id != target_asset_id -- Exclude the starting asset
    AND ut.parent_id IS NULL  -- Top-level sources only
    ORDER BY ut.level, ut.utility_type, ut.asset_name;
END;
$$;


--
-- Name: get_user_permissions(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_permissions(p_user_id integer, p_tenant_id integer DEFAULT NULL::integer) RETURNS TABLE(permission_code character varying)
    LANGUAGE sql
    AS $$
WITH RECURSIVE role_hierarchy AS (
    -- Base case: direct role assignments
    SELECT 
        r.id, 
        r.parent_role_id, 
        p.permission_code,
        ta.tenant_id, 
        0 as level
    FROM auth_user_tenants ta
    JOIN auth_roles r ON ta.role = r.role_code
    JOIN auth_role_permissions rp ON r.id = rp.role_id
    JOIN auth_permissions p ON rp.permission_id = p.id
    WHERE ta.user_id = p_user_id 
      AND ta.is_active = true
      AND r.is_active = true
      AND p.is_active = true
      AND (p_tenant_id IS NULL OR ta.tenant_id = p_tenant_id)
      AND (ta.expires_at IS NULL OR ta.expires_at > CURRENT_TIMESTAMP)
    
    UNION ALL
    
    -- Recursive case: parent roles
    SELECT 
        pr.id, 
        pr.parent_role_id, 
        pp.permission_code,
        rh.tenant_id, 
        rh.level + 1
    FROM auth_roles pr
    JOIN role_hierarchy rh ON pr.id = rh.parent_role_id
    JOIN auth_role_permissions prp ON pr.id = prp.role_id
    JOIN auth_permissions pp ON prp.permission_id = pp.id
    WHERE rh.level < 10  -- Prevent infinite recursion
      AND pr.is_active = true
      AND pp.is_active = true
)
SELECT DISTINCT permission_code
FROM role_hierarchy 
WHERE permission_code IS NOT NULL;
$$;


--
-- Name: FUNCTION get_user_permissions(p_user_id integer, p_tenant_id integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.get_user_permissions(p_user_id integer, p_tenant_id integer) IS 'Get all permissions for user in specific tenant with role hierarchy resolution (tenant_id can be NULL for all tenants)';


--
-- Name: get_user_roles_for_tenant(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_roles_for_tenant(p_user_id integer, p_tenant_id integer) RETURNS TABLE(role_id integer, role_code character varying, role_name character varying, assigned_at timestamp without time zone, expires_at timestamp without time zone, granted_by integer)
    LANGUAGE sql
    AS $$
SELECT 
    r.id as role_id,
    r.role_code,
    r.role_name,
    ta.created_at as assigned_at,
    ta.expires_at,
    ta.granted_by
FROM auth_user_tenants ta
JOIN auth_roles r ON ta.role = r.role_code
WHERE ta.user_id = p_user_id
  AND ta.tenant_id = p_tenant_id
  AND ta.is_active = true
  AND r.is_active = true
  AND (ta.expires_at IS NULL OR ta.expires_at > CURRENT_TIMESTAMP)
ORDER BY ta.created_at;
$$;


--
-- Name: FUNCTION get_user_roles_for_tenant(p_user_id integer, p_tenant_id integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.get_user_roles_for_tenant(p_user_id integer, p_tenant_id integer) IS 'Get all roles assigned to user for specific tenant';


--
-- Name: get_user_tenant_ids(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_tenant_ids(p_user_id integer) RETURNS integer[]
    LANGUAGE plpgsql
    AS $$
DECLARE
    tenant_ids INTEGER[];
BEGIN
    SELECT ARRAY_AGG(DISTINCT ta.tenant_id) INTO tenant_ids
    FROM auth_user_tenants ta
    JOIN auth_roles r ON ta.role = r.role_code
    JOIN tenants t ON ta.tenant_id = t.id
    WHERE ta.user_id = p_user_id
      AND ta.is_active = true
      AND r.is_active = true
      AND t.is_active = true
      AND (ta.expires_at IS NULL OR ta.expires_at > CURRENT_TIMESTAMP);
    
    RETURN COALESCE(tenant_ids, ARRAY[]::INTEGER[]);
END;
$$;


--
-- Name: FUNCTION get_user_tenant_ids(p_user_id integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.get_user_tenant_ids(p_user_id integer) IS 'Get array of tenant IDs user has access to (role-based)';


--
-- Name: get_user_tenant_summary(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_tenant_summary(p_user_id integer) RETURNS TABLE(tenant_id integer, tenant_name character varying, tenant_slug character varying, role_assignments jsonb, permission_count integer)
    LANGUAGE sql
    AS $$
SELECT 
    t.id as tenant_id,
    t.tenant_name,
    t.tenant_code as tenant_slug,
    jsonb_agg(
        jsonb_build_object(
            'role_id', r.id,
            'role_name', r.role_name,
            'role_code', r.role_code,
            'assigned_at', ta.created_at,
            'expires_at', ta.expires_at,
            'granted_by', ta.granted_by
        )
    ) as role_assignments,
    (
        SELECT COUNT(DISTINCT permission_code) 
        FROM get_user_permissions(p_user_id, t.id)
    ) as permission_count
FROM auth_user_tenants ta
JOIN tenants t ON ta.tenant_id = t.id
JOIN auth_roles r ON ta.role = r.role_code
WHERE ta.user_id = p_user_id 
  AND ta.is_active = true
  AND r.is_active = true
  AND t.is_active = true
  AND (ta.expires_at IS NULL OR ta.expires_at > CURRENT_TIMESTAMP)
GROUP BY t.id, t.tenant_name, t.tenant_code
ORDER BY t.tenant_name;
$$;


--
-- Name: FUNCTION get_user_tenant_summary(p_user_id integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.get_user_tenant_summary(p_user_id integer) IS 'Get comprehensive tenant summary for user including roles and permission counts';


--
-- Name: get_utility_rate(integer, integer, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_utility_rate(p_tenant_id integer, p_device_id integer, p_timestamp timestamp without time zone) RETURNS TABLE(rate_per_unit numeric, rate_code character varying, utility_source_id integer)
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    local_hour INTEGER;
    local_dow INTEGER;
BEGIN
    -- Convert to local time
    local_hour := EXTRACT(HOUR FROM (p_timestamp AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Jakarta'));
    local_dow := EXTRACT(DOW FROM (p_timestamp AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Jakarta')) + 1; -- Convert 0-6 to 1-7
    
    RETURN QUERY
    SELECT 
        ur.rate_per_unit,
        ur.rate_code,
        us.id as utility_source_id
    FROM device_utility_mappings dum
    JOIN utility_sources us ON dum.utility_source_id = us.id
    JOIN utility_rates ur ON us.id = ur.utility_source_id
    WHERE dum.device_id = p_device_id
      AND us.tenant_id = p_tenant_id  -- Add tenant_id filter for utility sources
      AND ur.tenant_id = p_tenant_id -- Add tenant_id filter for utility rates
	  AND dum.is_active = true
      AND (dum.effective_to IS NULL OR dum.effective_to >= CURRENT_DATE)
      AND dum.effective_from <= CURRENT_DATE
      AND us.is_active = true  -- Also check utility source is active
      AND ur.is_active = true
      AND (ur.effective_to IS NULL OR ur.effective_to >= CURRENT_DATE)
      AND ur.effective_from <= CURRENT_DATE
      AND (
          -- Time of Use rates
          (ur.rate_structure = 'TIME_OF_USE' 
		   AND 
		   (-- Normal range: start_hour < end_hour (e.g., 9 to 17)
			(ur.start_hour < ur.end_hour AND local_hour >= ur.start_hour AND local_hour < ur.end_hour)
			OR
			-- Cross-midnight range: start_hour > end_hour (e.g., 22 to 6)
			(ur.start_hour > ur.end_hour AND (local_hour >= ur.start_hour OR local_hour < ur.end_hour)))
           AND local_dow = ANY(ur.applies_to_days))
          OR
          -- Flat rates (no time restrictions)
          (ur.rate_structure = 'FLAT')
      )
    ORDER BY dum.priority_order, ur.rate_per_unit DESC
    LIMIT 1;
END;
$$;


--
-- Name: is_cumulative_quantity(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_cumulative_quantity(quantity_code_param character varying) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $$
BEGIN
    RETURN quantity_code_param IN (
        'ENERGY_DEL', 'ENERGY_REC', 'WATER_VOLUME', 'GAS_VOLUME'
        -- Add other cumulative quantities as needed
    );
END;
$$;


--
-- Name: process_detected_gap(integer, integer, integer, timestamp without time zone, timestamp without time zone, timestamp without time zone, numeric, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.process_detected_gap(p_tenant_id integer, p_device_id integer, p_quantity_id integer, p_gap_start timestamp without time zone, p_gap_end timestamp without time zone, p_original_bucket timestamp without time zone, p_original_value numeric, p_processed_by character varying DEFAULT 'SYSTEM'::character varying) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    gap_id INTEGER;
    gap_duration_hours NUMERIC;
    redistribution_method VARCHAR(50);
    pattern_confidence VARCHAR(20);
    intervals_count INTEGER;
BEGIN
    -- Calculate gap duration
    gap_duration_hours := EXTRACT(EPOCH FROM (p_gap_end - p_gap_start)) / 3600.0;
    intervals_count := CEIL(gap_duration_hours * 4)::INTEGER; -- 4 intervals per hour (15-min each)
    
    -- Determine redistribution method based on available patterns
    SELECT 
        CASE 
            WHEN COUNT(*) FILTER (WHERE dcp.pattern_confidence IN ('HIGH', 'MEDIUM')) >= (intervals_count * 0.75) 
            THEN 'WEIGHTED_PATTERN'
            
            WHEN COUNT(*) FILTER (WHERE dcp.pattern_confidence IN ('HIGH', 'MEDIUM', 'LOW')) >= (intervals_count * 0.5)
            THEN 'SIMPLE_PATTERN'
            
            ELSE 'LINEAR'
        END,
        CASE 
            WHEN COUNT(*) FILTER (WHERE dcp.pattern_confidence = 'HIGH') >= (intervals_count * 0.5) 
            THEN 'HIGH'
            WHEN COUNT(*) FILTER (WHERE dcp.pattern_confidence IN ('HIGH', 'MEDIUM')) >= (intervals_count * 0.5)
            THEN 'MEDIUM'
            ELSE 'LOW'
        END
    INTO redistribution_method, pattern_confidence
    FROM generate_series(p_gap_start, p_gap_end - INTERVAL '15 minutes', INTERVAL '15 minutes') as gap_intervals(bucket)
    LEFT JOIN device_consumption_patterns dcp ON (
        dcp.tenant_id = p_tenant_id
        AND dcp.device_id = p_device_id  
        AND dcp.quantity_id = p_quantity_id
        AND dcp.hour_of_day = EXTRACT(HOUR FROM gap_intervals.bucket)
        AND dcp.day_of_week = EXTRACT(DOW FROM gap_intervals.bucket)
    );
    
    -- Insert gap record
    INSERT INTO processed_gaps (
        tenant_id, device_id, quantity_id,
        gap_start, gap_end, gap_duration_hours,
        original_bucket, original_interval_value,
        redistribution_method, pattern_confidence_used,
        total_intervals_redistributed,
        processed_by
    ) VALUES (
        p_tenant_id, p_device_id, p_quantity_id,
        p_gap_start, p_gap_end, gap_duration_hours,
        p_original_bucket, p_original_value,
        redistribution_method, pattern_confidence,
        intervals_count,
        p_processed_by
    ) RETURNING id INTO gap_id;
    
    -- Perform redistribution and insert intervals
    PERFORM redistribute_gap_intervals(gap_id, redistribution_method);
    
    RETURN gap_id;
END;
$$;


--
-- Name: redistribute_gap_intervals(integer, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.redistribute_gap_intervals(p_gap_id integer, p_redistribution_method character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    gap_record processed_gaps%ROWTYPE;
BEGIN
    -- Get gap details
    SELECT * INTO gap_record FROM processed_gaps WHERE id = p_gap_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Gap ID % not found', p_gap_id;
    END IF;
    
    -- Calculate redistribution based on method
    IF p_redistribution_method = 'WEIGHTED_PATTERN' THEN
        WITH gap_intervals AS (
            -- Generate intervals INCLUDING the end point
            SELECT ts as bucket
            FROM generate_series(
                gap_record.gap_start, 
                gap_record.gap_end + INTERVAL '1 minute',  -- Add small buffer to ensure inclusion
                INTERVAL '15 minutes'
            ) ts
            WHERE ts <= gap_record.gap_end  -- Filter to exact end point
        ),
        interval_patterns AS (
            SELECT 
                gi.bucket,
                EXTRACT(HOUR FROM gi.bucket) as hour_of_day,
                EXTRACT(DOW FROM gi.bucket) as day_of_week,
                COALESCE(dcp.avg_consumption_per_15min, 
                        (SELECT AVG(dcp2.avg_consumption_per_15min) 
                         FROM device_consumption_patterns dcp2 
                         WHERE dcp2.tenant_id = gap_record.tenant_id 
                         AND dcp2.device_id = gap_record.device_id 
                         AND dcp2.quantity_id = gap_record.quantity_id
                         AND dcp2.avg_consumption_per_15min > 0)) as expected_consumption,
                COALESCE(dcp.pattern_confidence, 'INSUFFICIENT') as confidence
            FROM gap_intervals gi
            LEFT JOIN device_consumption_patterns dcp ON (
                dcp.tenant_id = gap_record.tenant_id
                AND dcp.device_id = gap_record.device_id
                AND dcp.quantity_id = gap_record.quantity_id
                AND dcp.hour_of_day = EXTRACT(HOUR FROM gi.bucket)
                AND dcp.day_of_week = EXTRACT(DOW FROM gi.bucket)
            )
        ),
        weighted_distribution AS (
            SELECT 
                bucket,
                expected_consumption,
                confidence,
                CASE 
                    WHEN SUM(expected_consumption) OVER () > 0 
                    THEN expected_consumption / SUM(expected_consumption) OVER ()
                    ELSE 1.0 / COUNT(*) OVER ()  -- Fallback to linear if no patterns
                END as weight_factor
            FROM interval_patterns
        )
        INSERT INTO redistributed_intervals (
            gap_id, bucket, redistributed_value, confidence_score, 
            pattern_source, weight_factor, expected_pattern_value, actual_redistributed_value
        )
        SELECT 
            p_gap_id,
            bucket,
            gap_record.original_interval_value * weight_factor,
            CASE confidence 
                WHEN 'HIGH' THEN 0.9
                WHEN 'MEDIUM' THEN 0.7
                WHEN 'LOW' THEN 0.5
                ELSE 0.3
            END,
            'HISTORICAL_PATTERN',
            weight_factor,
            COALESCE(expected_consumption, 0),
            gap_record.original_interval_value * weight_factor
        FROM weighted_distribution;
        
    ELSE 
        -- LINEAR or SIMPLE_PATTERN fallback
        WITH gap_intervals AS (
            SELECT ts as bucket
            FROM generate_series(
                gap_record.gap_start, 
                gap_record.gap_end + INTERVAL '1 minute',
                INTERVAL '15 minutes'
            ) ts
            WHERE ts <= gap_record.gap_end
        )
        INSERT INTO redistributed_intervals (
            gap_id, bucket, redistributed_value, confidence_score, 
            pattern_source, weight_factor, actual_redistributed_value
        )
        SELECT 
            p_gap_id,
            gi.bucket,
            gap_record.original_interval_value / COUNT(*) OVER (),
            0.5,
            'LINEAR',
            1.0 / COUNT(*) OVER (),
            gap_record.original_interval_value / COUNT(*) OVER ()
        FROM gap_intervals gi;
    END IF;
    
    -- Debug log
    RAISE NOTICE 'Gap % redistributed across % intervals from % to %', 
        p_gap_id,
        (SELECT COUNT(*) FROM redistributed_intervals WHERE gap_id = p_gap_id),
        gap_record.gap_start,
        gap_record.gap_end;
END;
$$;


--
-- Name: refresh_daily_energy_costs(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_daily_energy_costs() RETURNS text
    LANGUAGE plpgsql
    AS $$
DECLARE
    jakarta_today DATE;
    start_time TIMESTAMP;
    end_time TIMESTAMP;
    refresh_start_time TIMESTAMP := clock_timestamp();
    row_count INTEGER;
    refresh_duration INTERVAL;
BEGIN
    -- Get current date in Jakarta timezone
    jakarta_today := (NOW() AT TIME ZONE 'Asia/Jakarta')::DATE;
    
    -- Convert Jakarta midnight to UTC for proper filtering
    start_time := (jakarta_today - INTERVAL '2 days')::TIMESTAMP AT TIME ZONE 'Asia/Jakarta' AT TIME ZONE 'UTC';
    end_time := (jakarta_today + INTERVAL '1 day')::TIMESTAMP AT TIME ZONE 'Asia/Jakarta' AT TIME ZONE 'UTC';
    
    RAISE NOTICE 'Starting daily energy cost refresh at %', refresh_start_time;
    RAISE NOTICE 'Refreshing data from % to % (UTC)', start_time, end_time;
    RAISE NOTICE 'Jakarta equivalent: % to %',
        start_time AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Jakarta',
        end_time AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Jakarta';
    
    -- Delete existing data for the refresh period
    DELETE FROM daily_energy_cost_summary
    WHERE daily_bucket >= start_time AND daily_bucket < end_time;
    
    -- Insert new hierarchical shift-rate data
    INSERT INTO daily_energy_cost_summary (
        daily_bucket,
        tenant_id,
        device_id,
        quantity_id,
        grouping_type,
        grouping_value,
        shift_period,
        rate_code,
        rate_per_unit,
        utility_source_id,
        total_consumption,
        interval_count,
        avg_interval_consumption,
        max_interval_consumption,
        min_interval_consumption,
        total_cost,
        last_refreshed,
        refresh_method
    )
    WITH hourly_data AS (
        SELECT
            time_bucket('1 day', tic.bucket AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Jakarta') AS daily_bucket,
            EXTRACT(HOUR FROM (tic.bucket AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Jakarta'))::INTEGER as local_hour,
            tic.tenant_id,
            tic.device_id,
            tic.quantity_id,
            tic.bucket as timestamp_sample,
            SUM(tic.interval_value) as total_consumption,
            COUNT(*)::NUMERIC as interval_count,
            AVG(tic.interval_value) as avg_interval_consumption,
            MAX(tic.interval_value) as max_interval_consumption,
            MIN(tic.interval_value) as min_interval_consumption
        FROM telemetry_intervals_cumulative tic
        WHERE tic.quantity_id = ANY (ARRAY[62, 89, 96, 124, 130, 481])
          AND tic.bucket >= start_time
          AND tic.bucket < end_time
        GROUP BY
            time_bucket('1 day', tic.bucket AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Jakarta'),
            local_hour,
            tic.tenant_id,
            tic.device_id,
            tic.quantity_id,
            tic.bucket
    ),
    enriched_data AS (
        SELECT
            hd.*,
            get_shift_period(hd.tenant_id, hd.timestamp_sample) as shift_period,
            (SELECT rate_code FROM get_utility_rate(hd.tenant_id, hd.device_id, hd.timestamp_sample) LIMIT 1) as rate_code,
            (SELECT rate_per_unit FROM get_utility_rate(hd.tenant_id, hd.device_id, hd.timestamp_sample) LIMIT 1) as rate_per_unit,
            (SELECT utility_source_id FROM get_utility_rate(hd.tenant_id, hd.device_id, hd.timestamp_sample) LIMIT 1) as utility_source_id
        FROM hourly_data hd
    ),
    shift_rate_aggregation AS (
        SELECT
            daily_bucket,
            tenant_id,
            device_id,
            quantity_id,
            'SHIFT_RATE'::TEXT as grouping_type,
            (shift_period || '-' || COALESCE(rate_code, 'NO_RATE'))::VARCHAR as grouping_value,
            shift_period,
            rate_code,
            -- Use average rate for the shift-rate combination
            AVG(rate_per_unit) as rate_per_unit,
            utility_source_id,
            -- Aggregate consumption and cost metrics
            SUM(total_consumption) as total_consumption,
            SUM(interval_count) as interval_count,
            AVG(avg_interval_consumption) as avg_interval_consumption,
            MAX(max_interval_consumption) as max_interval_consumption,
            MIN(min_interval_consumption) as min_interval_consumption,
            SUM(total_consumption * COALESCE(rate_per_unit, 0)) as total_cost
        FROM enriched_data
        WHERE shift_period IS NOT NULL  -- Ensure we have valid shift data
        GROUP BY
            daily_bucket,
            tenant_id,
            device_id,
            quantity_id,
            shift_period,
            rate_code,
            utility_source_id
    )
    SELECT
        daily_bucket,
        tenant_id,
        device_id,
        quantity_id,
        grouping_type,
        grouping_value,
        shift_period,
        rate_code,
        rate_per_unit,
        utility_source_id,
        total_consumption,
        interval_count,
        avg_interval_consumption,
        max_interval_consumption,
        min_interval_consumption,
        total_cost,
        NOW() AT TIME ZONE 'UTC' as last_refreshed,
        'CRON_REFRESH'::TEXT as refresh_method
    FROM shift_rate_aggregation
    WHERE total_consumption > 0 OR total_cost > 0;  -- Only include meaningful data
    
    GET DIAGNOSTICS row_count = ROW_COUNT;
    refresh_duration := clock_timestamp() - refresh_start_time;
    
    RAISE NOTICE 'Refresh completed in %. Processed % rows.', refresh_duration, row_count;
    
    RETURN format('SUCCESS: Refreshed %s rows in %s', row_count, refresh_duration);
    
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Refresh failed: %', SQLERRM;
    RETURN format('ERROR: %s', SQLERRM);
END;
$$;


--
-- Name: refresh_daily_energy_costs_with_logging(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_daily_energy_costs_with_logging() RETURNS text
    LANGUAGE plpgsql
    AS $$
DECLARE
    result_text TEXT;
    start_time TIMESTAMP := clock_timestamp();
    row_count INTEGER;
BEGIN
    -- Call the main refresh function
    result_text := refresh_daily_energy_costs();
    
    -- Extract row count from result (if successful)
    IF result_text LIKE 'SUCCESS:%' THEN
        row_count := (regexp_matches(result_text, 'Refreshed (\d+) rows'))[1]::INTEGER;
    ELSE
        row_count := 0;
    END IF;
    
    -- Log the result
    INSERT INTO daily_energy_refresh_log (result, duration, rows_processed)
    VALUES (result_text, clock_timestamp() - start_time, row_count);
    
    RETURN result_text;
END;
$$;


--
-- Name: refresh_device_consumption_patterns(integer, integer[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_device_consumption_patterns(p_tenant_id integer DEFAULT NULL::integer, p_device_ids integer[] DEFAULT NULL::integer[]) RETURNS TABLE(tenant_id integer, devices_processed integer, patterns_created integer, execution_time_ms integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    start_time TIMESTAMP := CURRENT_TIMESTAMP;
    tenant_rec RECORD;
BEGIN
    -- If specific tenant provided, validate it exists
    IF p_tenant_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM tenants WHERE id = p_tenant_id AND is_active = true) THEN
            RAISE EXCEPTION 'Invalid or inactive tenant: %', p_tenant_id;
        END IF;
    END IF;
    
    -- Log refresh with tenant context
    INSERT INTO audit_logs (tenant_id, action_type, resource_type, action_description)
    VALUES (p_tenant_id, 'PATTERN_REFRESH', 'SYSTEM', 
            format('Manual pattern refresh started for tenant: %s, devices: %s', 
                   COALESCE(p_tenant_id::TEXT, 'ALL'), 
                   COALESCE(array_to_string(p_device_ids, ','), 'ALL')));
    
    -- Refresh the materialized view
    REFRESH MATERIALIZED VIEW device_consumption_patterns;
    
    -- Return results per tenant
    FOR tenant_rec IN 
        SELECT t.id as tid
        FROM tenants t 
        WHERE (p_tenant_id IS NULL OR t.id = p_tenant_id)
        AND t.is_active = true
    LOOP
        RETURN QUERY
        SELECT 
            tenant_rec.tid,
            (SELECT COUNT(DISTINCT dcp.device_id)::INTEGER 
             FROM device_consumption_patterns dcp
             WHERE dcp.tenant_id = tenant_rec.tid
             AND (p_device_ids IS NULL OR dcp.device_id = ANY(p_device_ids))),
            (SELECT COUNT(*)::INTEGER 
             FROM device_consumption_patterns dcp
             WHERE dcp.tenant_id = tenant_rec.tid
             AND (p_device_ids IS NULL OR dcp.device_id = ANY(p_device_ids))),
            EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - start_time) * 1000)::INTEGER;
    END LOOP;
END;
$$;


--
-- Name: refresh_device_consumption_patterns_bootstrap(integer, integer[], boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_device_consumption_patterns_bootstrap(p_tenant_id integer DEFAULT NULL::integer, p_device_ids integer[] DEFAULT NULL::integer[], p_bootstrap_mode boolean DEFAULT false) RETURNS TABLE(phase text, devices_processed integer, patterns_created integer, gaps_detected integer, execution_time_ms integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    start_time TIMESTAMP := CURRENT_TIMESTAMP;
    gaps_exist BOOLEAN;
    gap_count INTEGER := 0;
    pattern_count INTEGER := 0;
    device_count INTEGER := 0;
BEGIN
    -- Check if gaps already exist
    SELECT COUNT(*) > 0 INTO gaps_exist 
    FROM processed_gaps 
    WHERE (p_tenant_id IS NULL OR tenant_id = p_tenant_id);
    
    IF p_bootstrap_mode OR NOT gaps_exist THEN
        -- BOOTSTRAP PHASE: Create initial patterns with all data
        
        DROP MATERIALIZED VIEW IF EXISTS device_consumption_patterns;
        
        CREATE MATERIALIZED VIEW device_consumption_patterns AS
        WITH weighted_data AS (
          SELECT 
            tc.tenant_id,
            tc.device_id,
            tc.quantity_id,
            EXTRACT(HOUR FROM tc.bucket) as hour_of_day,
            EXTRACT(DOW FROM tc.bucket) as day_of_week,
            tc.interval_value,
            tc.bucket,
            POWER(0.95, EXTRACT(DAY FROM (CURRENT_TIMESTAMP - tc.bucket))) as time_weight
          FROM telemetry_intervals_cumulative tc
          WHERE 
            tc.bucket >= GREATEST(
              CURRENT_TIMESTAMP - INTERVAL '1 month',
              (SELECT MIN(bucket) FROM telemetry_intervals_cumulative)
            )
            AND tc.interval_value IS NOT NULL
            AND tc.data_quality_flag = 'NORMAL'
            AND tc.interval_value >= 0
            -- BOOTSTRAP: Include all data for initial gap detection
        )
        SELECT 
          tenant_id, device_id, quantity_id, hour_of_day, day_of_week,
          SUM(interval_value * time_weight) / SUM(time_weight) as avg_consumption_per_15min,
          AVG(interval_value) as simple_avg_consumption,
          STDDEV(interval_value) as stddev_consumption,
          COUNT(*) as total_samples,
          SUM(time_weight) as weighted_sample_count,
          COUNT(*) FILTER (WHERE interval_value > 0) as non_zero_samples,
          CASE 
            WHEN SUM(time_weight) >= 8.0 THEN 'HIGH'
            WHEN SUM(time_weight) >= 4.0 THEN 'MEDIUM'   
            WHEN SUM(time_weight) >= 2.0 THEN 'LOW'
            ELSE 'INSUFFICIENT'
          END as pattern_confidence,
          MIN(interval_value) as min_consumption,
          MAX(interval_value) as max_consumption,
          PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY interval_value) as p75_consumption,
          COUNT(*) as raw_sample_count,
          MIN(bucket) as earliest_data,
          MAX(bucket) as latest_data,
          CURRENT_TIMESTAMP as calculated_at
        FROM weighted_data
        GROUP BY tenant_id, device_id, quantity_id, hour_of_day, day_of_week
        HAVING COUNT(*) >= 1
        ORDER BY tenant_id, device_id, quantity_id, day_of_week, hour_of_day;
        
        -- Create indexes
        CREATE INDEX idx_device_patterns_tenant_device ON device_consumption_patterns(tenant_id, device_id);
        CREATE INDEX idx_device_patterns_lookup ON device_consumption_patterns(tenant_id, device_id, quantity_id, day_of_week, hour_of_day);
        
        -- Grant permissions
        GRANT SELECT ON device_consumption_patterns TO "grafReader";
        
        GET DIAGNOSTICS pattern_count = ROW_COUNT;
        
        RETURN QUERY SELECT 
            'BOOTSTRAP_PATTERNS'::TEXT,
            (SELECT COUNT(DISTINCT device_id)::INTEGER FROM device_consumption_patterns 
             WHERE (p_tenant_id IS NULL OR tenant_id = p_tenant_id)),
            pattern_count,
            0,
            EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - start_time) * 1000)::INTEGER;
            
    ELSE
        -- CLEAN REBUILD PHASE: Create patterns excluding detected gaps
        
        DROP MATERIALIZED VIEW IF EXISTS device_consumption_patterns;
        
        CREATE MATERIALIZED VIEW device_consumption_patterns AS
        WITH clean_telemetry_data AS (
          SELECT 
            tc.tenant_id,
            tc.device_id,
            tc.quantity_id,
            EXTRACT(HOUR FROM tc.bucket) as hour_of_day,
            EXTRACT(DOW FROM tc.bucket) as day_of_week,
            tc.interval_value,
            tc.bucket,
            POWER(0.95, EXTRACT(DAY FROM (CURRENT_TIMESTAMP - tc.bucket))) as time_weight
          FROM telemetry_intervals_cumulative tc
          WHERE 
            tc.bucket >= GREATEST(
              CURRENT_TIMESTAMP - INTERVAL '1 month',
              (SELECT MIN(bucket) FROM telemetry_intervals_cumulative)
            )
            AND tc.interval_value IS NOT NULL
            AND tc.data_quality_flag = 'NORMAL'
            AND tc.interval_value >= 0
            -- EXCLUDE intervals within detected gaps
            AND NOT EXISTS (
              SELECT 1 FROM processed_gaps pg 
              WHERE pg.tenant_id = tc.tenant_id
                AND pg.device_id = tc.device_id
                AND pg.quantity_id = tc.quantity_id  
                AND tc.bucket BETWEEN pg.gap_start AND pg.gap_end
            )
        )
        SELECT 
          tenant_id, device_id, quantity_id, hour_of_day, day_of_week,
          SUM(interval_value * time_weight) / SUM(time_weight) as avg_consumption_per_15min,
          AVG(interval_value) as simple_avg_consumption,
          STDDEV(interval_value) as stddev_consumption,
          COUNT(*) as total_samples,
          SUM(time_weight) as weighted_sample_count,
          COUNT(*) FILTER (WHERE interval_value > 0) as non_zero_samples,
          CASE 
            WHEN SUM(time_weight) >= 8.0 THEN 'HIGH'
            WHEN SUM(time_weight) >= 4.0 THEN 'MEDIUM'   
            WHEN SUM(time_weight) >= 2.0 THEN 'LOW'
            ELSE 'INSUFFICIENT'
          END as pattern_confidence,
          MIN(interval_value) as min_consumption,
          MAX(interval_value) as max_consumption,
          PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY interval_value) as p75_consumption,
          COUNT(*) as raw_sample_count,
          MIN(bucket) as earliest_data,
          MAX(bucket) as latest_data,
          CURRENT_TIMESTAMP as calculated_at
        FROM clean_telemetry_data
        GROUP BY tenant_id, device_id, quantity_id, hour_of_day, day_of_week
        HAVING COUNT(*) >= 1
        ORDER BY tenant_id, device_id, quantity_id, day_of_week, hour_of_day;
        
        -- Recreate indexes and permissions
        CREATE INDEX idx_device_patterns_tenant_device ON device_consumption_patterns(tenant_id, device_id);
        CREATE INDEX idx_device_patterns_lookup ON device_consumption_patterns(tenant_id, device_id, quantity_id, day_of_week, hour_of_day);
        GRANT SELECT ON device_consumption_patterns TO "grafReader";
        
        GET DIAGNOSTICS pattern_count = ROW_COUNT;
        
        RETURN QUERY SELECT 
            'CLEAN_PATTERNS'::TEXT,
            (SELECT COUNT(DISTINCT device_id)::INTEGER FROM device_consumption_patterns 
             WHERE (p_tenant_id IS NULL OR tenant_id = p_tenant_id)),
            pattern_count,
            (SELECT COUNT(*)::INTEGER FROM processed_gaps 
             WHERE (p_tenant_id IS NULL OR tenant_id = p_tenant_id)),
            EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - start_time) * 1000)::INTEGER;
    END IF;
    
    -- Log the action
    INSERT INTO audit_logs (tenant_id, action_type, resource_type, action_description)
    VALUES (p_tenant_id, 'PATTERN_REFRESH', 'SYSTEM', 
            format('Bootstrap pattern refresh: mode=%s, gaps_existed=%s', 
                   p_bootstrap_mode, gaps_exist));
END;
$$;


--
-- Name: refresh_telemetry_unified_15min(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_telemetry_unified_15min() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY telemetry_unified_15min;
END;
$$;


--
-- Name: refresh_telemetry_unified_raw(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_telemetry_unified_raw() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY telemetry_unified_raw;
END;
$$;


--
-- Name: update_asset_metadata(integer, integer, character varying, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_asset_metadata(p_tenant_id integer, p_asset_id integer, p_asset_name character varying DEFAULT NULL::character varying, p_description text DEFAULT NULL::text, p_metadata jsonb DEFAULT NULL::jsonb) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    update_count INTEGER;
BEGIN
    -- Validate asset ownership
    IF NOT EXISTS (
        SELECT 1 FROM assets 
        WHERE id = p_asset_id AND tenant_id = p_tenant_id AND is_active = true
    ) THEN
        RAISE EXCEPTION 'Asset not found or access denied';
    END IF;
    
    -- Update asset
    UPDATE assets SET
        asset_name = COALESCE(p_asset_name, asset_name),
        description = COALESCE(p_description, description),
        metadata = COALESCE(p_metadata, metadata),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_asset_id AND tenant_id = p_tenant_id;
    
    GET DIAGNOSTICS update_count = ROW_COUNT;
    
    -- Log the action
    INSERT INTO audit_logs (
        tenant_id, 
        action_type, 
        resource_type, 
        resource_id,
        action_description
    ) VALUES (
        p_tenant_id, 
        'ASSET_UPDATE', 
        'ASSET', 
        p_asset_id::TEXT,
        format('Updated asset metadata for asset ID: %s', p_asset_id)
    );
    
    RETURN update_count > 0;
END;
$$;


--
-- Name: update_asset_path(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_asset_path() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    parent_path TEXT := '';
    new_depth INTEGER := 0;
BEGIN
    -- Get parent path and depth
    IF NEW.parent_id IS NOT NULL THEN
        SELECT path, level_depth + 1 
        INTO parent_path, new_depth
        FROM assets 
        WHERE id = NEW.parent_id;
        
        NEW.path := parent_path || '/' || NEW.id::TEXT;
        NEW.level_depth := new_depth;
    ELSE
        NEW.path := '/' || NEW.id::TEXT;
        NEW.level_depth := 0;
    END IF;
    
    RETURN NEW;
END;
$$;


--
-- Name: update_device_status(integer, integer, character varying, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_device_status(p_tenant_id integer, p_device_id integer, p_status character varying, p_last_maintenance timestamp without time zone DEFAULT NULL::timestamp without time zone, p_next_maintenance timestamp without time zone DEFAULT NULL::timestamp without time zone) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    update_count INTEGER;
BEGIN
    -- Validate device ownership
    IF NOT EXISTS (
        SELECT 1 FROM devices 
        WHERE id = p_device_id AND tenant_id = p_tenant_id
    ) THEN
        RAISE EXCEPTION 'Device not found or access denied';
    END IF;
    
    -- Validate status value
    IF p_status NOT IN ('ONLINE', 'OFFLINE', 'WARNING', 'MAINTENANCE', 'ERROR') THEN
        RAISE EXCEPTION 'Invalid device status: %', p_status;
    END IF;
    
    -- Update device status
    UPDATE devices SET
        status = p_status,
        last_maintenance = COALESCE(p_last_maintenance, last_maintenance),
        next_maintenance = COALESCE(p_next_maintenance, next_maintenance),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_device_id AND tenant_id = p_tenant_id;
    
    GET DIAGNOSTICS update_count = ROW_COUNT;
    
    -- Log the action
    INSERT INTO audit_logs (
        tenant_id, 
        action_type, 
        resource_type, 
        resource_id,
        action_description
    ) VALUES (
        p_tenant_id, 
        'DEVICE_STATUS_UPDATE', 
        'DEVICE', 
        p_device_id::TEXT,
        format('Updated device status to %s', p_status)
    );
    
    RETURN update_count > 0;
END;
$$;


--
-- Name: FUNCTION update_device_status(p_tenant_id integer, p_device_id integer, p_status character varying, p_last_maintenance timestamp without time zone, p_next_maintenance timestamp without time zone); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.update_device_status(p_tenant_id integer, p_device_id integer, p_status character varying, p_last_maintenance timestamp without time zone, p_next_maintenance timestamp without time zone) IS 'Update device operational status with maintenance tracking';


--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;


--
-- Name: update_utility_path(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_utility_path() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    parent_path TEXT := '';
    new_level INTEGER := 0;
BEGIN
    -- Get parent path and level within same utility type
    IF NEW.parent_id IS NOT NULL THEN
        SELECT utility_path, utility_level + 1 
        INTO parent_path, new_level
        FROM assets 
        WHERE id = NEW.parent_id AND utility_type = NEW.utility_type;
        
        -- If parent exists in same utility, create hierarchical path
        IF FOUND THEN
            NEW.utility_path := parent_path || '/' || NEW.id::TEXT;
            NEW.utility_level := new_level;
        ELSE
            -- Cross-utility connection (e.g., compressor -> air distribution)
            NEW.utility_path := '/' || NEW.id::TEXT;
            NEW.utility_level := 0;
        END IF;
    ELSE
        -- Top-level utility source
        NEW.utility_path := '/' || NEW.id::TEXT;
        NEW.utility_level := 0;
    END IF;
    
    RETURN NEW;
END;
$$;


--
-- Name: upload_asset_file(integer, integer, character varying, text, character varying, character varying, character varying, bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upload_asset_file(p_tenant_id integer, p_asset_id integer, p_file_name character varying, p_file_path text, p_file_type character varying, p_file_category character varying, p_mime_type character varying DEFAULT NULL::character varying, p_file_size bigint DEFAULT NULL::bigint, p_uploaded_by character varying DEFAULT NULL::character varying) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    new_file_id INTEGER;
BEGIN
    -- Validate asset ownership
    IF NOT EXISTS (
        SELECT 1 FROM assets 
        WHERE id = p_asset_id AND tenant_id = p_tenant_id AND is_active = true
    ) THEN
        RAISE EXCEPTION 'Asset not found or access denied';
    END IF;
    
    -- Insert file record
    INSERT INTO file_storage (
        tenant_id,
        file_name,
        file_type,
        file_path,
        file_size,
        mime_type,
        uploaded_by,
        is_active
    ) VALUES (
        p_tenant_id,
        p_file_name,
        p_file_type,
        p_file_path,
        p_file_size,
        p_mime_type,
        p_uploaded_by,
        true
    ) RETURNING id INTO new_file_id;
    
    -- Associate with asset
    INSERT INTO asset_files (
        asset_id,
        file_id,
        file_category,
        is_primary
    ) VALUES (
        p_asset_id,
        new_file_id,
        p_file_category,
        false
    );
    
    -- Log the action
    INSERT INTO audit_logs (
        tenant_id, 
        action_type, 
        resource_type, 
        resource_id,
        action_description
    ) VALUES (
        p_tenant_id, 
        'FILE_UPLOAD', 
        'FILE', 
        new_file_id::TEXT,
        format('Uploaded file: %s for asset %s', p_file_name, p_asset_id)
    );
    
    RETURN new_file_id;
END;
$$;


--
-- Name: FUNCTION upload_asset_file(p_tenant_id integer, p_asset_id integer, p_file_name character varying, p_file_path text, p_file_type character varying, p_file_category character varying, p_mime_type character varying, p_file_size bigint, p_uploaded_by character varying); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.upload_asset_file(p_tenant_id integer, p_asset_id integer, p_file_name character varying, p_file_path text, p_file_type character varying, p_file_category character varying, p_mime_type character varying, p_file_size bigint, p_uploaded_by character varying) IS 'Upload and associate files with assets';


--
-- Name: upload_operational_data(integer, integer, date, character varying, numeric, character varying, character varying, uuid, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upload_operational_data(p_tenant_id integer, p_asset_id integer, p_data_date date, p_metric_type character varying, p_metric_value numeric, p_metric_unit character varying DEFAULT NULL::character varying, p_data_source character varying DEFAULT 'CSV_UPLOAD'::character varying, p_batch_id uuid DEFAULT NULL::uuid, p_uploaded_by character varying DEFAULT NULL::character varying) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
    new_data_id INTEGER;
    generated_batch_id UUID;
BEGIN
    -- Validate asset ownership
    IF NOT EXISTS (
        SELECT 1 FROM assets 
        WHERE id = p_asset_id AND tenant_id = p_tenant_id AND is_active = true
    ) THEN
        RAISE EXCEPTION 'Asset not found or access denied';
    END IF;
    
    -- Generate batch ID if not provided
    generated_batch_id := COALESCE(p_batch_id, gen_random_uuid());
    
    -- Insert operational data (with UPSERT logic)
    INSERT INTO operational_data (
        tenant_id,
        asset_id,
        data_date,
        metric_type,
        metric_value,
        metric_unit,
        data_source,
        batch_id,
        uploaded_by
    ) VALUES (
        p_tenant_id,
        p_asset_id,
        p_data_date,
        p_metric_type,
        p_metric_value,
        p_metric_unit,
        p_data_source,
        generated_batch_id,
        p_uploaded_by
    )
    ON CONFLICT (tenant_id, asset_id, data_date, metric_type)
    DO UPDATE SET
        metric_value = EXCLUDED.metric_value,
        metric_unit = EXCLUDED.metric_unit,
        data_source = EXCLUDED.data_source,
        batch_id = EXCLUDED.batch_id,
        uploaded_by = EXCLUDED.uploaded_by,
        created_at = CURRENT_TIMESTAMP
    RETURNING id INTO new_data_id;
    
    -- Log the action
    INSERT INTO audit_logs (
        tenant_id, 
        action_type, 
        resource_type, 
        resource_id,
        action_description
    ) VALUES (
        p_tenant_id, 
        'OPERATIONAL_DATA_UPLOAD', 
        'OPERATIONAL_DATA', 
        new_data_id::TEXT,
        format('Uploaded operational data: %s = %s %s for asset %s on %s', 
               p_metric_type, p_metric_value, p_metric_unit, p_asset_id, p_data_date)
    );
    
    RETURN new_data_id;
END;
$$;


--
-- Name: FUNCTION upload_operational_data(p_tenant_id integer, p_asset_id integer, p_data_date date, p_metric_type character varying, p_metric_value numeric, p_metric_unit character varying, p_data_source character varying, p_batch_id uuid, p_uploaded_by character varying); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.upload_operational_data(p_tenant_id integer, p_asset_id integer, p_data_date date, p_metric_type character varying, p_metric_value numeric, p_metric_unit character varying, p_data_source character varying, p_batch_id uuid, p_uploaded_by character varying) IS 'Upload operational metrics for EnPI calculations';


--
-- Name: user_has_permission(integer, integer, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_has_permission(p_user_id integer, p_tenant_id integer, p_permission character varying) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN EXISTS(
        SELECT 1 FROM get_user_permissions(p_user_id, p_tenant_id)
        WHERE permission_code = p_permission
    );
END;
$$;


--
-- Name: FUNCTION user_has_permission(p_user_id integer, p_tenant_id integer, p_permission character varying); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.user_has_permission(p_user_id integer, p_tenant_id integer, p_permission character varying) IS 'Check if user has specific permission in tenant (role-based)';


--
-- Name: validate_role_assignment(integer, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_role_assignment(p_assigner_user_id integer, p_target_role_id integer, p_tenant_id integer) RETURNS TABLE(can_assign boolean, reason character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    assigner_perms TEXT[];
    role_perms TEXT[];
    missing_perms TEXT[];
    role_exists BOOLEAN;
    tenant_exists BOOLEAN;
BEGIN
    -- Check if role exists and is active
    SELECT EXISTS(
        SELECT 1 FROM auth_roles 
        WHERE id = p_target_role_id AND is_active = true
    ) INTO role_exists;
    
    IF NOT role_exists THEN
        RETURN QUERY SELECT false, 'Target role does not exist or is inactive'::VARCHAR;
        RETURN;
    END IF;
    
    -- Check if tenant exists and is active
    SELECT validate_tenant_access(p_tenant_id) INTO tenant_exists;
    
    IF NOT tenant_exists THEN
        RETURN QUERY SELECT false, 'Tenant does not exist or is inactive'::VARCHAR;
        RETURN;
    END IF;
    
    -- Get assigner's permissions for this tenant
    SELECT array_agg(permission_code) INTO assigner_perms
    FROM get_user_permissions(p_assigner_user_id, p_tenant_id);
    
    -- Check if assigner has manage_tenant_assignments permission
    IF 'manage_tenant_assignments' != ALL(COALESCE(assigner_perms, ARRAY[]::TEXT[])) THEN
        RETURN QUERY SELECT false, 'Insufficient permissions to assign roles'::VARCHAR;
        RETURN;
    END IF;
    
    -- Get all permissions that would be granted by target role
    SELECT array_agg(DISTINCT permission_code) INTO role_perms
    FROM get_user_permissions(0, p_tenant_id) -- Get all possible permissions for role
    WHERE permission_code IN (
        WITH RECURSIVE role_tree AS (
            SELECT id, parent_role_id, 0 as level
            FROM auth_roles WHERE id = p_target_role_id
            
            UNION ALL
            
            SELECT r.id, r.parent_role_id, rt.level + 1
            FROM auth_roles r
            JOIN role_tree rt ON r.id = rt.parent_role_id
            WHERE rt.level < 10
        )
        SELECT DISTINCT p.permission_code
        FROM role_tree rt
        JOIN auth_role_permissions rp ON rt.id = rp.role_id
        JOIN auth_permissions p ON rp.permission_id = p.id
        WHERE p.is_active = true
    );
    
    -- Check for missing permissions
    SELECT array_agg(perm) INTO missing_perms
    FROM unnest(COALESCE(role_perms, ARRAY[]::TEXT[])) AS perm
    WHERE perm != ALL(COALESCE(assigner_perms, ARRAY[]::TEXT[]));
    
    IF missing_perms IS NULL OR array_length(missing_perms, 1) = 0 THEN
        RETURN QUERY SELECT true, 'Assignment allowed'::VARCHAR;
    ELSE
        RETURN QUERY SELECT false, 
            ('Missing permissions: ' || array_to_string(missing_perms, ', '))::VARCHAR;
    END IF;
END;
$$;


--
-- Name: FUNCTION validate_role_assignment(p_assigner_user_id integer, p_target_role_id integer, p_tenant_id integer); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.validate_role_assignment(p_assigner_user_id integer, p_target_role_id integer, p_tenant_id integer) IS 'Validate if assigner can assign target role to user in tenant';


--
-- Name: validate_tenant_access(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_tenant_access(p_tenant_id integer) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM tenants 
        WHERE id = p_tenant_id AND is_active = true
    );
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: quantities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quantities (
    id integer NOT NULL,
    quantity_code character varying(50) NOT NULL,
    quantity_name character varying(255) NOT NULL,
    unit character varying(50),
    category character varying(100),
    data_type character varying(50) DEFAULT 'NUMERIC'::character varying,
    aggregation_method character varying(50) DEFAULT 'SUM'::character varying,
    description text,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    is_cumulative boolean DEFAULT false
);


--
-- Name: telemetry_data; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.telemetry_data (
    "timestamp" timestamp without time zone NOT NULL,
    tenant_id integer NOT NULL,
    device_id integer NOT NULL,
    quantity_id integer NOT NULL,
    value numeric,
    quality integer DEFAULT 1,
    source_system character varying(50) NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: _direct_view_7; Type: VIEW; Schema: _timescaledb_internal; Owner: -
--

CREATE VIEW _timescaledb_internal._direct_view_7 AS
 SELECT public.time_bucket('00:15:00'::interval, td."timestamp") AS bucket,
    td.tenant_id,
    td.device_id,
    td.quantity_id,
    public.last(td.value, td."timestamp") AS aggregated_value,
    count(*) AS sample_count,
    td.source_system
   FROM (public.telemetry_data td
     JOIN public.quantities q ON ((td.quantity_id = q.id)))
  GROUP BY (public.time_bucket('00:15:00'::interval, td."timestamp")), td.tenant_id, td.device_id, td.quantity_id, td.source_system;


--
-- Name: _hyper_1_5611_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_1_5611_chunk (
    CONSTRAINT constraint_5611 CHECK ((("timestamp" >= '2025-11-03 00:00:00'::timestamp without time zone) AND ("timestamp" < '2025-11-04 00:00:00'::timestamp without time zone)))
)
INHERITS (public.telemetry_data);


--
-- Name: _hyper_1_5612_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_1_5612_chunk (
    CONSTRAINT constraint_5612 CHECK ((("timestamp" >= '2025-11-04 00:00:00'::timestamp without time zone) AND ("timestamp" < '2025-11-05 00:00:00'::timestamp without time zone)))
)
INHERITS (public.telemetry_data);


--
-- Name: _hyper_1_5613_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_1_5613_chunk (
    CONSTRAINT constraint_5613 CHECK ((("timestamp" >= '2025-11-05 00:00:00'::timestamp without time zone) AND ("timestamp" < '2025-11-06 00:00:00'::timestamp without time zone)))
)
INHERITS (public.telemetry_data);


--
-- Name: _hyper_1_5614_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_1_5614_chunk (
    CONSTRAINT constraint_5614 CHECK ((("timestamp" >= '2025-11-06 00:00:00'::timestamp without time zone) AND ("timestamp" < '2025-11-07 00:00:00'::timestamp without time zone)))
)
INHERITS (public.telemetry_data);


--
-- Name: _hyper_1_5615_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_1_5615_chunk (
    CONSTRAINT constraint_5615 CHECK ((("timestamp" >= '2025-11-07 00:00:00'::timestamp without time zone) AND ("timestamp" < '2025-11-08 00:00:00'::timestamp without time zone)))
)
INHERITS (public.telemetry_data);


--
-- Name: _hyper_1_5616_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_1_5616_chunk (
    CONSTRAINT constraint_5616 CHECK ((("timestamp" >= '2025-11-08 00:00:00'::timestamp without time zone) AND ("timestamp" < '2025-11-09 00:00:00'::timestamp without time zone)))
)
INHERITS (public.telemetry_data);


--
-- Name: _hyper_1_5618_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_1_5618_chunk (
    CONSTRAINT constraint_5618 CHECK ((("timestamp" >= '2025-11-09 00:00:00'::timestamp without time zone) AND ("timestamp" < '2025-11-10 00:00:00'::timestamp without time zone)))
)
INHERITS (public.telemetry_data);


--
-- Name: _hyper_1_5619_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_1_5619_chunk (
    CONSTRAINT constraint_5619 CHECK ((("timestamp" >= '2025-11-10 00:00:00'::timestamp without time zone) AND ("timestamp" < '2025-11-11 00:00:00'::timestamp without time zone)))
)
INHERITS (public.telemetry_data);


--
-- Name: _hyper_1_5620_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_1_5620_chunk (
    CONSTRAINT constraint_5620 CHECK ((("timestamp" >= '2025-11-11 00:00:00'::timestamp without time zone) AND ("timestamp" < '2025-11-12 00:00:00'::timestamp without time zone)))
)
INHERITS (public.telemetry_data);


--
-- Name: _hyper_1_5621_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_1_5621_chunk (
    CONSTRAINT constraint_5621 CHECK ((("timestamp" >= '2025-11-12 00:00:00'::timestamp without time zone) AND ("timestamp" < '2025-11-13 00:00:00'::timestamp without time zone)))
)
INHERITS (public.telemetry_data);


--
-- Name: _hyper_1_5622_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_1_5622_chunk (
    CONSTRAINT constraint_5622 CHECK ((("timestamp" >= '2025-11-13 00:00:00'::timestamp without time zone) AND ("timestamp" < '2025-11-14 00:00:00'::timestamp without time zone)))
)
INHERITS (public.telemetry_data);


--
-- Name: _hyper_1_5623_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_1_5623_chunk (
    CONSTRAINT constraint_5623 CHECK ((("timestamp" >= '2025-11-14 00:00:00'::timestamp without time zone) AND ("timestamp" < '2025-11-15 00:00:00'::timestamp without time zone)))
)
INHERITS (public.telemetry_data);


--
-- Name: _hyper_1_5624_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_1_5624_chunk (
    CONSTRAINT constraint_5624 CHECK ((("timestamp" >= '2025-11-15 00:00:00'::timestamp without time zone) AND ("timestamp" < '2025-11-16 00:00:00'::timestamp without time zone)))
)
INHERITS (public.telemetry_data);


--
-- Name: _hyper_1_5625_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_1_5625_chunk (
    CONSTRAINT constraint_5625 CHECK ((("timestamp" >= '2025-11-16 00:00:00'::timestamp without time zone) AND ("timestamp" < '2025-11-17 00:00:00'::timestamp without time zone)))
)
INHERITS (public.telemetry_data);


--
-- Name: _hyper_1_5626_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_1_5626_chunk (
    CONSTRAINT constraint_5626 CHECK ((("timestamp" >= '2025-11-17 00:00:00'::timestamp without time zone) AND ("timestamp" < '2025-11-18 00:00:00'::timestamp without time zone)))
)
INHERITS (public.telemetry_data);


--
-- Name: audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_logs (
    id bigint NOT NULL,
    tenant_id integer,
    user_id character varying(100),
    session_id character varying(255),
    action_type character varying(100) NOT NULL,
    resource_type character varying(100),
    resource_id character varying(100),
    action_description text,
    ip_address inet,
    user_agent text,
    request_data jsonb,
    response_status integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: _hyper_6_1_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_6_1_chunk (
    CONSTRAINT constraint_1 CHECK (((created_at >= '2025-05-12 00:00:00'::timestamp without time zone) AND (created_at < '2025-06-11 00:00:00'::timestamp without time zone)))
)
INHERITS (public.audit_logs);


--
-- Name: _hyper_6_305_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_6_305_chunk (
    CONSTRAINT constraint_305 CHECK (((created_at >= '2025-06-11 00:00:00'::timestamp without time zone) AND (created_at < '2025-07-11 00:00:00'::timestamp without time zone)))
)
INHERITS (public.audit_logs);


--
-- Name: _hyper_6_5559_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_6_5559_chunk (
    CONSTRAINT constraint_5559 CHECK (((created_at >= '2025-09-09 00:00:00'::timestamp without time zone) AND (created_at < '2025-10-09 00:00:00'::timestamp without time zone)))
)
INHERITS (public.audit_logs);


--
-- Name: _materialized_hypertable_7; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._materialized_hypertable_7 (
    bucket timestamp without time zone NOT NULL,
    tenant_id integer,
    device_id integer,
    quantity_id integer,
    aggregated_value numeric,
    sample_count bigint,
    source_system character varying(50)
);


--
-- Name: _hyper_7_323_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_7_323_chunk (
    CONSTRAINT constraint_323 CHECK (((bucket >= '2025-08-30 00:00:00'::timestamp without time zone) AND (bucket < '2025-09-09 00:00:00'::timestamp without time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_7);


--
-- Name: _hyper_7_324_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_7_324_chunk (
    CONSTRAINT constraint_324 CHECK (((bucket >= '2025-08-20 00:00:00'::timestamp without time zone) AND (bucket < '2025-08-30 00:00:00'::timestamp without time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_7);


--
-- Name: _hyper_7_5550_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_7_5550_chunk (
    CONSTRAINT constraint_5550 CHECK (((bucket >= '2025-09-09 00:00:00'::timestamp without time zone) AND (bucket < '2025-09-19 00:00:00'::timestamp without time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_7);


--
-- Name: _hyper_7_5562_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_7_5562_chunk (
    CONSTRAINT constraint_5562 CHECK (((bucket >= '2025-09-19 00:00:00'::timestamp without time zone) AND (bucket < '2025-09-29 00:00:00'::timestamp without time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_7);


--
-- Name: _hyper_7_5573_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_7_5573_chunk (
    CONSTRAINT constraint_5573 CHECK (((bucket >= '2025-09-29 00:00:00'::timestamp without time zone) AND (bucket < '2025-10-09 00:00:00'::timestamp without time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_7);


--
-- Name: _hyper_7_5584_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_7_5584_chunk (
    CONSTRAINT constraint_5584 CHECK (((bucket >= '2025-10-09 00:00:00'::timestamp without time zone) AND (bucket < '2025-10-19 00:00:00'::timestamp without time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_7);


--
-- Name: _hyper_7_5595_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_7_5595_chunk (
    CONSTRAINT constraint_5595 CHECK (((bucket >= '2025-10-19 00:00:00'::timestamp without time zone) AND (bucket < '2025-10-29 00:00:00'::timestamp without time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_7);


--
-- Name: _hyper_7_5606_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_7_5606_chunk (
    CONSTRAINT constraint_5606 CHECK (((bucket >= '2025-10-29 00:00:00'::timestamp without time zone) AND (bucket < '2025-11-08 00:00:00'::timestamp without time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_7);


--
-- Name: _hyper_7_5617_chunk; Type: TABLE; Schema: _timescaledb_internal; Owner: -
--

CREATE TABLE _timescaledb_internal._hyper_7_5617_chunk (
    CONSTRAINT constraint_5617 CHECK (((bucket >= '2025-11-08 00:00:00'::timestamp without time zone) AND (bucket < '2025-11-18 00:00:00'::timestamp without time zone)))
)
INHERITS (_timescaledb_internal._materialized_hypertable_7);


--
-- Name: _partial_view_7; Type: VIEW; Schema: _timescaledb_internal; Owner: -
--

CREATE VIEW _timescaledb_internal._partial_view_7 AS
 SELECT public.time_bucket('00:15:00'::interval, td."timestamp") AS bucket,
    td.tenant_id,
    td.device_id,
    td.quantity_id,
    public.last(td.value, td."timestamp") AS aggregated_value,
    count(*) AS sample_count,
    td.source_system
   FROM (public.telemetry_data td
     JOIN public.quantities q ON ((td.quantity_id = q.id)))
  GROUP BY (public.time_bucket('00:15:00'::interval, td."timestamp")), td.tenant_id, td.device_id, td.quantity_id, td.source_system;


--
-- Name: asset_connections_backup; Type: TABLE; Schema: prs; Owner: -
--

CREATE TABLE prs.asset_connections_backup (
    id integer,
    source_asset_id integer,
    target_asset_id integer,
    connection_type character varying(50),
    priority_order integer,
    rated_capacity numeric,
    capacity_unit character varying(20),
    operating_conditions jsonb,
    is_active boolean,
    is_normally_open boolean,
    auto_switch_enabled boolean,
    connection_description text,
    cable_conduit_info text,
    pipe_valve_info text,
    created_at timestamp without time zone,
    updated_at timestamp without time zone
);


--
-- Name: assets_backup; Type: TABLE; Schema: prs; Owner: -
--

CREATE TABLE prs.assets_backup (
    id integer,
    tenant_id integer,
    parent_id integer,
    asset_code character varying(100),
    asset_name character varying(255),
    asset_type character varying(100),
    utility_type character varying(50),
    source_utility character varying(50),
    output_utility character varying(50),
    flow_direction character varying(20),
    utility_level integer,
    utility_path text,
    rated_capacity numeric,
    capacity_unit character varying(20),
    operating_pressure numeric,
    pressure_unit character varying(10),
    voltage_level character varying(50),
    description text,
    location_description text,
    metadata jsonb,
    is_active boolean,
    commissioned_date date,
    decommissioned_date date,
    created_at timestamp without time zone,
    updated_at timestamp without time zone
);


--
-- Name: baseline_load_profiles; Type: TABLE; Schema: prs; Owner: -
--

CREATE TABLE prs.baseline_load_profiles (
    id integer NOT NULL,
    tenant_id integer NOT NULL,
    baseline_version integer NOT NULL,
    calculation_date date NOT NULL,
    data_period_start date NOT NULL,
    data_period_end date NOT NULL,
    profile_type character varying(50) NOT NULL,
    time_hhmm time without time zone,
    shift_name character varying(50) NOT NULL,
    day_type character varying(20) NOT NULL,
    load_group character varying(50) NOT NULL,
    baseline_median numeric(10,3) NOT NULL,
    baseline_mean numeric(10,3),
    baseline_p10 numeric(10,3),
    baseline_p90 numeric(10,3),
    baseline_std numeric(10,3),
    baseline_min numeric(10,3),
    baseline_max numeric(10,3),
    sample_count integer NOT NULL,
    data_completeness numeric(5,2),
    measurement_unit character varying(20) NOT NULL,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT check_profile_type CHECK (((profile_type)::text = ANY ((ARRAY['POWER_15MIN'::character varying, 'ENERGY_SHIFT'::character varying, 'ENERGY_DAILY'::character varying, 'ENERGY_HOURLY'::character varying])::text[]))),
    CONSTRAINT check_time_granularity CHECK (((((profile_type)::text = 'POWER_15MIN'::text) AND (time_hhmm IS NOT NULL)) OR (((profile_type)::text = ANY ((ARRAY['ENERGY_SHIFT'::character varying, 'ENERGY_DAILY'::character varying])::text[])) AND (time_hhmm IS NULL))))
);


--
-- Name: TABLE baseline_load_profiles; Type: COMMENT; Schema: prs; Owner: -
--

COMMENT ON TABLE prs.baseline_load_profiles IS 'Unified baseline profiles for power demand (15-min) and energy consumption (shift/daily)';


--
-- Name: COLUMN baseline_load_profiles.profile_type; Type: COMMENT; Schema: prs; Owner: -
--

COMMENT ON COLUMN prs.baseline_load_profiles.profile_type IS 'Type of baseline: POWER_15MIN (kW at 15-min intervals), ENERGY_SHIFT (kWh per shift), ENERGY_DAILY (kWh per day)';


--
-- Name: COLUMN baseline_load_profiles.time_hhmm; Type: COMMENT; Schema: prs; Owner: -
--

COMMENT ON COLUMN prs.baseline_load_profiles.time_hhmm IS 'Time of day (HH:MM) - populated only for POWER_15MIN profile type, NULL for shift/daily aggregates';


--
-- Name: COLUMN baseline_load_profiles.measurement_unit; Type: COMMENT; Schema: prs; Owner: -
--

COMMENT ON COLUMN prs.baseline_load_profiles.measurement_unit IS 'Unit of measurement: kW for power, kWh for energy';


--
-- Name: baseline_load_profiles_backup; Type: TABLE; Schema: prs; Owner: -
--

CREATE TABLE prs.baseline_load_profiles_backup (
    id integer,
    tenant_id integer,
    baseline_version integer,
    calculation_date date,
    data_period_start date,
    data_period_end date,
    time_hhmm time without time zone,
    shift_name character varying(50),
    day_type character varying(20),
    load_group character varying(50),
    baseline_median numeric(10,3),
    baseline_mean numeric(10,3),
    baseline_p10 numeric(10,3),
    baseline_p90 numeric(10,3),
    baseline_std numeric(10,3),
    baseline_min numeric(10,3),
    baseline_max numeric(10,3),
    sample_count integer,
    data_completeness numeric(5,2),
    is_active boolean,
    created_at timestamp without time zone
);


--
-- Name: baseline_load_profiles_id_seq; Type: SEQUENCE; Schema: prs; Owner: -
--

CREATE SEQUENCE prs.baseline_load_profiles_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: baseline_load_profiles_id_seq; Type: SEQUENCE OWNED BY; Schema: prs; Owner: -
--

ALTER SEQUENCE prs.baseline_load_profiles_id_seq OWNED BY prs.baseline_load_profiles.id;


--
-- Name: asset_connections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.asset_connections (
    id integer NOT NULL,
    source_asset_id integer NOT NULL,
    target_asset_id integer NOT NULL,
    connection_type character varying(50) NOT NULL,
    priority_order integer DEFAULT 1,
    rated_capacity numeric,
    capacity_unit character varying(20),
    operating_conditions jsonb,
    is_active boolean DEFAULT true,
    is_normally_open boolean DEFAULT false,
    auto_switch_enabled boolean DEFAULT true,
    connection_description text,
    cable_conduit_info text,
    pipe_valve_info text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT check_no_self_connection CHECK ((source_asset_id <> target_asset_id))
);


--
-- Name: asset_connections_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.asset_connections_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: asset_connections_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.asset_connections_id_seq OWNED BY public.asset_connections.id;


--
-- Name: asset_files; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.asset_files (
    id integer NOT NULL,
    asset_id integer NOT NULL,
    file_id integer NOT NULL,
    file_category character varying(50) NOT NULL,
    display_order integer DEFAULT 0,
    is_primary boolean DEFAULT false,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: asset_files_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.asset_files_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: asset_files_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.asset_files_id_seq OWNED BY public.asset_files.id;


--
-- Name: asset_tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.asset_tags (
    id integer NOT NULL,
    asset_id integer NOT NULL,
    tag_key character varying(100) NOT NULL,
    tag_value character varying(255) NOT NULL,
    tag_category character varying(50),
    tag_description text,
    effective_from date DEFAULT CURRENT_DATE,
    effective_to date,
    is_active boolean DEFAULT true,
    confidence_level character varying(20) DEFAULT 'HIGH'::character varying,
    data_source character varying(50) DEFAULT 'MANUAL'::character varying,
    validation_status character varying(20) DEFAULT 'PENDING'::character varying,
    created_by character varying(100),
    validated_by character varying(100),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT check_asset_effective_dates CHECK (((effective_to IS NULL) OR (effective_to >= effective_from)))
);


--
-- Name: asset_tags_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.asset_tags_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: asset_tags_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.asset_tags_id_seq OWNED BY public.asset_tags.id;


--
-- Name: assets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.assets (
    id integer NOT NULL,
    tenant_id integer NOT NULL,
    parent_id integer,
    asset_code character varying(100) NOT NULL,
    asset_name character varying(255) NOT NULL,
    asset_type character varying(100) NOT NULL,
    utility_type character varying(50) NOT NULL,
    source_utility character varying(50),
    output_utility character varying(50),
    flow_direction character varying(20) DEFAULT 'DOWNSTREAM'::character varying,
    utility_level integer DEFAULT 0,
    utility_path text,
    rated_capacity numeric,
    capacity_unit character varying(20),
    operating_pressure numeric,
    pressure_unit character varying(10),
    voltage_level character varying(50),
    description text,
    location_description text,
    metadata jsonb,
    is_active boolean DEFAULT true,
    commissioned_date date,
    decommissioned_date date,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT check_conversion_utilities CHECK ((((source_utility IS NULL) AND (output_utility IS NULL)) OR ((source_utility IS NOT NULL) AND (output_utility IS NOT NULL) AND ((source_utility)::text <> (output_utility)::text)))),
    CONSTRAINT check_flow_direction CHECK (((flow_direction)::text = ANY ((ARRAY['DOWNSTREAM'::character varying, 'UPSTREAM'::character varying, 'BIDIRECTIONAL'::character varying])::text[])))
);


--
-- Name: assets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.assets_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: assets_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.assets_id_seq OWNED BY public.assets.id;


--
-- Name: audit_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.audit_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: audit_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.audit_logs_id_seq OWNED BY public.audit_logs.id;


--
-- Name: auth_audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_audit_logs (
    id bigint NOT NULL,
    user_id integer,
    tenant_id integer,
    session_id integer,
    event_type character varying(100) NOT NULL,
    event_category character varying(50) NOT NULL,
    event_description text,
    ip_address inet,
    user_agent text,
    request_id character varying(100),
    event_data jsonb,
    success boolean NOT NULL,
    error_message text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: auth_audit_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.auth_audit_logs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: auth_audit_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.auth_audit_logs_id_seq OWNED BY public.auth_audit_logs.id;


--
-- Name: auth_email_verifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_email_verifications (
    id integer NOT NULL,
    user_id integer NOT NULL,
    email character varying(255) NOT NULL,
    token_hash character varying(255) NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    verified_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: auth_email_verifications_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.auth_email_verifications_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: auth_email_verifications_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.auth_email_verifications_id_seq OWNED BY public.auth_email_verifications.id;


--
-- Name: auth_oauth_providers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_oauth_providers (
    id integer NOT NULL,
    provider_code character varying(50) NOT NULL,
    provider_name character varying(255) NOT NULL,
    client_id character varying(255) NOT NULL,
    client_secret_encrypted text NOT NULL,
    auth_url text NOT NULL,
    token_url text NOT NULL,
    user_info_url text NOT NULL,
    scopes text[],
    email_claim character varying(100) DEFAULT 'email'::character varying,
    name_claim character varying(100) DEFAULT 'name'::character varying,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: auth_oauth_providers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.auth_oauth_providers_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: auth_oauth_providers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.auth_oauth_providers_id_seq OWNED BY public.auth_oauth_providers.id;


--
-- Name: auth_password_resets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_password_resets (
    id integer NOT NULL,
    user_id integer NOT NULL,
    token_hash character varying(255) NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    used_at timestamp without time zone,
    ip_address inet,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: auth_password_resets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.auth_password_resets_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: auth_password_resets_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.auth_password_resets_id_seq OWNED BY public.auth_password_resets.id;


--
-- Name: auth_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_permissions (
    id integer NOT NULL,
    permission_code character varying(100) NOT NULL,
    permission_name character varying(255) NOT NULL,
    description text,
    category character varying(50),
    product_id integer,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: auth_permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.auth_permissions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: auth_permissions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.auth_permissions_id_seq OWNED BY public.auth_permissions.id;


--
-- Name: auth_products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_products (
    id integer NOT NULL,
    product_code character varying(50) NOT NULL,
    product_name character varying(255) NOT NULL,
    description text,
    is_active boolean DEFAULT true,
    features text[],
    default_permissions text[],
    tenant_types text[],
    product_metadata jsonb,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: auth_products_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.auth_products_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: auth_products_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.auth_products_id_seq OWNED BY public.auth_products.id;


--
-- Name: auth_role_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_role_permissions (
    id integer NOT NULL,
    role_id integer NOT NULL,
    permission_id integer NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: auth_role_permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.auth_role_permissions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: auth_role_permissions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.auth_role_permissions_id_seq OWNED BY public.auth_role_permissions.id;


--
-- Name: auth_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_roles (
    id integer NOT NULL,
    role_code character varying(50) NOT NULL,
    role_name character varying(255) NOT NULL,
    description text,
    product_id integer,
    parent_role_id integer,
    level integer DEFAULT 0,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: auth_roles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.auth_roles_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: auth_roles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.auth_roles_id_seq OWNED BY public.auth_roles.id;


--
-- Name: auth_user_oauth; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_user_oauth (
    id integer NOT NULL,
    user_id integer NOT NULL,
    provider_id integer NOT NULL,
    provider_user_id character varying(255) NOT NULL,
    provider_email character varying(255),
    provider_data jsonb,
    access_token_encrypted text,
    refresh_token_encrypted text,
    token_expires_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: auth_user_oauth_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.auth_user_oauth_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: auth_user_oauth_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.auth_user_oauth_id_seq OWNED BY public.auth_user_oauth.id;


--
-- Name: auth_user_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_user_sessions (
    id integer NOT NULL,
    user_id integer NOT NULL,
    session_token character varying(255) NOT NULL,
    refresh_token_hash character varying(255),
    device_info jsonb,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    expires_at timestamp without time zone NOT NULL,
    last_used_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    is_revoked boolean DEFAULT false,
    revoked_at timestamp without time zone,
    revoked_reason character varying(100)
);


--
-- Name: auth_user_sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.auth_user_sessions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: auth_user_sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.auth_user_sessions_id_seq OWNED BY public.auth_user_sessions.id;


--
-- Name: auth_user_tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_user_tenants (
    id integer NOT NULL,
    user_id integer NOT NULL,
    tenant_id integer NOT NULL,
    product_id integer NOT NULL,
    role character varying(50) NOT NULL,
    permissions text[],
    is_active boolean DEFAULT true,
    granted_by integer,
    granted_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    expires_at timestamp without time zone,
    user_tenant_metadata jsonb,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: auth_user_tenants_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.auth_user_tenants_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: auth_user_tenants_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.auth_user_tenants_id_seq OWNED BY public.auth_user_tenants.id;


--
-- Name: auth_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_users (
    id integer NOT NULL,
    email character varying(255) NOT NULL,
    password_hash character varying(255) NOT NULL,
    name character varying(255),
    email_verified boolean DEFAULT false,
    email_verified_at timestamp without time zone,
    phone character varying(50),
    phone_verified boolean DEFAULT false,
    avatar_url text,
    locale character varying(10) DEFAULT 'en'::character varying,
    timezone character varying(50) DEFAULT 'UTC'::character varying,
    is_active boolean DEFAULT true,
    is_locked boolean DEFAULT false,
    locked_until timestamp without time zone,
    last_login_at timestamp without time zone,
    password_changed_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    failed_login_attempts integer DEFAULT 0,
    mfa_enabled boolean DEFAULT false,
    mfa_secret character varying(255),
    backup_codes text[],
    metadata jsonb,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: auth_users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.auth_users_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: auth_users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.auth_users_id_seq OWNED BY public.auth_users.id;


--
-- Name: daily_energy_cost_summary; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_energy_cost_summary (
    daily_bucket timestamp without time zone,
    tenant_id integer,
    device_id integer,
    quantity_id integer,
    grouping_type text,
    grouping_value character varying,
    shift_period character varying,
    rate_code character varying,
    rate_per_unit numeric,
    utility_source_id integer,
    total_consumption numeric,
    interval_count numeric,
    avg_interval_consumption numeric,
    max_interval_consumption numeric,
    min_interval_consumption numeric,
    total_cost numeric,
    last_refreshed timestamp with time zone,
    refresh_method text
);


--
-- Name: daily_energy_cost_summary_old; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_energy_cost_summary_old (
    daily_bucket timestamp without time zone,
    tenant_id integer,
    device_id integer,
    quantity_id integer,
    grouping_type text,
    grouping_value character varying,
    shift_period character varying,
    rate_code character varying,
    rate_per_unit numeric,
    utility_source_id integer,
    total_consumption numeric,
    interval_count numeric,
    avg_interval_consumption numeric,
    max_interval_consumption numeric,
    min_interval_consumption numeric,
    total_cost numeric,
    last_refreshed timestamp with time zone,
    refresh_method text
);


--
-- Name: daily_energy_refresh_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_energy_refresh_log (
    id integer NOT NULL,
    refresh_timestamp timestamp without time zone DEFAULT now(),
    result text,
    duration interval,
    rows_processed integer
);


--
-- Name: daily_energy_refresh_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.daily_energy_refresh_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: daily_energy_refresh_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.daily_energy_refresh_log_id_seq OWNED BY public.daily_energy_refresh_log.id;


--
-- Name: device_alerts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.device_alerts (
    id integer NOT NULL,
    device_id integer NOT NULL,
    tenant_id integer NOT NULL,
    severity character varying(20) NOT NULL,
    message text NOT NULL,
    acknowledged boolean DEFAULT false,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    acknowledged_at timestamp without time zone,
    acknowledged_by character varying(100),
    CONSTRAINT device_alerts_severity_check CHECK (((severity)::text = ANY ((ARRAY['LOW'::character varying, 'MEDIUM'::character varying, 'HIGH'::character varying, 'CRITICAL'::character varying])::text[])))
);


--
-- Name: TABLE device_alerts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.device_alerts IS 'Device alerts for equipment status monitoring and maintenance notifications';


--
-- Name: device_alerts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.device_alerts_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: device_alerts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.device_alerts_id_seq OWNED BY public.device_alerts.id;


--
-- Name: processed_gaps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.processed_gaps (
    id integer NOT NULL,
    tenant_id integer NOT NULL,
    device_id integer NOT NULL,
    quantity_id integer NOT NULL,
    gap_start timestamp without time zone NOT NULL,
    gap_end timestamp without time zone NOT NULL,
    gap_duration_hours numeric(8,2) NOT NULL,
    original_bucket timestamp without time zone NOT NULL,
    original_interval_value numeric NOT NULL,
    original_cumulative_value numeric,
    redistribution_method character varying(50) NOT NULL,
    pattern_confidence_used character varying(20),
    total_intervals_redistributed integer NOT NULL,
    processed_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    processed_by character varying(100),
    processing_notes text,
    CONSTRAINT check_gap_duration CHECK ((gap_duration_hours > (0)::numeric)),
    CONSTRAINT check_gap_times CHECK ((gap_end > gap_start))
);


--
-- Name: telemetry_15min_agg; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.telemetry_15min_agg AS
 SELECT bucket,
    tenant_id,
    device_id,
    quantity_id,
    aggregated_value,
    sample_count,
    source_system
   FROM _timescaledb_internal._materialized_hypertable_7;


--
-- Name: telemetry_intervals_cumulative; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.telemetry_intervals_cumulative AS
 WITH raw_intervals AS (
         SELECT ta.bucket,
            ta.tenant_id,
            ta.device_id,
            ta.quantity_id,
            q.quantity_code,
            q.quantity_name,
            q.unit,
            ta.aggregated_value AS cumulative_value,
            lag(ta.aggregated_value) OVER (PARTITION BY ta.tenant_id, ta.device_id, ta.quantity_id ORDER BY ta.bucket) AS prev_cumulative_value,
            ta.sample_count,
            ta.source_system
           FROM (public.telemetry_15min_agg ta
             JOIN public.quantities q ON ((ta.quantity_id = q.id)))
          WHERE (ta.quantity_id = ANY (ARRAY[62, 89, 96, 124, 130, 481]))
        ), reset_detection AS (
         SELECT raw_intervals.bucket,
            raw_intervals.tenant_id,
            raw_intervals.device_id,
            raw_intervals.quantity_id,
            raw_intervals.quantity_code,
            raw_intervals.quantity_name,
            raw_intervals.unit,
            raw_intervals.cumulative_value,
            raw_intervals.prev_cumulative_value,
            raw_intervals.sample_count,
            raw_intervals.source_system,
            (raw_intervals.cumulative_value - raw_intervals.prev_cumulative_value) AS raw_interval_value,
            abs((raw_intervals.cumulative_value - COALESCE(raw_intervals.prev_cumulative_value, (0)::numeric))) AS abs_interval_change,
                CASE
                    WHEN (raw_intervals.prev_cumulative_value IS NULL) THEN false
                    WHEN ((raw_intervals.cumulative_value < (0)::numeric) AND (abs(raw_intervals.cumulative_value) < 0.00000000000000000001)) THEN true
                    WHEN ((raw_intervals.prev_cumulative_value < (0)::numeric) AND (abs(raw_intervals.prev_cumulative_value) < 0.00000000000000000001)) THEN true
                    WHEN (raw_intervals.cumulative_value = (0)::numeric) THEN true
                    WHEN ((raw_intervals.prev_cumulative_value < (1)::numeric) AND (raw_intervals.cumulative_value > (1000)::numeric)) THEN true
                    WHEN ((raw_intervals.prev_cumulative_value > (0)::numeric) AND (raw_intervals.prev_cumulative_value < (100)::numeric) AND (raw_intervals.cumulative_value > (10000)::numeric)) THEN true
                    WHEN ((raw_intervals.prev_cumulative_value > (100)::numeric) AND (raw_intervals.cumulative_value < (raw_intervals.prev_cumulative_value * 0.5))) THEN true
                    WHEN ((raw_intervals.prev_cumulative_value > (1000)::numeric) AND (raw_intervals.cumulative_value < (100)::numeric)) THEN true
                    ELSE false
                END AS is_reset,
                CASE
                    WHEN (raw_intervals.prev_cumulative_value IS NULL) THEN false
                    WHEN ((raw_intervals.prev_cumulative_value < (0)::numeric) AND (abs(raw_intervals.prev_cumulative_value) < 0.00000000000000000001) AND (raw_intervals.cumulative_value > (1000)::numeric)) THEN true
                    WHEN ((raw_intervals.prev_cumulative_value > (0)::numeric) AND (raw_intervals.prev_cumulative_value < (1)::numeric) AND (raw_intervals.cumulative_value > (1000)::numeric)) THEN true
                    ELSE false
                END AS is_register_correction,
                CASE
                    WHEN (raw_intervals.prev_cumulative_value IS NULL) THEN false
                    WHEN ((raw_intervals.prev_cumulative_value > (100)::numeric) AND (raw_intervals.cumulative_value > (raw_intervals.prev_cumulative_value * (10)::numeric))) THEN true
                    ELSE false
                END AS is_unrealistic_spike,
                CASE
                    WHEN ((raw_intervals.cumulative_value < (0)::numeric) AND (abs(raw_intervals.cumulative_value) < 0.00000000000000000001)) THEN true
                    ELSE false
                END AS is_tiny_negative,
                CASE
                    WHEN (abs((raw_intervals.cumulative_value - COALESCE(raw_intervals.prev_cumulative_value, (0)::numeric))) > (1000000)::numeric) THEN true
                    ELSE false
                END AS is_extreme_interval
           FROM raw_intervals
        )
 SELECT bucket,
    tenant_id,
    device_id,
    quantity_id,
    quantity_code,
    quantity_name,
    unit,
    cumulative_value,
        CASE
            WHEN (prev_cumulative_value IS NULL) THEN (0)::numeric
            WHEN is_reset THEN (0)::numeric
            WHEN is_register_correction THEN (0)::numeric
            WHEN is_unrealistic_spike THEN (0)::numeric
            WHEN (raw_interval_value < (0)::numeric) THEN (0)::numeric
            WHEN (raw_interval_value > (999999)::numeric) THEN (0)::numeric
            ELSE raw_interval_value
        END AS interval_value,
    sample_count,
    source_system,
    is_reset,
    is_register_correction,
    is_unrealistic_spike,
    is_tiny_negative,
    is_extreme_interval,
    prev_cumulative_value,
    raw_interval_value,
    abs_interval_change,
        CASE
            WHEN (prev_cumulative_value IS NULL) THEN 'FIRST_READING'::text
            WHEN is_tiny_negative THEN 'TINY_NEGATIVE_ERROR'::text
            WHEN is_register_correction THEN 'REGISTER_CORRECTION'::text
            WHEN is_reset THEN 'DEVICE_RESET'::text
            WHEN is_unrealistic_spike THEN 'UNREALISTIC_SPIKE'::text
            WHEN is_extreme_interval THEN 'EXTREME_INTERVAL'::text
            WHEN (raw_interval_value < (0)::numeric) THEN 'NEGATIVE_INTERVAL'::text
            WHEN (raw_interval_value = (0)::numeric) THEN 'NO_CONSUMPTION'::text
            WHEN (raw_interval_value > (0)::numeric) THEN 'NORMAL_CONSUMPTION'::text
            ELSE 'UNKNOWN'::text
        END AS interval_classification,
        CASE
            WHEN (is_tiny_negative OR is_register_correction) THEN 'REGISTER_ISSUE'::text
            WHEN is_reset THEN 'DEVICE_RESET_EVENT'::text
            WHEN (is_unrealistic_spike OR is_extreme_interval) THEN 'DATA_ANOMALY'::text
            WHEN (raw_interval_value < (0)::numeric) THEN 'NEGATIVE_READING'::text
            ELSE 'NORMAL'::text
        END AS data_quality_flag,
    round((abs(raw_interval_value) / 1000000.0), 3) AS abs_interval_gwh
   FROM reset_detection;


--
-- Name: device_consumption_patterns; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

CREATE MATERIALIZED VIEW public.device_consumption_patterns AS
 WITH clean_telemetry_data AS (
         SELECT tc.tenant_id,
            tc.device_id,
            tc.quantity_id,
            EXTRACT(hour FROM tc.bucket) AS hour_of_day,
            EXTRACT(dow FROM tc.bucket) AS day_of_week,
            tc.interval_value,
            tc.bucket,
            power(0.95, EXTRACT(day FROM (CURRENT_TIMESTAMP - (tc.bucket)::timestamp with time zone))) AS time_weight
           FROM public.telemetry_intervals_cumulative tc
          WHERE ((tc.bucket >= GREATEST((CURRENT_TIMESTAMP - '1 mon'::interval), (( SELECT min(telemetry_intervals_cumulative.bucket) AS min
                   FROM public.telemetry_intervals_cumulative))::timestamp with time zone)) AND (tc.interval_value IS NOT NULL) AND (tc.data_quality_flag = 'NORMAL'::text) AND (tc.interval_value >= (0)::numeric) AND (NOT (EXISTS ( SELECT 1
                   FROM public.processed_gaps pg
                  WHERE ((pg.tenant_id = tc.tenant_id) AND (pg.device_id = tc.device_id) AND (pg.quantity_id = tc.quantity_id) AND ((tc.bucket >= pg.gap_start) AND (tc.bucket <= pg.gap_end)))))))
        )
 SELECT tenant_id,
    device_id,
    quantity_id,
    hour_of_day,
    day_of_week,
    (sum((interval_value * time_weight)) / sum(time_weight)) AS avg_consumption_per_15min,
    avg(interval_value) AS simple_avg_consumption,
    stddev(interval_value) AS stddev_consumption,
    count(*) AS total_samples,
    sum(time_weight) AS weighted_sample_count,
    count(*) FILTER (WHERE (interval_value > (0)::numeric)) AS non_zero_samples,
        CASE
            WHEN (sum(time_weight) >= 8.0) THEN 'HIGH'::text
            WHEN (sum(time_weight) >= 4.0) THEN 'MEDIUM'::text
            WHEN (sum(time_weight) >= 2.0) THEN 'LOW'::text
            ELSE 'INSUFFICIENT'::text
        END AS pattern_confidence,
    min(interval_value) AS min_consumption,
    max(interval_value) AS max_consumption,
    percentile_cont((0.75)::double precision) WITHIN GROUP (ORDER BY ((interval_value)::double precision)) AS p75_consumption,
    count(*) AS raw_sample_count,
    min(bucket) AS earliest_data,
    max(bucket) AS latest_data,
    CURRENT_TIMESTAMP AS calculated_at
   FROM clean_telemetry_data
  GROUP BY tenant_id, device_id, quantity_id, hour_of_day, day_of_week
 HAVING (count(*) >= 1)
  ORDER BY tenant_id, device_id, quantity_id, day_of_week, hour_of_day
  WITH NO DATA;


--
-- Name: device_files; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.device_files (
    id integer NOT NULL,
    device_id integer NOT NULL,
    file_id integer NOT NULL,
    file_category character varying(50) NOT NULL,
    is_primary boolean DEFAULT false,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: device_files_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.device_files_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: device_files_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.device_files_id_seq OWNED BY public.device_files.id;


--
-- Name: device_mappings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.device_mappings (
    id integer NOT NULL,
    device_id integer NOT NULL,
    external_system character varying(50) NOT NULL,
    external_id character varying(255) NOT NULL,
    external_name character varying(255),
    mapping_metadata jsonb,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: device_mappings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.device_mappings_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: device_mappings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.device_mappings_id_seq OWNED BY public.device_mappings.id;


--
-- Name: device_tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.device_tags (
    id integer NOT NULL,
    device_id integer NOT NULL,
    tag_key character varying(100) NOT NULL,
    tag_value character varying(255) NOT NULL,
    tag_category character varying(50),
    tag_description text,
    effective_from date DEFAULT CURRENT_DATE,
    effective_to date,
    is_active boolean DEFAULT true,
    confidence_level character varying(20) DEFAULT 'HIGH'::character varying,
    data_source character varying(50) DEFAULT 'MANUAL'::character varying,
    validation_status character varying(20) DEFAULT 'PENDING'::character varying,
    created_by character varying(100),
    validated_by character varying(100),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT check_effective_dates CHECK (((effective_to IS NULL) OR (effective_to >= effective_from)))
);


--
-- Name: device_tags_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.device_tags_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: device_tags_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.device_tags_id_seq OWNED BY public.device_tags.id;


--
-- Name: device_utility_mappings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.device_utility_mappings (
    id integer NOT NULL,
    device_id integer NOT NULL,
    utility_source_id integer NOT NULL,
    mapping_type character varying(50) DEFAULT 'CONSUMPTION'::character varying,
    priority_order integer DEFAULT 1,
    allocation_percentage numeric(5,2) DEFAULT 100.00,
    effective_from date NOT NULL,
    effective_to date,
    is_active boolean DEFAULT true,
    mapping_notes text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_by character varying(100),
    CONSTRAINT check_allocation CHECK (((allocation_percentage > (0)::numeric) AND (allocation_percentage <= (100)::numeric))),
    CONSTRAINT check_mapping_effective_dates CHECK (((effective_to IS NULL) OR (effective_to >= effective_from))),
    CONSTRAINT check_mapping_type CHECK (((mapping_type)::text = ANY ((ARRAY['CONSUMPTION'::character varying, 'GENERATION'::character varying, 'BIDIRECTIONAL'::character varying])::text[])))
);


--
-- Name: TABLE device_utility_mappings; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.device_utility_mappings IS 'Maps devices to their corresponding utility sources for billing and cost allocation';


--
-- Name: COLUMN device_utility_mappings.mapping_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.device_utility_mappings.mapping_type IS 'CONSUMPTION (using utility), GENERATION (producing utility), BIDIRECTIONAL';


--
-- Name: device_utility_mappings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.device_utility_mappings_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: device_utility_mappings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.device_utility_mappings_id_seq OWNED BY public.device_utility_mappings.id;


--
-- Name: devices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.devices (
    id integer NOT NULL,
    tenant_id integer NOT NULL,
    asset_id integer,
    device_code character varying(100) NOT NULL,
    device_name character varying(255) NOT NULL,
    device_type character varying(100),
    display_name character varying(255),
    alias character varying(255),
    is_active boolean DEFAULT true,
    metadata jsonb,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    status character varying(50) DEFAULT 'ONLINE'::character varying,
    last_maintenance timestamp without time zone,
    next_maintenance timestamp without time zone,
    CONSTRAINT check_device_status CHECK (((status)::text = ANY ((ARRAY['ONLINE'::character varying, 'OFFLINE'::character varying, 'WARNING'::character varying, 'MAINTENANCE'::character varying, 'ERROR'::character varying])::text[])))
);


--
-- Name: devices_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.devices_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: devices_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.devices_id_seq OWNED BY public.devices.id;


--
-- Name: energy_costs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.energy_costs (
    id integer NOT NULL,
    tenant_id integer NOT NULL,
    device_id integer NOT NULL,
    asset_id integer,
    calculation_date date NOT NULL,
    period_name character varying(100),
    energy_kwh numeric(12,3),
    cost_amount numeric(12,2),
    rate_used numeric(10,4),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: energy_costs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.energy_costs_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: energy_costs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.energy_costs_id_seq OWNED BY public.energy_costs.id;


--
-- Name: enpi_calculations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.enpi_calculations (
    id integer NOT NULL,
    tenant_id integer NOT NULL,
    asset_id integer NOT NULL,
    calculation_date date NOT NULL,
    enpi_type character varying(100) NOT NULL,
    energy_consumption numeric(15,3) NOT NULL,
    operational_metric numeric(15,3) NOT NULL,
    enpi_value numeric(15,6) NOT NULL,
    baseline_enpi numeric(15,6),
    improvement_percentage numeric(5,2),
    calculation_params jsonb,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: enpi_calculations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.enpi_calculations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: enpi_calculations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.enpi_calculations_id_seq OWNED BY public.enpi_calculations.id;


--
-- Name: file_storage; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.file_storage (
    id integer NOT NULL,
    tenant_id integer NOT NULL,
    file_name character varying(255) NOT NULL,
    file_type character varying(50) NOT NULL,
    file_path text NOT NULL,
    file_size bigint,
    mime_type character varying(100),
    version integer DEFAULT 1,
    parent_file_id integer,
    metadata jsonb,
    uploaded_by character varying(100),
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: file_storage_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.file_storage_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: file_storage_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.file_storage_id_seq OWNED BY public.file_storage.id;


--
-- Name: hotspot_coordinates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hotspot_coordinates (
    id integer NOT NULL,
    asset_id integer,
    device_id integer,
    file_id integer,
    coordinate_type character varying(50) NOT NULL,
    x_coordinate numeric(10,3),
    y_coordinate numeric(10,3),
    z_coordinate numeric(10,3),
    yaw numeric(6,2),
    pitch numeric(6,2),
    hotspot_label character varying(255),
    hotspot_color character varying(20),
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    hotspot_type character varying(50) DEFAULT 'EQUIPMENT'::character varying,
    level integer DEFAULT 0,
    navigation_target_id integer,
    chart_data_source_id integer,
    CONSTRAINT check_coordinate_reference CHECK ((((asset_id IS NOT NULL) AND (device_id IS NULL)) OR ((asset_id IS NULL) AND (device_id IS NOT NULL)))),
    CONSTRAINT check_hotspot_type CHECK (((hotspot_type)::text = ANY ((ARRAY['EQUIPMENT'::character varying, 'SENSOR'::character varying, 'NAVIGATION'::character varying, 'CHART'::character varying, 'INFO'::character varying])::text[])))
);


--
-- Name: hotspot_coordinates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.hotspot_coordinates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: hotspot_coordinates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.hotspot_coordinates_id_seq OWNED BY public.hotspot_coordinates.id;


--
-- Name: operational_data; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.operational_data (
    id integer NOT NULL,
    tenant_id integer NOT NULL,
    asset_id integer,
    data_date date NOT NULL,
    metric_type character varying(100) NOT NULL,
    metric_value numeric(15,3) NOT NULL,
    metric_unit character varying(50),
    data_source character varying(100),
    batch_id uuid DEFAULT gen_random_uuid(),
    uploaded_by character varying(100),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: operational_data_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.operational_data_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: operational_data_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.operational_data_id_seq OWNED BY public.operational_data.id;


--
-- Name: pme_quantity_mapping; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pme_quantity_mapping (
    pme_quantity_id integer NOT NULL,
    new_quantity_id integer NOT NULL,
    quantity_code character varying(50) NOT NULL,
    quantity_name character varying(255) NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: processed_gaps_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.processed_gaps_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: processed_gaps_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.processed_gaps_id_seq OWNED BY public.processed_gaps.id;


--
-- Name: quantities_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.quantities_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: quantities_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.quantities_id_seq OWNED BY public.quantities.id;


--
-- Name: redistributed_intervals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.redistributed_intervals (
    id integer NOT NULL,
    gap_id integer NOT NULL,
    bucket timestamp without time zone NOT NULL,
    redistributed_value numeric NOT NULL,
    confidence_score numeric(3,2),
    pattern_source character varying(50),
    weight_factor numeric(8,6),
    expected_pattern_value numeric,
    actual_redistributed_value numeric NOT NULL,
    CONSTRAINT check_redistributed_value CHECK ((redistributed_value >= (0)::numeric)),
    CONSTRAINT redistributed_intervals_confidence_score_check CHECK (((confidence_score >= (0)::numeric) AND (confidence_score <= (1)::numeric)))
);


--
-- Name: redistributed_intervals_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.redistributed_intervals_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: redistributed_intervals_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.redistributed_intervals_id_seq OWNED BY public.redistributed_intervals.id;


--
-- Name: sankey_levels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sankey_levels (
    id integer NOT NULL,
    sankey_mapping_id integer NOT NULL,
    level_order integer NOT NULL,
    level_name character varying(255) NOT NULL,
    asset_type character varying(100),
    filter_criteria jsonb,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT valid_level_order CHECK ((level_order >= '-1'::integer))
);


--
-- Name: TABLE sankey_levels; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.sankey_levels IS 'Defines hierarchical levels for each sankey mapping';


--
-- Name: COLUMN sankey_levels.level_order; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sankey_levels.level_order IS 'Hierarchical order: -1=external sources, 0=root, 1=next level, etc.';


--
-- Name: COLUMN sankey_levels.asset_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sankey_levels.asset_type IS 'Filter nodes by asset type: COMPANY, FACILITY, EQUIPMENT, etc.';


--
-- Name: COLUMN sankey_levels.filter_criteria; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sankey_levels.filter_criteria IS 'Additional JSON filtering rules for node selection';


--
-- Name: sankey_levels_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sankey_levels_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sankey_levels_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sankey_levels_id_seq OWNED BY public.sankey_levels.id;


--
-- Name: sankey_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sankey_links (
    id integer NOT NULL,
    sankey_mapping_id integer NOT NULL,
    source_node_id character varying(255) NOT NULL,
    target_node_id character varying(255) NOT NULL,
    quantity_id integer,
    calculation_formula text,
    aggregation_method character varying(50) DEFAULT 'sum'::character varying,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT no_self_link CHECK (((source_node_id)::text <> (target_node_id)::text)),
    CONSTRAINT valid_aggregation_method CHECK (((aggregation_method)::text = ANY ((ARRAY['sum'::character varying, 'avg'::character varying, 'min'::character varying, 'max'::character varying, 'count'::character varying])::text[])))
);


--
-- Name: TABLE sankey_links; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.sankey_links IS 'Defines connections between sankey nodes with telemetry aggregation rules';


--
-- Name: COLUMN sankey_links.source_node_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sankey_links.source_node_id IS 'Source node identifier (references sankey_nodes.node_id)';


--
-- Name: COLUMN sankey_links.target_node_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sankey_links.target_node_id IS 'Target node identifier (references sankey_nodes.node_id)';


--
-- Name: COLUMN sankey_links.quantity_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sankey_links.quantity_id IS 'Which telemetry quantity to aggregate for link value';


--
-- Name: COLUMN sankey_links.calculation_formula; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sankey_links.calculation_formula IS 'Optional custom calculation logic for complex scenarios';


--
-- Name: COLUMN sankey_links.aggregation_method; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sankey_links.aggregation_method IS 'How to aggregate telemetry data: sum, avg, min, max, count';


--
-- Name: sankey_links_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sankey_links_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sankey_links_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sankey_links_id_seq OWNED BY public.sankey_links.id;


--
-- Name: sankey_mappings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sankey_mappings (
    id integer NOT NULL,
    tenant_id integer NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    type character varying(100) NOT NULL,
    is_cumulative boolean DEFAULT false,
    is_active boolean DEFAULT true,
    configuration jsonb,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT valid_sankey_type CHECK (((type)::text = ANY ((ARRAY['energy_flow'::character varying, 'air_volume_flow'::character varying, 'water_flow'::character varying, 'energy_balance'::character varying, 'custom'::character varying])::text[])))
);


--
-- Name: TABLE sankey_mappings; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.sankey_mappings IS 'Defines different sankey diagram types available for each tenant';


--
-- Name: COLUMN sankey_mappings.type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sankey_mappings.type IS 'Type of sankey diagram: energy_flow, air_volume_flow, water_flow, energy_balance, custom';


--
-- Name: COLUMN sankey_mappings.is_cumulative; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sankey_mappings.is_cumulative IS 'Whether to use interval consumption calculation for telemetry aggregation';


--
-- Name: COLUMN sankey_mappings.configuration; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sankey_mappings.configuration IS 'JSON configuration for diagram settings like maxNodes, refreshInterval, etc.';


--
-- Name: sankey_mappings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sankey_mappings_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sankey_mappings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sankey_mappings_id_seq OWNED BY public.sankey_mappings.id;


--
-- Name: sankey_mappings_summary; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.sankey_mappings_summary AS
 SELECT sm.id,
    sm.tenant_id,
    sm.name,
    sm.description,
    sm.type,
    sm.is_cumulative,
    sm.is_active,
    sm.configuration,
    count(sl.id) AS level_count,
    sm.created_at,
    sm.updated_at
   FROM (public.sankey_mappings sm
     LEFT JOIN public.sankey_levels sl ON ((sm.id = sl.sankey_mapping_id)))
  WHERE (sm.is_active = true)
  GROUP BY sm.id, sm.tenant_id, sm.name, sm.description, sm.type, sm.is_cumulative, sm.is_active, sm.configuration, sm.created_at, sm.updated_at;


--
-- Name: sankey_nodes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sankey_nodes (
    id integer NOT NULL,
    sankey_mapping_id integer NOT NULL,
    node_id character varying(255) NOT NULL,
    asset_id integer,
    device_id integer,
    node_name character varying(255) NOT NULL,
    level_id integer,
    node_type character varying(50) DEFAULT 'asset'::character varying NOT NULL,
    metadata jsonb,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT asset_or_device_check CHECK ((((asset_id IS NOT NULL) AND (device_id IS NULL)) OR ((asset_id IS NULL) AND (device_id IS NOT NULL)) OR ((asset_id IS NULL) AND (device_id IS NULL) AND ((node_type)::text = ANY ((ARRAY['virtual'::character varying, 'external_source'::character varying])::text[]))))),
    CONSTRAINT valid_node_type CHECK (((node_type)::text = ANY ((ARRAY['asset'::character varying, 'device'::character varying, 'virtual'::character varying, 'external_source'::character varying])::text[])))
);


--
-- Name: TABLE sankey_nodes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.sankey_nodes IS 'Pre-configured nodes for sankey mappings (optional, supports dynamic generation)';


--
-- Name: COLUMN sankey_nodes.node_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sankey_nodes.node_id IS 'Unique identifier within the mapping scope';


--
-- Name: COLUMN sankey_nodes.node_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sankey_nodes.node_type IS 'Type of node: asset, device, virtual, external_source';


--
-- Name: COLUMN sankey_nodes.metadata; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.sankey_nodes.metadata IS 'Additional node properties for rendering and behavior';


--
-- Name: sankey_nodes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sankey_nodes_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sankey_nodes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sankey_nodes_id_seq OWNED BY public.sankey_nodes.id;


--
-- Name: shared_quantities_summary; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.shared_quantities_summary AS
 SELECT q.category,
    q.data_type,
    count(DISTINCT q.id) AS total_quantities,
    count(DISTINCT td.device_id) AS devices_using_category,
    avg(COALESCE((td.quality)::numeric, 1.0)) AS avg_quality_score,
    count(*) AS total_measurements,
    min(td."timestamp") AS earliest_measurement,
    max(td."timestamp") AS latest_measurement
   FROM (public.quantities q
     LEFT JOIN public.telemetry_data td ON ((q.id = td.quantity_id)))
  WHERE ((q.is_active = true) AND (td."timestamp" >= (CURRENT_TIMESTAMP - '30 days'::interval)))
  GROUP BY q.category, q.data_type
  ORDER BY (count(*)) DESC;


--
-- Name: telemetry_unified_raw; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

CREATE MATERIALIZED VIEW public.telemetry_unified_raw AS
 SELECT td."timestamp",
    d.tenant_id,
    td.device_id,
    td.quantity_id,
    q.quantity_code,
    q.quantity_name,
    q.unit,
    td.value AS raw_value,
        CASE
            WHEN q.is_cumulative THEN (td.value - lag(td.value) OVER (PARTITION BY d.tenant_id, td.device_id, td.quantity_id ORDER BY td."timestamp"))
            ELSE td.value
        END AS display_value,
    td.quality,
    td.source_system,
    td.created_at,
    q.is_cumulative
   FROM ((public.telemetry_data td
     JOIN public.devices d ON (((td.device_id = d.id) AND (d.is_active = true))))
     JOIN public.quantities q ON ((td.quantity_id = q.id)))
  WHERE (td."timestamp" >= (now() - '14 days'::interval))
  WITH NO DATA;


--
-- Name: tenant_shift_periods; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenant_shift_periods (
    id integer NOT NULL,
    tenant_id integer NOT NULL,
    shift_name character varying(50) NOT NULL,
    start_hour integer NOT NULL,
    end_hour integer NOT NULL,
    description text,
    effective_from date NOT NULL,
    effective_to date,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT tenant_shift_periods_end_hour_check CHECK (((end_hour >= 0) AND (end_hour <= 23))),
    CONSTRAINT tenant_shift_periods_start_hour_check CHECK (((start_hour >= 0) AND (start_hour <= 23)))
);


--
-- Name: tenant_shift_periods_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tenant_shift_periods_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tenant_shift_periods_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tenant_shift_periods_id_seq OWNED BY public.tenant_shift_periods.id;


--
-- Name: tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tenants (
    id integer NOT NULL,
    tenant_code character varying(50) NOT NULL,
    tenant_name character varying(255) NOT NULL,
    tenant_type character varying(50) NOT NULL,
    description text,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT tenants_tenant_type_check CHECK (((tenant_type)::text = ANY ((ARRAY['PME'::character varying, 'THINGSBOARD'::character varying])::text[])))
);


--
-- Name: tenants_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tenants_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tenants_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tenants_id_seq OWNED BY public.tenants.id;


--
-- Name: tou_rate_periods; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tou_rate_periods (
    id integer NOT NULL,
    tenant_id integer NOT NULL,
    period_name character varying(100) NOT NULL,
    start_hour integer NOT NULL,
    end_hour integer NOT NULL,
    rate_per_kwh numeric(10,4) NOT NULL,
    effective_from date NOT NULL,
    effective_to date,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT tou_rate_periods_end_hour_check CHECK (((end_hour >= 0) AND (end_hour <= 24))),
    CONSTRAINT tou_rate_periods_start_hour_check CHECK (((start_hour >= 0) AND (start_hour <= 23)))
);


--
-- Name: tou_rate_periods_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tou_rate_periods_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tou_rate_periods_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tou_rate_periods_id_seq OWNED BY public.tou_rate_periods.id;


--
-- Name: user_tenant_access_debug; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.user_tenant_access_debug AS
 SELECT u.id AS user_id,
    u.email,
    ut.tenant_id,
    p.product_code,
    ut.role,
    ut.permissions,
    p.features,
    ut.is_active,
    ut.expires_at
   FROM ((public.auth_users u
     JOIN public.auth_user_tenants ut ON ((u.id = ut.user_id)))
     JOIN public.auth_products p ON ((ut.product_id = p.id)))
  WHERE (u.is_active = true)
  ORDER BY u.id, ut.tenant_id;


--
-- Name: utility_rates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.utility_rates (
    id integer NOT NULL,
    utility_source_id integer NOT NULL,
    rate_code character varying(50) NOT NULL,
    rate_name character varying(100) NOT NULL,
    rate_structure character varying(50) DEFAULT 'TIME_OF_USE'::character varying NOT NULL,
    start_hour integer,
    end_hour integer,
    applies_to_days integer[] DEFAULT ARRAY[1, 2, 3, 4, 5, 6, 7],
    tier_min_usage numeric(15,3),
    tier_max_usage numeric(15,3),
    rate_per_unit numeric(12,4) NOT NULL,
    fixed_charge numeric(12,2) DEFAULT 0,
    demand_charge numeric(12,4) DEFAULT 0,
    currency_code character varying(3) DEFAULT 'IDR'::character varying,
    rate_unit character varying(20),
    effective_from date NOT NULL,
    effective_to date,
    rate_parameters jsonb,
    is_active boolean DEFAULT true,
    description text,
    notes text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    created_by character varying(100),
    tenant_id integer NOT NULL,
    CONSTRAINT check_effective_dates CHECK (((effective_to IS NULL) OR (effective_to >= effective_from))),
    CONSTRAINT check_rate_structure CHECK (((rate_structure)::text = ANY ((ARRAY['TIME_OF_USE'::character varying, 'TIERED'::character varying, 'PROGRESSIVE'::character varying, 'FLAT'::character varying, 'DEMAND_BASED'::character varying, 'SEASONAL'::character varying])::text[]))),
    CONSTRAINT check_tier_logic CHECK (((((rate_structure)::text = ANY ((ARRAY['TIERED'::character varying, 'PROGRESSIVE'::character varying])::text[])) AND (tier_min_usage IS NOT NULL)) OR ((rate_structure)::text <> ALL ((ARRAY['TIERED'::character varying, 'PROGRESSIVE'::character varying])::text[])))),
    CONSTRAINT check_time_logic CHECK (((((rate_structure)::text = 'TIME_OF_USE'::text) AND (start_hour IS NOT NULL) AND (end_hour IS NOT NULL)) OR ((rate_structure)::text <> 'TIME_OF_USE'::text))),
    CONSTRAINT utility_rates_end_hour_check CHECK (((end_hour >= 0) AND (end_hour <= 23))),
    CONSTRAINT utility_rates_start_hour_check CHECK (((start_hour >= 0) AND (start_hour <= 23)))
);


--
-- Name: TABLE utility_rates; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.utility_rates IS 'Enhanced rate table supporting multiple rate structures across all utility types';


--
-- Name: COLUMN utility_rates.rate_structure; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.utility_rates.rate_structure IS 'Pricing model: TIME_OF_USE, TIERED, PROGRESSIVE, FLAT';


--
-- Name: COLUMN utility_rates.rate_per_unit; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.utility_rates.rate_per_unit IS 'Rate per base unit (kWh, m³, L, etc.) in local currency';


--
-- Name: utility_rates_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.utility_rates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: utility_rates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.utility_rates_id_seq OWNED BY public.utility_rates.id;


--
-- Name: utility_sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.utility_sources (
    id integer NOT NULL,
    tenant_id integer NOT NULL,
    source_code character varying(50) NOT NULL,
    source_name character varying(100) NOT NULL,
    source_type character varying(50) NOT NULL,
    utility_type character varying(50) NOT NULL,
    base_unit character varying(20) DEFAULT 'kWh'::character varying NOT NULL,
    measurement_type character varying(50) DEFAULT 'ENERGY'::character varying,
    provider_name character varying(100),
    provider_contact jsonb,
    description text,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT check_base_unit CHECK (((base_unit)::text = ANY ((ARRAY['kWh'::character varying, 'kW'::character varying, 'm³'::character varying, 'L'::character varying, 'kg'::character varying, 'BTU'::character varying, 'MJ'::character varying, 'Therm'::character varying, 'MMBTU'::character varying])::text[]))),
    CONSTRAINT check_utility_type CHECK (((utility_type)::text = ANY ((ARRAY['ELECTRICITY'::character varying, 'NATURAL_GAS'::character varying, 'LPG'::character varying, 'WATER'::character varying, 'TREATED_WATER'::character varying, 'CHILLED_WATER'::character varying, 'COMPRESSED_AIR'::character varying, 'STEAM'::character varying, 'HOT_WATER'::character varying, 'OTHER'::character varying])::text[])))
);


--
-- Name: TABLE utility_sources; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.utility_sources IS 'Defines utility sources/suppliers for different utility types (electricity, gas, water, etc.)';


--
-- Name: COLUMN utility_sources.source_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.utility_sources.source_code IS 'Unique identifier for the utility source within tenant';


--
-- Name: COLUMN utility_sources.utility_type; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.utility_sources.utility_type IS 'Type of utility: ELECTRICITY, NATURAL_GAS, WATER, etc.';


--
-- Name: utility_sources_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.utility_sources_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: utility_sources_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.utility_sources_id_seq OWNED BY public.utility_sources.id;


--
-- Name: _hyper_1_5611_chunk quality; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5611_chunk ALTER COLUMN quality SET DEFAULT 1;


--
-- Name: _hyper_1_5611_chunk created_at; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5611_chunk ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;


--
-- Name: _hyper_1_5612_chunk quality; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5612_chunk ALTER COLUMN quality SET DEFAULT 1;


--
-- Name: _hyper_1_5612_chunk created_at; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5612_chunk ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;


--
-- Name: _hyper_1_5613_chunk quality; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5613_chunk ALTER COLUMN quality SET DEFAULT 1;


--
-- Name: _hyper_1_5613_chunk created_at; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5613_chunk ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;


--
-- Name: _hyper_1_5614_chunk quality; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5614_chunk ALTER COLUMN quality SET DEFAULT 1;


--
-- Name: _hyper_1_5614_chunk created_at; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5614_chunk ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;


--
-- Name: _hyper_1_5615_chunk quality; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5615_chunk ALTER COLUMN quality SET DEFAULT 1;


--
-- Name: _hyper_1_5615_chunk created_at; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5615_chunk ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;


--
-- Name: _hyper_1_5616_chunk quality; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5616_chunk ALTER COLUMN quality SET DEFAULT 1;


--
-- Name: _hyper_1_5616_chunk created_at; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5616_chunk ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;


--
-- Name: _hyper_1_5618_chunk quality; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5618_chunk ALTER COLUMN quality SET DEFAULT 1;


--
-- Name: _hyper_1_5618_chunk created_at; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5618_chunk ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;


--
-- Name: _hyper_1_5619_chunk quality; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5619_chunk ALTER COLUMN quality SET DEFAULT 1;


--
-- Name: _hyper_1_5619_chunk created_at; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5619_chunk ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;


--
-- Name: _hyper_1_5620_chunk quality; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5620_chunk ALTER COLUMN quality SET DEFAULT 1;


--
-- Name: _hyper_1_5620_chunk created_at; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5620_chunk ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;


--
-- Name: _hyper_1_5621_chunk quality; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5621_chunk ALTER COLUMN quality SET DEFAULT 1;


--
-- Name: _hyper_1_5621_chunk created_at; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5621_chunk ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;


--
-- Name: _hyper_1_5622_chunk quality; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5622_chunk ALTER COLUMN quality SET DEFAULT 1;


--
-- Name: _hyper_1_5622_chunk created_at; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5622_chunk ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;


--
-- Name: _hyper_1_5623_chunk quality; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5623_chunk ALTER COLUMN quality SET DEFAULT 1;


--
-- Name: _hyper_1_5623_chunk created_at; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5623_chunk ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;


--
-- Name: _hyper_1_5624_chunk quality; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5624_chunk ALTER COLUMN quality SET DEFAULT 1;


--
-- Name: _hyper_1_5624_chunk created_at; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5624_chunk ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;


--
-- Name: _hyper_1_5625_chunk quality; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5625_chunk ALTER COLUMN quality SET DEFAULT 1;


--
-- Name: _hyper_1_5625_chunk created_at; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5625_chunk ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;


--
-- Name: _hyper_1_5626_chunk quality; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5626_chunk ALTER COLUMN quality SET DEFAULT 1;


--
-- Name: _hyper_1_5626_chunk created_at; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5626_chunk ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;


--
-- Name: _hyper_6_1_chunk id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_6_1_chunk ALTER COLUMN id SET DEFAULT nextval('public.audit_logs_id_seq'::regclass);


--
-- Name: _hyper_6_1_chunk created_at; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_6_1_chunk ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;


--
-- Name: _hyper_6_305_chunk id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_6_305_chunk ALTER COLUMN id SET DEFAULT nextval('public.audit_logs_id_seq'::regclass);


--
-- Name: _hyper_6_305_chunk created_at; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_6_305_chunk ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;


--
-- Name: _hyper_6_5559_chunk id; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_6_5559_chunk ALTER COLUMN id SET DEFAULT nextval('public.audit_logs_id_seq'::regclass);


--
-- Name: _hyper_6_5559_chunk created_at; Type: DEFAULT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_6_5559_chunk ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP;


--
-- Name: baseline_load_profiles id; Type: DEFAULT; Schema: prs; Owner: -
--

ALTER TABLE ONLY prs.baseline_load_profiles ALTER COLUMN id SET DEFAULT nextval('prs.baseline_load_profiles_id_seq'::regclass);


--
-- Name: asset_connections id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_connections ALTER COLUMN id SET DEFAULT nextval('public.asset_connections_id_seq'::regclass);


--
-- Name: asset_files id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_files ALTER COLUMN id SET DEFAULT nextval('public.asset_files_id_seq'::regclass);


--
-- Name: asset_tags id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_tags ALTER COLUMN id SET DEFAULT nextval('public.asset_tags_id_seq'::regclass);


--
-- Name: assets id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assets ALTER COLUMN id SET DEFAULT nextval('public.assets_id_seq'::regclass);


--
-- Name: audit_logs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs ALTER COLUMN id SET DEFAULT nextval('public.audit_logs_id_seq'::regclass);


--
-- Name: auth_audit_logs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_audit_logs ALTER COLUMN id SET DEFAULT nextval('public.auth_audit_logs_id_seq'::regclass);


--
-- Name: auth_email_verifications id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_email_verifications ALTER COLUMN id SET DEFAULT nextval('public.auth_email_verifications_id_seq'::regclass);


--
-- Name: auth_oauth_providers id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_oauth_providers ALTER COLUMN id SET DEFAULT nextval('public.auth_oauth_providers_id_seq'::regclass);


--
-- Name: auth_password_resets id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_password_resets ALTER COLUMN id SET DEFAULT nextval('public.auth_password_resets_id_seq'::regclass);


--
-- Name: auth_permissions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_permissions ALTER COLUMN id SET DEFAULT nextval('public.auth_permissions_id_seq'::regclass);


--
-- Name: auth_products id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_products ALTER COLUMN id SET DEFAULT nextval('public.auth_products_id_seq'::regclass);


--
-- Name: auth_role_permissions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_role_permissions ALTER COLUMN id SET DEFAULT nextval('public.auth_role_permissions_id_seq'::regclass);


--
-- Name: auth_roles id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_roles ALTER COLUMN id SET DEFAULT nextval('public.auth_roles_id_seq'::regclass);


--
-- Name: auth_user_oauth id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_user_oauth ALTER COLUMN id SET DEFAULT nextval('public.auth_user_oauth_id_seq'::regclass);


--
-- Name: auth_user_sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_user_sessions ALTER COLUMN id SET DEFAULT nextval('public.auth_user_sessions_id_seq'::regclass);


--
-- Name: auth_user_tenants id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_user_tenants ALTER COLUMN id SET DEFAULT nextval('public.auth_user_tenants_id_seq'::regclass);


--
-- Name: auth_users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_users ALTER COLUMN id SET DEFAULT nextval('public.auth_users_id_seq'::regclass);


--
-- Name: daily_energy_refresh_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_energy_refresh_log ALTER COLUMN id SET DEFAULT nextval('public.daily_energy_refresh_log_id_seq'::regclass);


--
-- Name: device_alerts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_alerts ALTER COLUMN id SET DEFAULT nextval('public.device_alerts_id_seq'::regclass);


--
-- Name: device_files id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_files ALTER COLUMN id SET DEFAULT nextval('public.device_files_id_seq'::regclass);


--
-- Name: device_mappings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_mappings ALTER COLUMN id SET DEFAULT nextval('public.device_mappings_id_seq'::regclass);


--
-- Name: device_tags id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_tags ALTER COLUMN id SET DEFAULT nextval('public.device_tags_id_seq'::regclass);


--
-- Name: device_utility_mappings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_utility_mappings ALTER COLUMN id SET DEFAULT nextval('public.device_utility_mappings_id_seq'::regclass);


--
-- Name: devices id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices ALTER COLUMN id SET DEFAULT nextval('public.devices_id_seq'::regclass);


--
-- Name: energy_costs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.energy_costs ALTER COLUMN id SET DEFAULT nextval('public.energy_costs_id_seq'::regclass);


--
-- Name: enpi_calculations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enpi_calculations ALTER COLUMN id SET DEFAULT nextval('public.enpi_calculations_id_seq'::regclass);


--
-- Name: file_storage id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_storage ALTER COLUMN id SET DEFAULT nextval('public.file_storage_id_seq'::regclass);


--
-- Name: hotspot_coordinates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hotspot_coordinates ALTER COLUMN id SET DEFAULT nextval('public.hotspot_coordinates_id_seq'::regclass);


--
-- Name: operational_data id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_data ALTER COLUMN id SET DEFAULT nextval('public.operational_data_id_seq'::regclass);


--
-- Name: processed_gaps id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processed_gaps ALTER COLUMN id SET DEFAULT nextval('public.processed_gaps_id_seq'::regclass);


--
-- Name: quantities id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quantities ALTER COLUMN id SET DEFAULT nextval('public.quantities_id_seq'::regclass);


--
-- Name: redistributed_intervals id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.redistributed_intervals ALTER COLUMN id SET DEFAULT nextval('public.redistributed_intervals_id_seq'::regclass);


--
-- Name: sankey_levels id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sankey_levels ALTER COLUMN id SET DEFAULT nextval('public.sankey_levels_id_seq'::regclass);


--
-- Name: sankey_links id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sankey_links ALTER COLUMN id SET DEFAULT nextval('public.sankey_links_id_seq'::regclass);


--
-- Name: sankey_mappings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sankey_mappings ALTER COLUMN id SET DEFAULT nextval('public.sankey_mappings_id_seq'::regclass);


--
-- Name: sankey_nodes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sankey_nodes ALTER COLUMN id SET DEFAULT nextval('public.sankey_nodes_id_seq'::regclass);


--
-- Name: tenant_shift_periods id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_shift_periods ALTER COLUMN id SET DEFAULT nextval('public.tenant_shift_periods_id_seq'::regclass);


--
-- Name: tenants id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants ALTER COLUMN id SET DEFAULT nextval('public.tenants_id_seq'::regclass);


--
-- Name: tou_rate_periods id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tou_rate_periods ALTER COLUMN id SET DEFAULT nextval('public.tou_rate_periods_id_seq'::regclass);


--
-- Name: utility_rates id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_rates ALTER COLUMN id SET DEFAULT nextval('public.utility_rates_id_seq'::regclass);


--
-- Name: utility_sources id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_sources ALTER COLUMN id SET DEFAULT nextval('public.utility_sources_id_seq'::regclass);


--
-- Name: _hyper_6_1_chunk 1_1_audit_logs_pkey; Type: CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_6_1_chunk
    ADD CONSTRAINT "1_1_audit_logs_pkey" PRIMARY KEY (id, created_at);


--
-- Name: _hyper_6_305_chunk 305_743_audit_logs_pkey; Type: CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_6_305_chunk
    ADD CONSTRAINT "305_743_audit_logs_pkey" PRIMARY KEY (id, created_at);


--
-- Name: _hyper_6_5559_chunk 5559_16483_audit_logs_pkey; Type: CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_6_5559_chunk
    ADD CONSTRAINT "5559_16483_audit_logs_pkey" PRIMARY KEY (id, created_at);


--
-- Name: baseline_load_profiles baseline_load_profiles_pkey; Type: CONSTRAINT; Schema: prs; Owner: -
--

ALTER TABLE ONLY prs.baseline_load_profiles
    ADD CONSTRAINT baseline_load_profiles_pkey PRIMARY KEY (id);


--
-- Name: baseline_load_profiles unique_baseline_version; Type: CONSTRAINT; Schema: prs; Owner: -
--

ALTER TABLE ONLY prs.baseline_load_profiles
    ADD CONSTRAINT unique_baseline_version UNIQUE (tenant_id, baseline_version, profile_type, shift_name, day_type, load_group, time_hhmm);


--
-- Name: asset_connections asset_connections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_connections
    ADD CONSTRAINT asset_connections_pkey PRIMARY KEY (id);


--
-- Name: asset_files asset_files_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_files
    ADD CONSTRAINT asset_files_pkey PRIMARY KEY (id);


--
-- Name: asset_tags asset_tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_tags
    ADD CONSTRAINT asset_tags_pkey PRIMARY KEY (id);


--
-- Name: assets assets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_pkey PRIMARY KEY (id);


--
-- Name: audit_logs audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id, created_at);


--
-- Name: auth_audit_logs auth_audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_audit_logs
    ADD CONSTRAINT auth_audit_logs_pkey PRIMARY KEY (id);


--
-- Name: auth_email_verifications auth_email_verifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_email_verifications
    ADD CONSTRAINT auth_email_verifications_pkey PRIMARY KEY (id);


--
-- Name: auth_email_verifications auth_email_verifications_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_email_verifications
    ADD CONSTRAINT auth_email_verifications_token_hash_key UNIQUE (token_hash);


--
-- Name: auth_oauth_providers auth_oauth_providers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_oauth_providers
    ADD CONSTRAINT auth_oauth_providers_pkey PRIMARY KEY (id);


--
-- Name: auth_oauth_providers auth_oauth_providers_provider_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_oauth_providers
    ADD CONSTRAINT auth_oauth_providers_provider_code_key UNIQUE (provider_code);


--
-- Name: auth_password_resets auth_password_resets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_password_resets
    ADD CONSTRAINT auth_password_resets_pkey PRIMARY KEY (id);


--
-- Name: auth_password_resets auth_password_resets_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_password_resets
    ADD CONSTRAINT auth_password_resets_token_hash_key UNIQUE (token_hash);


--
-- Name: auth_permissions auth_permissions_permission_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_permissions
    ADD CONSTRAINT auth_permissions_permission_code_key UNIQUE (permission_code);


--
-- Name: auth_permissions auth_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_permissions
    ADD CONSTRAINT auth_permissions_pkey PRIMARY KEY (id);


--
-- Name: auth_products auth_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_products
    ADD CONSTRAINT auth_products_pkey PRIMARY KEY (id);


--
-- Name: auth_products auth_products_product_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_products
    ADD CONSTRAINT auth_products_product_code_key UNIQUE (product_code);


--
-- Name: auth_role_permissions auth_role_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_role_permissions
    ADD CONSTRAINT auth_role_permissions_pkey PRIMARY KEY (id);


--
-- Name: auth_roles auth_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_roles
    ADD CONSTRAINT auth_roles_pkey PRIMARY KEY (id);


--
-- Name: auth_roles auth_roles_role_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_roles
    ADD CONSTRAINT auth_roles_role_code_key UNIQUE (role_code);


--
-- Name: auth_user_oauth auth_user_oauth_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_user_oauth
    ADD CONSTRAINT auth_user_oauth_pkey PRIMARY KEY (id);


--
-- Name: auth_user_sessions auth_user_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_user_sessions
    ADD CONSTRAINT auth_user_sessions_pkey PRIMARY KEY (id);


--
-- Name: auth_user_sessions auth_user_sessions_session_token_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_user_sessions
    ADD CONSTRAINT auth_user_sessions_session_token_key UNIQUE (session_token);


--
-- Name: auth_user_tenants auth_user_tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_user_tenants
    ADD CONSTRAINT auth_user_tenants_pkey PRIMARY KEY (id);


--
-- Name: auth_users auth_users_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_users
    ADD CONSTRAINT auth_users_email_key UNIQUE (email);


--
-- Name: auth_users auth_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_users
    ADD CONSTRAINT auth_users_pkey PRIMARY KEY (id);


--
-- Name: daily_energy_refresh_log daily_energy_refresh_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_energy_refresh_log
    ADD CONSTRAINT daily_energy_refresh_log_pkey PRIMARY KEY (id);


--
-- Name: device_alerts device_alerts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_alerts
    ADD CONSTRAINT device_alerts_pkey PRIMARY KEY (id);


--
-- Name: device_files device_files_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_files
    ADD CONSTRAINT device_files_pkey PRIMARY KEY (id);


--
-- Name: device_mappings device_mappings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_mappings
    ADD CONSTRAINT device_mappings_pkey PRIMARY KEY (id);


--
-- Name: device_tags device_tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_tags
    ADD CONSTRAINT device_tags_pkey PRIMARY KEY (id);


--
-- Name: device_utility_mappings device_utility_mappings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_utility_mappings
    ADD CONSTRAINT device_utility_mappings_pkey PRIMARY KEY (id);


--
-- Name: devices devices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_pkey PRIMARY KEY (id);


--
-- Name: energy_costs energy_costs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.energy_costs
    ADD CONSTRAINT energy_costs_pkey PRIMARY KEY (id);


--
-- Name: enpi_calculations enpi_calculations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enpi_calculations
    ADD CONSTRAINT enpi_calculations_pkey PRIMARY KEY (id);


--
-- Name: file_storage file_storage_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_storage
    ADD CONSTRAINT file_storage_pkey PRIMARY KEY (id);


--
-- Name: hotspot_coordinates hotspot_coordinates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hotspot_coordinates
    ADD CONSTRAINT hotspot_coordinates_pkey PRIMARY KEY (id);


--
-- Name: operational_data operational_data_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_data
    ADD CONSTRAINT operational_data_pkey PRIMARY KEY (id);


--
-- Name: pme_quantity_mapping pme_quantity_mapping_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pme_quantity_mapping
    ADD CONSTRAINT pme_quantity_mapping_pkey PRIMARY KEY (pme_quantity_id);


--
-- Name: processed_gaps processed_gaps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processed_gaps
    ADD CONSTRAINT processed_gaps_pkey PRIMARY KEY (id);


--
-- Name: quantities quantities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quantities
    ADD CONSTRAINT quantities_pkey PRIMARY KEY (id);


--
-- Name: quantities quantities_quantity_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quantities
    ADD CONSTRAINT quantities_quantity_code_key UNIQUE (quantity_code);


--
-- Name: redistributed_intervals redistributed_intervals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.redistributed_intervals
    ADD CONSTRAINT redistributed_intervals_pkey PRIMARY KEY (id);


--
-- Name: sankey_levels sankey_levels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sankey_levels
    ADD CONSTRAINT sankey_levels_pkey PRIMARY KEY (id);


--
-- Name: sankey_links sankey_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sankey_links
    ADD CONSTRAINT sankey_links_pkey PRIMARY KEY (id);


--
-- Name: sankey_mappings sankey_mappings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sankey_mappings
    ADD CONSTRAINT sankey_mappings_pkey PRIMARY KEY (id);


--
-- Name: sankey_nodes sankey_nodes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sankey_nodes
    ADD CONSTRAINT sankey_nodes_pkey PRIMARY KEY (id);


--
-- Name: tenant_shift_periods tenant_shift_periods_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_shift_periods
    ADD CONSTRAINT tenant_shift_periods_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_pkey PRIMARY KEY (id);


--
-- Name: tenants tenants_tenant_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenants
    ADD CONSTRAINT tenants_tenant_code_key UNIQUE (tenant_code);


--
-- Name: tou_rate_periods tou_rate_periods_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tou_rate_periods
    ADD CONSTRAINT tou_rate_periods_pkey PRIMARY KEY (id);


--
-- Name: asset_tags unique_active_asset_tag; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_tags
    ADD CONSTRAINT unique_active_asset_tag UNIQUE (asset_id, tag_key, tag_value, effective_from);


--
-- Name: device_tags unique_active_device_tag; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_tags
    ADD CONSTRAINT unique_active_device_tag UNIQUE (device_id, tag_key, tag_value, effective_from);


--
-- Name: asset_connections unique_asset_connection; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_connections
    ADD CONSTRAINT unique_asset_connection UNIQUE (source_asset_id, target_asset_id, connection_type);


--
-- Name: asset_files unique_asset_file; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_files
    ADD CONSTRAINT unique_asset_file UNIQUE (asset_id, file_id);


--
-- Name: device_files unique_device_file; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_files
    ADD CONSTRAINT unique_device_file UNIQUE (device_id, file_id);


--
-- Name: device_utility_mappings unique_device_source_effective; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_utility_mappings
    ADD CONSTRAINT unique_device_source_effective UNIQUE (device_id, utility_source_id, effective_from);


--
-- Name: enpi_calculations unique_enpi_calculation; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enpi_calculations
    ADD CONSTRAINT unique_enpi_calculation UNIQUE (tenant_id, asset_id, calculation_date, enpi_type);


--
-- Name: device_mappings unique_external_mapping; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_mappings
    ADD CONSTRAINT unique_external_mapping UNIQUE (external_system, external_id);


--
-- Name: processed_gaps unique_gap; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processed_gaps
    ADD CONSTRAINT unique_gap UNIQUE (tenant_id, device_id, quantity_id, gap_start, gap_end);


--
-- Name: sankey_levels unique_mapping_level_order; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sankey_levels
    ADD CONSTRAINT unique_mapping_level_order UNIQUE (sankey_mapping_id, level_order);


--
-- Name: sankey_nodes unique_mapping_node_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sankey_nodes
    ADD CONSTRAINT unique_mapping_node_id UNIQUE (sankey_mapping_id, node_id);


--
-- Name: sankey_links unique_mapping_source_target; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sankey_links
    ADD CONSTRAINT unique_mapping_source_target UNIQUE (sankey_mapping_id, source_node_id, target_node_id);


--
-- Name: operational_data unique_operational_data; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_data
    ADD CONSTRAINT unique_operational_data UNIQUE (tenant_id, asset_id, data_date, metric_type);


--
-- Name: auth_user_oauth unique_provider_user; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_user_oauth
    ADD CONSTRAINT unique_provider_user UNIQUE (provider_id, provider_user_id);


--
-- Name: redistributed_intervals unique_redistributed_interval; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.redistributed_intervals
    ADD CONSTRAINT unique_redistributed_interval UNIQUE (gap_id, bucket);


--
-- Name: auth_role_permissions unique_role_permission; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_role_permissions
    ADD CONSTRAINT unique_role_permission UNIQUE (role_id, permission_id);


--
-- Name: assets unique_tenant_asset_code; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT unique_tenant_asset_code UNIQUE (tenant_id, asset_code);


--
-- Name: devices unique_tenant_device_code; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT unique_tenant_device_code UNIQUE (tenant_id, device_code);


--
-- Name: tou_rate_periods unique_tenant_period_time; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tou_rate_periods
    ADD CONSTRAINT unique_tenant_period_time UNIQUE (tenant_id, period_name, start_hour, effective_from);


--
-- Name: sankey_mappings unique_tenant_sankey_name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sankey_mappings
    ADD CONSTRAINT unique_tenant_sankey_name UNIQUE (tenant_id, name);


--
-- Name: tenant_shift_periods unique_tenant_shift_time; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_shift_periods
    ADD CONSTRAINT unique_tenant_shift_time UNIQUE (tenant_id, shift_name, start_hour, effective_from);


--
-- Name: utility_sources unique_tenant_source_code; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_sources
    ADD CONSTRAINT unique_tenant_source_code UNIQUE (tenant_id, source_code);


--
-- Name: utility_rates unique_tenant_source_rate_effective; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_rates
    ADD CONSTRAINT unique_tenant_source_rate_effective UNIQUE (tenant_id, utility_source_id, rate_code, effective_from);


--
-- Name: auth_user_oauth unique_user_provider; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_user_oauth
    ADD CONSTRAINT unique_user_provider UNIQUE (user_id, provider_id);


--
-- Name: auth_user_tenants unique_user_tenant_product; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_user_tenants
    ADD CONSTRAINT unique_user_tenant_product UNIQUE (user_id, tenant_id, product_id);


--
-- Name: utility_rates utility_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_rates
    ADD CONSTRAINT utility_rates_pkey PRIMARY KEY (id);


--
-- Name: utility_sources utility_sources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_sources
    ADD CONSTRAINT utility_sources_pkey PRIMARY KEY (id);


--
-- Name: _hyper_1_5611_chunk_idx_telemetry_device_quantity; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5611_chunk_idx_telemetry_device_quantity ON _timescaledb_internal._hyper_1_5611_chunk USING btree (device_id, quantity_id, "timestamp" DESC);


--
-- Name: _hyper_1_5611_chunk_idx_telemetry_device_quantity_timestamp; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5611_chunk_idx_telemetry_device_quantity_timestamp ON _timescaledb_internal._hyper_1_5611_chunk USING btree (device_id, quantity_id, "timestamp" DESC, tenant_id);


--
-- Name: _hyper_1_5611_chunk_idx_telemetry_device_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5611_chunk_idx_telemetry_device_time ON _timescaledb_internal._hyper_1_5611_chunk USING btree (device_id, "timestamp" DESC);


--
-- Name: _hyper_1_5611_chunk_idx_telemetry_quality_recent; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5611_chunk_idx_telemetry_quality_recent ON _timescaledb_internal._hyper_1_5611_chunk USING btree (quantity_id, device_id, quality, "timestamp");


--
-- Name: _hyper_1_5611_chunk_idx_telemetry_source; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5611_chunk_idx_telemetry_source ON _timescaledb_internal._hyper_1_5611_chunk USING btree (source_system);


--
-- Name: _hyper_1_5611_chunk_idx_telemetry_tenant_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5611_chunk_idx_telemetry_tenant_time ON _timescaledb_internal._hyper_1_5611_chunk USING btree (tenant_id, "timestamp" DESC);


--
-- Name: _hyper_1_5611_chunk_idx_telemetry_unique; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE UNIQUE INDEX _hyper_1_5611_chunk_idx_telemetry_unique ON _timescaledb_internal._hyper_1_5611_chunk USING btree ("timestamp", device_id, quantity_id);


--
-- Name: _hyper_1_5611_chunk_telemetry_data_timestamp_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5611_chunk_telemetry_data_timestamp_idx ON _timescaledb_internal._hyper_1_5611_chunk USING btree ("timestamp" DESC);


--
-- Name: _hyper_1_5612_chunk_idx_telemetry_device_quantity; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5612_chunk_idx_telemetry_device_quantity ON _timescaledb_internal._hyper_1_5612_chunk USING btree (device_id, quantity_id, "timestamp" DESC);


--
-- Name: _hyper_1_5612_chunk_idx_telemetry_device_quantity_timestamp; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5612_chunk_idx_telemetry_device_quantity_timestamp ON _timescaledb_internal._hyper_1_5612_chunk USING btree (device_id, quantity_id, "timestamp" DESC, tenant_id);


--
-- Name: _hyper_1_5612_chunk_idx_telemetry_device_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5612_chunk_idx_telemetry_device_time ON _timescaledb_internal._hyper_1_5612_chunk USING btree (device_id, "timestamp" DESC);


--
-- Name: _hyper_1_5612_chunk_idx_telemetry_quality_recent; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5612_chunk_idx_telemetry_quality_recent ON _timescaledb_internal._hyper_1_5612_chunk USING btree (quantity_id, device_id, quality, "timestamp");


--
-- Name: _hyper_1_5612_chunk_idx_telemetry_source; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5612_chunk_idx_telemetry_source ON _timescaledb_internal._hyper_1_5612_chunk USING btree (source_system);


--
-- Name: _hyper_1_5612_chunk_idx_telemetry_tenant_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5612_chunk_idx_telemetry_tenant_time ON _timescaledb_internal._hyper_1_5612_chunk USING btree (tenant_id, "timestamp" DESC);


--
-- Name: _hyper_1_5612_chunk_idx_telemetry_unique; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE UNIQUE INDEX _hyper_1_5612_chunk_idx_telemetry_unique ON _timescaledb_internal._hyper_1_5612_chunk USING btree ("timestamp", device_id, quantity_id);


--
-- Name: _hyper_1_5612_chunk_telemetry_data_timestamp_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5612_chunk_telemetry_data_timestamp_idx ON _timescaledb_internal._hyper_1_5612_chunk USING btree ("timestamp" DESC);


--
-- Name: _hyper_1_5613_chunk_idx_telemetry_device_quantity; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5613_chunk_idx_telemetry_device_quantity ON _timescaledb_internal._hyper_1_5613_chunk USING btree (device_id, quantity_id, "timestamp" DESC);


--
-- Name: _hyper_1_5613_chunk_idx_telemetry_device_quantity_timestamp; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5613_chunk_idx_telemetry_device_quantity_timestamp ON _timescaledb_internal._hyper_1_5613_chunk USING btree (device_id, quantity_id, "timestamp" DESC, tenant_id);


--
-- Name: _hyper_1_5613_chunk_idx_telemetry_device_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5613_chunk_idx_telemetry_device_time ON _timescaledb_internal._hyper_1_5613_chunk USING btree (device_id, "timestamp" DESC);


--
-- Name: _hyper_1_5613_chunk_idx_telemetry_quality_recent; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5613_chunk_idx_telemetry_quality_recent ON _timescaledb_internal._hyper_1_5613_chunk USING btree (quantity_id, device_id, quality, "timestamp");


--
-- Name: _hyper_1_5613_chunk_idx_telemetry_source; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5613_chunk_idx_telemetry_source ON _timescaledb_internal._hyper_1_5613_chunk USING btree (source_system);


--
-- Name: _hyper_1_5613_chunk_idx_telemetry_tenant_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5613_chunk_idx_telemetry_tenant_time ON _timescaledb_internal._hyper_1_5613_chunk USING btree (tenant_id, "timestamp" DESC);


--
-- Name: _hyper_1_5613_chunk_idx_telemetry_unique; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE UNIQUE INDEX _hyper_1_5613_chunk_idx_telemetry_unique ON _timescaledb_internal._hyper_1_5613_chunk USING btree ("timestamp", device_id, quantity_id);


--
-- Name: _hyper_1_5613_chunk_telemetry_data_timestamp_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5613_chunk_telemetry_data_timestamp_idx ON _timescaledb_internal._hyper_1_5613_chunk USING btree ("timestamp" DESC);


--
-- Name: _hyper_1_5614_chunk_idx_telemetry_device_quantity; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5614_chunk_idx_telemetry_device_quantity ON _timescaledb_internal._hyper_1_5614_chunk USING btree (device_id, quantity_id, "timestamp" DESC);


--
-- Name: _hyper_1_5614_chunk_idx_telemetry_device_quantity_timestamp; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5614_chunk_idx_telemetry_device_quantity_timestamp ON _timescaledb_internal._hyper_1_5614_chunk USING btree (device_id, quantity_id, "timestamp" DESC, tenant_id);


--
-- Name: _hyper_1_5614_chunk_idx_telemetry_device_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5614_chunk_idx_telemetry_device_time ON _timescaledb_internal._hyper_1_5614_chunk USING btree (device_id, "timestamp" DESC);


--
-- Name: _hyper_1_5614_chunk_idx_telemetry_quality_recent; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5614_chunk_idx_telemetry_quality_recent ON _timescaledb_internal._hyper_1_5614_chunk USING btree (quantity_id, device_id, quality, "timestamp");


--
-- Name: _hyper_1_5614_chunk_idx_telemetry_source; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5614_chunk_idx_telemetry_source ON _timescaledb_internal._hyper_1_5614_chunk USING btree (source_system);


--
-- Name: _hyper_1_5614_chunk_idx_telemetry_tenant_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5614_chunk_idx_telemetry_tenant_time ON _timescaledb_internal._hyper_1_5614_chunk USING btree (tenant_id, "timestamp" DESC);


--
-- Name: _hyper_1_5614_chunk_idx_telemetry_unique; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE UNIQUE INDEX _hyper_1_5614_chunk_idx_telemetry_unique ON _timescaledb_internal._hyper_1_5614_chunk USING btree ("timestamp", device_id, quantity_id);


--
-- Name: _hyper_1_5614_chunk_telemetry_data_timestamp_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5614_chunk_telemetry_data_timestamp_idx ON _timescaledb_internal._hyper_1_5614_chunk USING btree ("timestamp" DESC);


--
-- Name: _hyper_1_5615_chunk_idx_telemetry_device_quantity; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5615_chunk_idx_telemetry_device_quantity ON _timescaledb_internal._hyper_1_5615_chunk USING btree (device_id, quantity_id, "timestamp" DESC);


--
-- Name: _hyper_1_5615_chunk_idx_telemetry_device_quantity_timestamp; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5615_chunk_idx_telemetry_device_quantity_timestamp ON _timescaledb_internal._hyper_1_5615_chunk USING btree (device_id, quantity_id, "timestamp" DESC, tenant_id);


--
-- Name: _hyper_1_5615_chunk_idx_telemetry_device_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5615_chunk_idx_telemetry_device_time ON _timescaledb_internal._hyper_1_5615_chunk USING btree (device_id, "timestamp" DESC);


--
-- Name: _hyper_1_5615_chunk_idx_telemetry_quality_recent; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5615_chunk_idx_telemetry_quality_recent ON _timescaledb_internal._hyper_1_5615_chunk USING btree (quantity_id, device_id, quality, "timestamp");


--
-- Name: _hyper_1_5615_chunk_idx_telemetry_source; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5615_chunk_idx_telemetry_source ON _timescaledb_internal._hyper_1_5615_chunk USING btree (source_system);


--
-- Name: _hyper_1_5615_chunk_idx_telemetry_tenant_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5615_chunk_idx_telemetry_tenant_time ON _timescaledb_internal._hyper_1_5615_chunk USING btree (tenant_id, "timestamp" DESC);


--
-- Name: _hyper_1_5615_chunk_idx_telemetry_unique; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE UNIQUE INDEX _hyper_1_5615_chunk_idx_telemetry_unique ON _timescaledb_internal._hyper_1_5615_chunk USING btree ("timestamp", device_id, quantity_id);


--
-- Name: _hyper_1_5615_chunk_telemetry_data_timestamp_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5615_chunk_telemetry_data_timestamp_idx ON _timescaledb_internal._hyper_1_5615_chunk USING btree ("timestamp" DESC);


--
-- Name: _hyper_1_5616_chunk_idx_telemetry_device_quantity; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5616_chunk_idx_telemetry_device_quantity ON _timescaledb_internal._hyper_1_5616_chunk USING btree (device_id, quantity_id, "timestamp" DESC);


--
-- Name: _hyper_1_5616_chunk_idx_telemetry_device_quantity_timestamp; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5616_chunk_idx_telemetry_device_quantity_timestamp ON _timescaledb_internal._hyper_1_5616_chunk USING btree (device_id, quantity_id, "timestamp" DESC, tenant_id);


--
-- Name: _hyper_1_5616_chunk_idx_telemetry_device_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5616_chunk_idx_telemetry_device_time ON _timescaledb_internal._hyper_1_5616_chunk USING btree (device_id, "timestamp" DESC);


--
-- Name: _hyper_1_5616_chunk_idx_telemetry_quality_recent; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5616_chunk_idx_telemetry_quality_recent ON _timescaledb_internal._hyper_1_5616_chunk USING btree (quantity_id, device_id, quality, "timestamp");


--
-- Name: _hyper_1_5616_chunk_idx_telemetry_source; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5616_chunk_idx_telemetry_source ON _timescaledb_internal._hyper_1_5616_chunk USING btree (source_system);


--
-- Name: _hyper_1_5616_chunk_idx_telemetry_tenant_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5616_chunk_idx_telemetry_tenant_time ON _timescaledb_internal._hyper_1_5616_chunk USING btree (tenant_id, "timestamp" DESC);


--
-- Name: _hyper_1_5616_chunk_idx_telemetry_unique; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE UNIQUE INDEX _hyper_1_5616_chunk_idx_telemetry_unique ON _timescaledb_internal._hyper_1_5616_chunk USING btree ("timestamp", device_id, quantity_id);


--
-- Name: _hyper_1_5616_chunk_telemetry_data_timestamp_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5616_chunk_telemetry_data_timestamp_idx ON _timescaledb_internal._hyper_1_5616_chunk USING btree ("timestamp" DESC);


--
-- Name: _hyper_1_5618_chunk_idx_telemetry_device_quantity; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5618_chunk_idx_telemetry_device_quantity ON _timescaledb_internal._hyper_1_5618_chunk USING btree (device_id, quantity_id, "timestamp" DESC);


--
-- Name: _hyper_1_5618_chunk_idx_telemetry_device_quantity_timestamp; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5618_chunk_idx_telemetry_device_quantity_timestamp ON _timescaledb_internal._hyper_1_5618_chunk USING btree (device_id, quantity_id, "timestamp" DESC, tenant_id);


--
-- Name: _hyper_1_5618_chunk_idx_telemetry_device_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5618_chunk_idx_telemetry_device_time ON _timescaledb_internal._hyper_1_5618_chunk USING btree (device_id, "timestamp" DESC);


--
-- Name: _hyper_1_5618_chunk_idx_telemetry_quality_recent; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5618_chunk_idx_telemetry_quality_recent ON _timescaledb_internal._hyper_1_5618_chunk USING btree (quantity_id, device_id, quality, "timestamp");


--
-- Name: _hyper_1_5618_chunk_idx_telemetry_source; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5618_chunk_idx_telemetry_source ON _timescaledb_internal._hyper_1_5618_chunk USING btree (source_system);


--
-- Name: _hyper_1_5618_chunk_idx_telemetry_tenant_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5618_chunk_idx_telemetry_tenant_time ON _timescaledb_internal._hyper_1_5618_chunk USING btree (tenant_id, "timestamp" DESC);


--
-- Name: _hyper_1_5618_chunk_idx_telemetry_unique; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE UNIQUE INDEX _hyper_1_5618_chunk_idx_telemetry_unique ON _timescaledb_internal._hyper_1_5618_chunk USING btree ("timestamp", device_id, quantity_id);


--
-- Name: _hyper_1_5618_chunk_telemetry_data_timestamp_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5618_chunk_telemetry_data_timestamp_idx ON _timescaledb_internal._hyper_1_5618_chunk USING btree ("timestamp" DESC);


--
-- Name: _hyper_1_5619_chunk_idx_telemetry_device_quantity; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5619_chunk_idx_telemetry_device_quantity ON _timescaledb_internal._hyper_1_5619_chunk USING btree (device_id, quantity_id, "timestamp" DESC);


--
-- Name: _hyper_1_5619_chunk_idx_telemetry_device_quantity_timestamp; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5619_chunk_idx_telemetry_device_quantity_timestamp ON _timescaledb_internal._hyper_1_5619_chunk USING btree (device_id, quantity_id, "timestamp" DESC, tenant_id);


--
-- Name: _hyper_1_5619_chunk_idx_telemetry_device_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5619_chunk_idx_telemetry_device_time ON _timescaledb_internal._hyper_1_5619_chunk USING btree (device_id, "timestamp" DESC);


--
-- Name: _hyper_1_5619_chunk_idx_telemetry_quality_recent; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5619_chunk_idx_telemetry_quality_recent ON _timescaledb_internal._hyper_1_5619_chunk USING btree (quantity_id, device_id, quality, "timestamp");


--
-- Name: _hyper_1_5619_chunk_idx_telemetry_source; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5619_chunk_idx_telemetry_source ON _timescaledb_internal._hyper_1_5619_chunk USING btree (source_system);


--
-- Name: _hyper_1_5619_chunk_idx_telemetry_tenant_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5619_chunk_idx_telemetry_tenant_time ON _timescaledb_internal._hyper_1_5619_chunk USING btree (tenant_id, "timestamp" DESC);


--
-- Name: _hyper_1_5619_chunk_idx_telemetry_unique; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE UNIQUE INDEX _hyper_1_5619_chunk_idx_telemetry_unique ON _timescaledb_internal._hyper_1_5619_chunk USING btree ("timestamp", device_id, quantity_id);


--
-- Name: _hyper_1_5619_chunk_telemetry_data_timestamp_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5619_chunk_telemetry_data_timestamp_idx ON _timescaledb_internal._hyper_1_5619_chunk USING btree ("timestamp" DESC);


--
-- Name: _hyper_1_5620_chunk_idx_telemetry_device_quantity; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5620_chunk_idx_telemetry_device_quantity ON _timescaledb_internal._hyper_1_5620_chunk USING btree (device_id, quantity_id, "timestamp" DESC);


--
-- Name: _hyper_1_5620_chunk_idx_telemetry_device_quantity_timestamp; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5620_chunk_idx_telemetry_device_quantity_timestamp ON _timescaledb_internal._hyper_1_5620_chunk USING btree (device_id, quantity_id, "timestamp" DESC, tenant_id);


--
-- Name: _hyper_1_5620_chunk_idx_telemetry_device_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5620_chunk_idx_telemetry_device_time ON _timescaledb_internal._hyper_1_5620_chunk USING btree (device_id, "timestamp" DESC);


--
-- Name: _hyper_1_5620_chunk_idx_telemetry_quality_recent; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5620_chunk_idx_telemetry_quality_recent ON _timescaledb_internal._hyper_1_5620_chunk USING btree (quantity_id, device_id, quality, "timestamp");


--
-- Name: _hyper_1_5620_chunk_idx_telemetry_source; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5620_chunk_idx_telemetry_source ON _timescaledb_internal._hyper_1_5620_chunk USING btree (source_system);


--
-- Name: _hyper_1_5620_chunk_idx_telemetry_tenant_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5620_chunk_idx_telemetry_tenant_time ON _timescaledb_internal._hyper_1_5620_chunk USING btree (tenant_id, "timestamp" DESC);


--
-- Name: _hyper_1_5620_chunk_idx_telemetry_unique; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE UNIQUE INDEX _hyper_1_5620_chunk_idx_telemetry_unique ON _timescaledb_internal._hyper_1_5620_chunk USING btree ("timestamp", device_id, quantity_id);


--
-- Name: _hyper_1_5620_chunk_telemetry_data_timestamp_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5620_chunk_telemetry_data_timestamp_idx ON _timescaledb_internal._hyper_1_5620_chunk USING btree ("timestamp" DESC);


--
-- Name: _hyper_1_5621_chunk_idx_telemetry_device_quantity; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5621_chunk_idx_telemetry_device_quantity ON _timescaledb_internal._hyper_1_5621_chunk USING btree (device_id, quantity_id, "timestamp" DESC);


--
-- Name: _hyper_1_5621_chunk_idx_telemetry_device_quantity_timestamp; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5621_chunk_idx_telemetry_device_quantity_timestamp ON _timescaledb_internal._hyper_1_5621_chunk USING btree (device_id, quantity_id, "timestamp" DESC, tenant_id);


--
-- Name: _hyper_1_5621_chunk_idx_telemetry_device_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5621_chunk_idx_telemetry_device_time ON _timescaledb_internal._hyper_1_5621_chunk USING btree (device_id, "timestamp" DESC);


--
-- Name: _hyper_1_5621_chunk_idx_telemetry_quality_recent; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5621_chunk_idx_telemetry_quality_recent ON _timescaledb_internal._hyper_1_5621_chunk USING btree (quantity_id, device_id, quality, "timestamp");


--
-- Name: _hyper_1_5621_chunk_idx_telemetry_source; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5621_chunk_idx_telemetry_source ON _timescaledb_internal._hyper_1_5621_chunk USING btree (source_system);


--
-- Name: _hyper_1_5621_chunk_idx_telemetry_tenant_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5621_chunk_idx_telemetry_tenant_time ON _timescaledb_internal._hyper_1_5621_chunk USING btree (tenant_id, "timestamp" DESC);


--
-- Name: _hyper_1_5621_chunk_idx_telemetry_unique; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE UNIQUE INDEX _hyper_1_5621_chunk_idx_telemetry_unique ON _timescaledb_internal._hyper_1_5621_chunk USING btree ("timestamp", device_id, quantity_id);


--
-- Name: _hyper_1_5621_chunk_telemetry_data_timestamp_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5621_chunk_telemetry_data_timestamp_idx ON _timescaledb_internal._hyper_1_5621_chunk USING btree ("timestamp" DESC);


--
-- Name: _hyper_1_5622_chunk_idx_telemetry_device_quantity; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5622_chunk_idx_telemetry_device_quantity ON _timescaledb_internal._hyper_1_5622_chunk USING btree (device_id, quantity_id, "timestamp" DESC);


--
-- Name: _hyper_1_5622_chunk_idx_telemetry_device_quantity_timestamp; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5622_chunk_idx_telemetry_device_quantity_timestamp ON _timescaledb_internal._hyper_1_5622_chunk USING btree (device_id, quantity_id, "timestamp" DESC, tenant_id);


--
-- Name: _hyper_1_5622_chunk_idx_telemetry_device_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5622_chunk_idx_telemetry_device_time ON _timescaledb_internal._hyper_1_5622_chunk USING btree (device_id, "timestamp" DESC);


--
-- Name: _hyper_1_5622_chunk_idx_telemetry_quality_recent; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5622_chunk_idx_telemetry_quality_recent ON _timescaledb_internal._hyper_1_5622_chunk USING btree (quantity_id, device_id, quality, "timestamp");


--
-- Name: _hyper_1_5622_chunk_idx_telemetry_source; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5622_chunk_idx_telemetry_source ON _timescaledb_internal._hyper_1_5622_chunk USING btree (source_system);


--
-- Name: _hyper_1_5622_chunk_idx_telemetry_tenant_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5622_chunk_idx_telemetry_tenant_time ON _timescaledb_internal._hyper_1_5622_chunk USING btree (tenant_id, "timestamp" DESC);


--
-- Name: _hyper_1_5622_chunk_idx_telemetry_unique; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE UNIQUE INDEX _hyper_1_5622_chunk_idx_telemetry_unique ON _timescaledb_internal._hyper_1_5622_chunk USING btree ("timestamp", device_id, quantity_id);


--
-- Name: _hyper_1_5622_chunk_telemetry_data_timestamp_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5622_chunk_telemetry_data_timestamp_idx ON _timescaledb_internal._hyper_1_5622_chunk USING btree ("timestamp" DESC);


--
-- Name: _hyper_1_5623_chunk_idx_telemetry_device_quantity; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5623_chunk_idx_telemetry_device_quantity ON _timescaledb_internal._hyper_1_5623_chunk USING btree (device_id, quantity_id, "timestamp" DESC);


--
-- Name: _hyper_1_5623_chunk_idx_telemetry_device_quantity_timestamp; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5623_chunk_idx_telemetry_device_quantity_timestamp ON _timescaledb_internal._hyper_1_5623_chunk USING btree (device_id, quantity_id, "timestamp" DESC, tenant_id);


--
-- Name: _hyper_1_5623_chunk_idx_telemetry_device_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5623_chunk_idx_telemetry_device_time ON _timescaledb_internal._hyper_1_5623_chunk USING btree (device_id, "timestamp" DESC);


--
-- Name: _hyper_1_5623_chunk_idx_telemetry_quality_recent; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5623_chunk_idx_telemetry_quality_recent ON _timescaledb_internal._hyper_1_5623_chunk USING btree (quantity_id, device_id, quality, "timestamp");


--
-- Name: _hyper_1_5623_chunk_idx_telemetry_source; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5623_chunk_idx_telemetry_source ON _timescaledb_internal._hyper_1_5623_chunk USING btree (source_system);


--
-- Name: _hyper_1_5623_chunk_idx_telemetry_tenant_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5623_chunk_idx_telemetry_tenant_time ON _timescaledb_internal._hyper_1_5623_chunk USING btree (tenant_id, "timestamp" DESC);


--
-- Name: _hyper_1_5623_chunk_idx_telemetry_unique; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE UNIQUE INDEX _hyper_1_5623_chunk_idx_telemetry_unique ON _timescaledb_internal._hyper_1_5623_chunk USING btree ("timestamp", device_id, quantity_id);


--
-- Name: _hyper_1_5623_chunk_telemetry_data_timestamp_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5623_chunk_telemetry_data_timestamp_idx ON _timescaledb_internal._hyper_1_5623_chunk USING btree ("timestamp" DESC);


--
-- Name: _hyper_1_5624_chunk_idx_telemetry_device_quantity; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5624_chunk_idx_telemetry_device_quantity ON _timescaledb_internal._hyper_1_5624_chunk USING btree (device_id, quantity_id, "timestamp" DESC);


--
-- Name: _hyper_1_5624_chunk_idx_telemetry_device_quantity_timestamp; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5624_chunk_idx_telemetry_device_quantity_timestamp ON _timescaledb_internal._hyper_1_5624_chunk USING btree (device_id, quantity_id, "timestamp" DESC, tenant_id);


--
-- Name: _hyper_1_5624_chunk_idx_telemetry_device_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5624_chunk_idx_telemetry_device_time ON _timescaledb_internal._hyper_1_5624_chunk USING btree (device_id, "timestamp" DESC);


--
-- Name: _hyper_1_5624_chunk_idx_telemetry_quality_recent; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5624_chunk_idx_telemetry_quality_recent ON _timescaledb_internal._hyper_1_5624_chunk USING btree (quantity_id, device_id, quality, "timestamp");


--
-- Name: _hyper_1_5624_chunk_idx_telemetry_source; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5624_chunk_idx_telemetry_source ON _timescaledb_internal._hyper_1_5624_chunk USING btree (source_system);


--
-- Name: _hyper_1_5624_chunk_idx_telemetry_tenant_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5624_chunk_idx_telemetry_tenant_time ON _timescaledb_internal._hyper_1_5624_chunk USING btree (tenant_id, "timestamp" DESC);


--
-- Name: _hyper_1_5624_chunk_idx_telemetry_unique; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE UNIQUE INDEX _hyper_1_5624_chunk_idx_telemetry_unique ON _timescaledb_internal._hyper_1_5624_chunk USING btree ("timestamp", device_id, quantity_id);


--
-- Name: _hyper_1_5624_chunk_telemetry_data_timestamp_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5624_chunk_telemetry_data_timestamp_idx ON _timescaledb_internal._hyper_1_5624_chunk USING btree ("timestamp" DESC);


--
-- Name: _hyper_1_5625_chunk_idx_telemetry_device_quantity; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5625_chunk_idx_telemetry_device_quantity ON _timescaledb_internal._hyper_1_5625_chunk USING btree (device_id, quantity_id, "timestamp" DESC);


--
-- Name: _hyper_1_5625_chunk_idx_telemetry_device_quantity_timestamp; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5625_chunk_idx_telemetry_device_quantity_timestamp ON _timescaledb_internal._hyper_1_5625_chunk USING btree (device_id, quantity_id, "timestamp" DESC, tenant_id);


--
-- Name: _hyper_1_5625_chunk_idx_telemetry_device_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5625_chunk_idx_telemetry_device_time ON _timescaledb_internal._hyper_1_5625_chunk USING btree (device_id, "timestamp" DESC);


--
-- Name: _hyper_1_5625_chunk_idx_telemetry_quality_recent; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5625_chunk_idx_telemetry_quality_recent ON _timescaledb_internal._hyper_1_5625_chunk USING btree (quantity_id, device_id, quality, "timestamp");


--
-- Name: _hyper_1_5625_chunk_idx_telemetry_source; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5625_chunk_idx_telemetry_source ON _timescaledb_internal._hyper_1_5625_chunk USING btree (source_system);


--
-- Name: _hyper_1_5625_chunk_idx_telemetry_tenant_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5625_chunk_idx_telemetry_tenant_time ON _timescaledb_internal._hyper_1_5625_chunk USING btree (tenant_id, "timestamp" DESC);


--
-- Name: _hyper_1_5625_chunk_idx_telemetry_unique; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE UNIQUE INDEX _hyper_1_5625_chunk_idx_telemetry_unique ON _timescaledb_internal._hyper_1_5625_chunk USING btree ("timestamp", device_id, quantity_id);


--
-- Name: _hyper_1_5625_chunk_telemetry_data_timestamp_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5625_chunk_telemetry_data_timestamp_idx ON _timescaledb_internal._hyper_1_5625_chunk USING btree ("timestamp" DESC);


--
-- Name: _hyper_1_5626_chunk_idx_telemetry_device_quantity; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5626_chunk_idx_telemetry_device_quantity ON _timescaledb_internal._hyper_1_5626_chunk USING btree (device_id, quantity_id, "timestamp" DESC);


--
-- Name: _hyper_1_5626_chunk_idx_telemetry_device_quantity_timestamp; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5626_chunk_idx_telemetry_device_quantity_timestamp ON _timescaledb_internal._hyper_1_5626_chunk USING btree (device_id, quantity_id, "timestamp" DESC, tenant_id);


--
-- Name: _hyper_1_5626_chunk_idx_telemetry_device_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5626_chunk_idx_telemetry_device_time ON _timescaledb_internal._hyper_1_5626_chunk USING btree (device_id, "timestamp" DESC);


--
-- Name: _hyper_1_5626_chunk_idx_telemetry_quality_recent; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5626_chunk_idx_telemetry_quality_recent ON _timescaledb_internal._hyper_1_5626_chunk USING btree (quantity_id, device_id, quality, "timestamp");


--
-- Name: _hyper_1_5626_chunk_idx_telemetry_source; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5626_chunk_idx_telemetry_source ON _timescaledb_internal._hyper_1_5626_chunk USING btree (source_system);


--
-- Name: _hyper_1_5626_chunk_idx_telemetry_tenant_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5626_chunk_idx_telemetry_tenant_time ON _timescaledb_internal._hyper_1_5626_chunk USING btree (tenant_id, "timestamp" DESC);


--
-- Name: _hyper_1_5626_chunk_idx_telemetry_unique; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE UNIQUE INDEX _hyper_1_5626_chunk_idx_telemetry_unique ON _timescaledb_internal._hyper_1_5626_chunk USING btree ("timestamp", device_id, quantity_id);


--
-- Name: _hyper_1_5626_chunk_telemetry_data_timestamp_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_1_5626_chunk_telemetry_data_timestamp_idx ON _timescaledb_internal._hyper_1_5626_chunk USING btree ("timestamp" DESC);


--
-- Name: _hyper_6_1_chunk_audit_logs_created_at_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_6_1_chunk_audit_logs_created_at_idx ON _timescaledb_internal._hyper_6_1_chunk USING btree (created_at DESC);


--
-- Name: _hyper_6_1_chunk_idx_audit_logs_action_type; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_6_1_chunk_idx_audit_logs_action_type ON _timescaledb_internal._hyper_6_1_chunk USING btree (action_type);


--
-- Name: _hyper_6_1_chunk_idx_audit_logs_resource; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_6_1_chunk_idx_audit_logs_resource ON _timescaledb_internal._hyper_6_1_chunk USING btree (resource_type, resource_id);


--
-- Name: _hyper_6_1_chunk_idx_audit_logs_tenant_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_6_1_chunk_idx_audit_logs_tenant_time ON _timescaledb_internal._hyper_6_1_chunk USING btree (tenant_id, created_at DESC);


--
-- Name: _hyper_6_1_chunk_idx_audit_logs_user_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_6_1_chunk_idx_audit_logs_user_time ON _timescaledb_internal._hyper_6_1_chunk USING btree (user_id, created_at DESC);


--
-- Name: _hyper_6_1_chunk_idx_audit_logs_user_type_recent; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_6_1_chunk_idx_audit_logs_user_type_recent ON _timescaledb_internal._hyper_6_1_chunk USING btree (user_id, action_type, created_at DESC);


--
-- Name: _hyper_6_305_chunk_audit_logs_created_at_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_6_305_chunk_audit_logs_created_at_idx ON _timescaledb_internal._hyper_6_305_chunk USING btree (created_at DESC);


--
-- Name: _hyper_6_305_chunk_idx_audit_logs_action_type; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_6_305_chunk_idx_audit_logs_action_type ON _timescaledb_internal._hyper_6_305_chunk USING btree (action_type);


--
-- Name: _hyper_6_305_chunk_idx_audit_logs_resource; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_6_305_chunk_idx_audit_logs_resource ON _timescaledb_internal._hyper_6_305_chunk USING btree (resource_type, resource_id);


--
-- Name: _hyper_6_305_chunk_idx_audit_logs_tenant_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_6_305_chunk_idx_audit_logs_tenant_time ON _timescaledb_internal._hyper_6_305_chunk USING btree (tenant_id, created_at DESC);


--
-- Name: _hyper_6_305_chunk_idx_audit_logs_user_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_6_305_chunk_idx_audit_logs_user_time ON _timescaledb_internal._hyper_6_305_chunk USING btree (user_id, created_at DESC);


--
-- Name: _hyper_6_305_chunk_idx_audit_logs_user_type_recent; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_6_305_chunk_idx_audit_logs_user_type_recent ON _timescaledb_internal._hyper_6_305_chunk USING btree (user_id, action_type, created_at DESC);


--
-- Name: _hyper_6_5559_chunk_audit_logs_created_at_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_6_5559_chunk_audit_logs_created_at_idx ON _timescaledb_internal._hyper_6_5559_chunk USING btree (created_at DESC);


--
-- Name: _hyper_6_5559_chunk_idx_audit_logs_action_type; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_6_5559_chunk_idx_audit_logs_action_type ON _timescaledb_internal._hyper_6_5559_chunk USING btree (action_type);


--
-- Name: _hyper_6_5559_chunk_idx_audit_logs_resource; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_6_5559_chunk_idx_audit_logs_resource ON _timescaledb_internal._hyper_6_5559_chunk USING btree (resource_type, resource_id);


--
-- Name: _hyper_6_5559_chunk_idx_audit_logs_tenant_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_6_5559_chunk_idx_audit_logs_tenant_time ON _timescaledb_internal._hyper_6_5559_chunk USING btree (tenant_id, created_at DESC);


--
-- Name: _hyper_6_5559_chunk_idx_audit_logs_user_time; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_6_5559_chunk_idx_audit_logs_user_time ON _timescaledb_internal._hyper_6_5559_chunk USING btree (user_id, created_at DESC);


--
-- Name: _hyper_6_5559_chunk_idx_audit_logs_user_type_recent; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_6_5559_chunk_idx_audit_logs_user_type_recent ON _timescaledb_internal._hyper_6_5559_chunk USING btree (user_id, action_type, created_at DESC);


--
-- Name: _hyper_7_323_chunk__materialized_hypertable_7_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_323_chunk__materialized_hypertable_7_bucket_idx ON _timescaledb_internal._hyper_7_323_chunk USING btree (bucket DESC);


--
-- Name: _hyper_7_323_chunk__materialized_hypertable_7_device_id_bucket_; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_323_chunk__materialized_hypertable_7_device_id_bucket_ ON _timescaledb_internal._hyper_7_323_chunk USING btree (device_id, bucket DESC);


--
-- Name: _hyper_7_323_chunk__materialized_hypertable_7_quantity_id_bucke; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_323_chunk__materialized_hypertable_7_quantity_id_bucke ON _timescaledb_internal._hyper_7_323_chunk USING btree (quantity_id, bucket DESC);


--
-- Name: _hyper_7_323_chunk__materialized_hypertable_7_source_system_buc; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_323_chunk__materialized_hypertable_7_source_system_buc ON _timescaledb_internal._hyper_7_323_chunk USING btree (source_system, bucket DESC);


--
-- Name: _hyper_7_323_chunk__materialized_hypertable_7_tenant_id_bucket_; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_323_chunk__materialized_hypertable_7_tenant_id_bucket_ ON _timescaledb_internal._hyper_7_323_chunk USING btree (tenant_id, bucket DESC);


--
-- Name: _hyper_7_324_chunk__materialized_hypertable_7_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_324_chunk__materialized_hypertable_7_bucket_idx ON _timescaledb_internal._hyper_7_324_chunk USING btree (bucket DESC);


--
-- Name: _hyper_7_324_chunk__materialized_hypertable_7_device_id_bucket_; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_324_chunk__materialized_hypertable_7_device_id_bucket_ ON _timescaledb_internal._hyper_7_324_chunk USING btree (device_id, bucket DESC);


--
-- Name: _hyper_7_324_chunk__materialized_hypertable_7_quantity_id_bucke; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_324_chunk__materialized_hypertable_7_quantity_id_bucke ON _timescaledb_internal._hyper_7_324_chunk USING btree (quantity_id, bucket DESC);


--
-- Name: _hyper_7_324_chunk__materialized_hypertable_7_source_system_buc; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_324_chunk__materialized_hypertable_7_source_system_buc ON _timescaledb_internal._hyper_7_324_chunk USING btree (source_system, bucket DESC);


--
-- Name: _hyper_7_324_chunk__materialized_hypertable_7_tenant_id_bucket_; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_324_chunk__materialized_hypertable_7_tenant_id_bucket_ ON _timescaledb_internal._hyper_7_324_chunk USING btree (tenant_id, bucket DESC);


--
-- Name: _hyper_7_5550_chunk__materialized_hypertable_7_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5550_chunk__materialized_hypertable_7_bucket_idx ON _timescaledb_internal._hyper_7_5550_chunk USING btree (bucket DESC);


--
-- Name: _hyper_7_5550_chunk__materialized_hypertable_7_device_id_bucket; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5550_chunk__materialized_hypertable_7_device_id_bucket ON _timescaledb_internal._hyper_7_5550_chunk USING btree (device_id, bucket DESC);


--
-- Name: _hyper_7_5550_chunk__materialized_hypertable_7_quantity_id_buck; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5550_chunk__materialized_hypertable_7_quantity_id_buck ON _timescaledb_internal._hyper_7_5550_chunk USING btree (quantity_id, bucket DESC);


--
-- Name: _hyper_7_5550_chunk__materialized_hypertable_7_source_system_bu; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5550_chunk__materialized_hypertable_7_source_system_bu ON _timescaledb_internal._hyper_7_5550_chunk USING btree (source_system, bucket DESC);


--
-- Name: _hyper_7_5550_chunk__materialized_hypertable_7_tenant_id_bucket; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5550_chunk__materialized_hypertable_7_tenant_id_bucket ON _timescaledb_internal._hyper_7_5550_chunk USING btree (tenant_id, bucket DESC);


--
-- Name: _hyper_7_5562_chunk__materialized_hypertable_7_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5562_chunk__materialized_hypertable_7_bucket_idx ON _timescaledb_internal._hyper_7_5562_chunk USING btree (bucket DESC);


--
-- Name: _hyper_7_5562_chunk__materialized_hypertable_7_device_id_bucket; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5562_chunk__materialized_hypertable_7_device_id_bucket ON _timescaledb_internal._hyper_7_5562_chunk USING btree (device_id, bucket DESC);


--
-- Name: _hyper_7_5562_chunk__materialized_hypertable_7_quantity_id_buck; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5562_chunk__materialized_hypertable_7_quantity_id_buck ON _timescaledb_internal._hyper_7_5562_chunk USING btree (quantity_id, bucket DESC);


--
-- Name: _hyper_7_5562_chunk__materialized_hypertable_7_source_system_bu; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5562_chunk__materialized_hypertable_7_source_system_bu ON _timescaledb_internal._hyper_7_5562_chunk USING btree (source_system, bucket DESC);


--
-- Name: _hyper_7_5562_chunk__materialized_hypertable_7_tenant_id_bucket; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5562_chunk__materialized_hypertable_7_tenant_id_bucket ON _timescaledb_internal._hyper_7_5562_chunk USING btree (tenant_id, bucket DESC);


--
-- Name: _hyper_7_5573_chunk__materialized_hypertable_7_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5573_chunk__materialized_hypertable_7_bucket_idx ON _timescaledb_internal._hyper_7_5573_chunk USING btree (bucket DESC);


--
-- Name: _hyper_7_5573_chunk__materialized_hypertable_7_device_id_bucket; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5573_chunk__materialized_hypertable_7_device_id_bucket ON _timescaledb_internal._hyper_7_5573_chunk USING btree (device_id, bucket DESC);


--
-- Name: _hyper_7_5573_chunk__materialized_hypertable_7_quantity_id_buck; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5573_chunk__materialized_hypertable_7_quantity_id_buck ON _timescaledb_internal._hyper_7_5573_chunk USING btree (quantity_id, bucket DESC);


--
-- Name: _hyper_7_5573_chunk__materialized_hypertable_7_source_system_bu; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5573_chunk__materialized_hypertable_7_source_system_bu ON _timescaledb_internal._hyper_7_5573_chunk USING btree (source_system, bucket DESC);


--
-- Name: _hyper_7_5573_chunk__materialized_hypertable_7_tenant_id_bucket; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5573_chunk__materialized_hypertable_7_tenant_id_bucket ON _timescaledb_internal._hyper_7_5573_chunk USING btree (tenant_id, bucket DESC);


--
-- Name: _hyper_7_5584_chunk__materialized_hypertable_7_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5584_chunk__materialized_hypertable_7_bucket_idx ON _timescaledb_internal._hyper_7_5584_chunk USING btree (bucket DESC);


--
-- Name: _hyper_7_5584_chunk__materialized_hypertable_7_device_id_bucket; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5584_chunk__materialized_hypertable_7_device_id_bucket ON _timescaledb_internal._hyper_7_5584_chunk USING btree (device_id, bucket DESC);


--
-- Name: _hyper_7_5584_chunk__materialized_hypertable_7_quantity_id_buck; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5584_chunk__materialized_hypertable_7_quantity_id_buck ON _timescaledb_internal._hyper_7_5584_chunk USING btree (quantity_id, bucket DESC);


--
-- Name: _hyper_7_5584_chunk__materialized_hypertable_7_source_system_bu; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5584_chunk__materialized_hypertable_7_source_system_bu ON _timescaledb_internal._hyper_7_5584_chunk USING btree (source_system, bucket DESC);


--
-- Name: _hyper_7_5584_chunk__materialized_hypertable_7_tenant_id_bucket; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5584_chunk__materialized_hypertable_7_tenant_id_bucket ON _timescaledb_internal._hyper_7_5584_chunk USING btree (tenant_id, bucket DESC);


--
-- Name: _hyper_7_5595_chunk__materialized_hypertable_7_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5595_chunk__materialized_hypertable_7_bucket_idx ON _timescaledb_internal._hyper_7_5595_chunk USING btree (bucket DESC);


--
-- Name: _hyper_7_5595_chunk__materialized_hypertable_7_device_id_bucket; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5595_chunk__materialized_hypertable_7_device_id_bucket ON _timescaledb_internal._hyper_7_5595_chunk USING btree (device_id, bucket DESC);


--
-- Name: _hyper_7_5595_chunk__materialized_hypertable_7_quantity_id_buck; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5595_chunk__materialized_hypertable_7_quantity_id_buck ON _timescaledb_internal._hyper_7_5595_chunk USING btree (quantity_id, bucket DESC);


--
-- Name: _hyper_7_5595_chunk__materialized_hypertable_7_source_system_bu; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5595_chunk__materialized_hypertable_7_source_system_bu ON _timescaledb_internal._hyper_7_5595_chunk USING btree (source_system, bucket DESC);


--
-- Name: _hyper_7_5595_chunk__materialized_hypertable_7_tenant_id_bucket; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5595_chunk__materialized_hypertable_7_tenant_id_bucket ON _timescaledb_internal._hyper_7_5595_chunk USING btree (tenant_id, bucket DESC);


--
-- Name: _hyper_7_5606_chunk__materialized_hypertable_7_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5606_chunk__materialized_hypertable_7_bucket_idx ON _timescaledb_internal._hyper_7_5606_chunk USING btree (bucket DESC);


--
-- Name: _hyper_7_5606_chunk__materialized_hypertable_7_device_id_bucket; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5606_chunk__materialized_hypertable_7_device_id_bucket ON _timescaledb_internal._hyper_7_5606_chunk USING btree (device_id, bucket DESC);


--
-- Name: _hyper_7_5606_chunk__materialized_hypertable_7_quantity_id_buck; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5606_chunk__materialized_hypertable_7_quantity_id_buck ON _timescaledb_internal._hyper_7_5606_chunk USING btree (quantity_id, bucket DESC);


--
-- Name: _hyper_7_5606_chunk__materialized_hypertable_7_source_system_bu; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5606_chunk__materialized_hypertable_7_source_system_bu ON _timescaledb_internal._hyper_7_5606_chunk USING btree (source_system, bucket DESC);


--
-- Name: _hyper_7_5606_chunk__materialized_hypertable_7_tenant_id_bucket; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5606_chunk__materialized_hypertable_7_tenant_id_bucket ON _timescaledb_internal._hyper_7_5606_chunk USING btree (tenant_id, bucket DESC);


--
-- Name: _hyper_7_5617_chunk__materialized_hypertable_7_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5617_chunk__materialized_hypertable_7_bucket_idx ON _timescaledb_internal._hyper_7_5617_chunk USING btree (bucket DESC);


--
-- Name: _hyper_7_5617_chunk__materialized_hypertable_7_device_id_bucket; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5617_chunk__materialized_hypertable_7_device_id_bucket ON _timescaledb_internal._hyper_7_5617_chunk USING btree (device_id, bucket DESC);


--
-- Name: _hyper_7_5617_chunk__materialized_hypertable_7_quantity_id_buck; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5617_chunk__materialized_hypertable_7_quantity_id_buck ON _timescaledb_internal._hyper_7_5617_chunk USING btree (quantity_id, bucket DESC);


--
-- Name: _hyper_7_5617_chunk__materialized_hypertable_7_source_system_bu; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5617_chunk__materialized_hypertable_7_source_system_bu ON _timescaledb_internal._hyper_7_5617_chunk USING btree (source_system, bucket DESC);


--
-- Name: _hyper_7_5617_chunk__materialized_hypertable_7_tenant_id_bucket; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _hyper_7_5617_chunk__materialized_hypertable_7_tenant_id_bucket ON _timescaledb_internal._hyper_7_5617_chunk USING btree (tenant_id, bucket DESC);


--
-- Name: _materialized_hypertable_7_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _materialized_hypertable_7_bucket_idx ON _timescaledb_internal._materialized_hypertable_7 USING btree (bucket DESC);


--
-- Name: _materialized_hypertable_7_device_id_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _materialized_hypertable_7_device_id_bucket_idx ON _timescaledb_internal._materialized_hypertable_7 USING btree (device_id, bucket DESC);


--
-- Name: _materialized_hypertable_7_quantity_id_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _materialized_hypertable_7_quantity_id_bucket_idx ON _timescaledb_internal._materialized_hypertable_7 USING btree (quantity_id, bucket DESC);


--
-- Name: _materialized_hypertable_7_source_system_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _materialized_hypertable_7_source_system_bucket_idx ON _timescaledb_internal._materialized_hypertable_7 USING btree (source_system, bucket DESC);


--
-- Name: _materialized_hypertable_7_tenant_id_bucket_idx; Type: INDEX; Schema: _timescaledb_internal; Owner: -
--

CREATE INDEX _materialized_hypertable_7_tenant_id_bucket_idx ON _timescaledb_internal._materialized_hypertable_7 USING btree (tenant_id, bucket DESC);


--
-- Name: idx_baseline_active; Type: INDEX; Schema: prs; Owner: -
--

CREATE INDEX idx_baseline_active ON prs.baseline_load_profiles USING btree (tenant_id, is_active) WHERE (is_active = true);


--
-- Name: idx_baseline_day_type; Type: INDEX; Schema: prs; Owner: -
--

CREATE INDEX idx_baseline_day_type ON prs.baseline_load_profiles USING btree (day_type);


--
-- Name: idx_baseline_load_group; Type: INDEX; Schema: prs; Owner: -
--

CREATE INDEX idx_baseline_load_group ON prs.baseline_load_profiles USING btree (load_group);


--
-- Name: idx_baseline_profile_type; Type: INDEX; Schema: prs; Owner: -
--

CREATE INDEX idx_baseline_profile_type ON prs.baseline_load_profiles USING btree (profile_type);


--
-- Name: idx_baseline_shift_only; Type: INDEX; Schema: prs; Owner: -
--

CREATE INDEX idx_baseline_shift_only ON prs.baseline_load_profiles USING btree (shift_name) WHERE (time_hhmm IS NULL);


--
-- Name: idx_baseline_shift_time; Type: INDEX; Schema: prs; Owner: -
--

CREATE INDEX idx_baseline_shift_time ON prs.baseline_load_profiles USING btree (shift_name, time_hhmm) WHERE (time_hhmm IS NOT NULL);


--
-- Name: idx_baseline_tenant_version_profile; Type: INDEX; Schema: prs; Owner: -
--

CREATE INDEX idx_baseline_tenant_version_profile ON prs.baseline_load_profiles USING btree (tenant_id, baseline_version, profile_type);


--
-- Name: audit_logs_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_logs_created_at_idx ON public.audit_logs USING btree (created_at DESC);


--
-- Name: idx_asset_connections_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_asset_connections_active ON public.asset_connections USING btree (is_active);


--
-- Name: idx_asset_connections_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_asset_connections_source ON public.asset_connections USING btree (source_asset_id);


--
-- Name: idx_asset_connections_target; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_asset_connections_target ON public.asset_connections USING btree (target_asset_id);


--
-- Name: idx_asset_connections_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_asset_connections_type ON public.asset_connections USING btree (connection_type);


--
-- Name: idx_asset_files_asset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_asset_files_asset ON public.asset_files USING btree (asset_id);


--
-- Name: idx_asset_tags_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_asset_tags_active ON public.asset_tags USING btree (is_active);


--
-- Name: idx_asset_tags_asset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_asset_tags_asset ON public.asset_tags USING btree (asset_id);


--
-- Name: idx_asset_tags_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_asset_tags_category ON public.asset_tags USING btree (tag_category);


--
-- Name: idx_asset_tags_effective; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_asset_tags_effective ON public.asset_tags USING btree (effective_from, effective_to);


--
-- Name: idx_asset_tags_key_value; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_asset_tags_key_value ON public.asset_tags USING btree (tag_key, tag_value);


--
-- Name: idx_assets_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_assets_active ON public.assets USING btree (is_active);


--
-- Name: idx_assets_conversion; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_assets_conversion ON public.assets USING btree (source_utility, output_utility) WHERE (source_utility IS NOT NULL);


--
-- Name: idx_assets_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_assets_parent ON public.assets USING btree (parent_id);


--
-- Name: idx_assets_path; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_assets_path ON public.assets USING gin (utility_path public.gin_trgm_ops);


--
-- Name: idx_assets_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_assets_tenant ON public.assets USING btree (tenant_id);


--
-- Name: idx_assets_tenant_utility_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_assets_tenant_utility_active ON public.assets USING btree (tenant_id, utility_type, is_active);


--
-- Name: idx_assets_utility_hierarchy; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_assets_utility_hierarchy ON public.assets USING btree (tenant_id, utility_type, utility_level);


--
-- Name: idx_assets_utility_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_assets_utility_type ON public.assets USING btree (utility_type);


--
-- Name: idx_audit_logs_action_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_action_type ON public.audit_logs USING btree (action_type);


--
-- Name: idx_audit_logs_resource; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_resource ON public.audit_logs USING btree (resource_type, resource_id);


--
-- Name: idx_audit_logs_tenant_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_tenant_time ON public.audit_logs USING btree (tenant_id, created_at DESC);


--
-- Name: idx_audit_logs_user_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_user_time ON public.audit_logs USING btree (user_id, created_at DESC);


--
-- Name: idx_audit_logs_user_type_recent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_logs_user_type_recent ON public.audit_logs USING btree (user_id, action_type, created_at DESC);


--
-- Name: idx_auth_audit_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_audit_created_at ON public.auth_audit_logs USING btree (created_at);


--
-- Name: idx_auth_audit_event_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_audit_event_type ON public.auth_audit_logs USING btree (event_type);


--
-- Name: idx_auth_audit_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_audit_tenant_id ON public.auth_audit_logs USING btree (tenant_id);


--
-- Name: idx_auth_audit_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_audit_user_id ON public.auth_audit_logs USING btree (user_id);


--
-- Name: idx_auth_email_verifications_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_email_verifications_expires ON public.auth_email_verifications USING btree (expires_at);


--
-- Name: idx_auth_email_verifications_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_email_verifications_token ON public.auth_email_verifications USING btree (token_hash);


--
-- Name: idx_auth_oauth_provider_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_oauth_provider_user ON public.auth_user_oauth USING btree (provider_id, provider_user_id);


--
-- Name: idx_auth_oauth_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_oauth_user_id ON public.auth_user_oauth USING btree (user_id);


--
-- Name: idx_auth_password_resets_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_password_resets_expires ON public.auth_password_resets USING btree (expires_at);


--
-- Name: idx_auth_password_resets_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_password_resets_token ON public.auth_password_resets USING btree (token_hash);


--
-- Name: idx_auth_permissions_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_permissions_category ON public.auth_permissions USING btree (category);


--
-- Name: idx_auth_permissions_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_permissions_code ON public.auth_permissions USING btree (permission_code);


--
-- Name: idx_auth_products_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_products_active ON public.auth_products USING btree (is_active);


--
-- Name: idx_auth_products_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_products_code ON public.auth_products USING btree (product_code);


--
-- Name: idx_auth_roles_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_roles_code ON public.auth_roles USING btree (role_code);


--
-- Name: idx_auth_sessions_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_sessions_active ON public.auth_user_sessions USING btree (is_revoked, expires_at);


--
-- Name: idx_auth_sessions_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_sessions_expires ON public.auth_user_sessions USING btree (expires_at);


--
-- Name: idx_auth_sessions_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_sessions_token ON public.auth_user_sessions USING btree (session_token);


--
-- Name: idx_auth_sessions_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_sessions_user_id ON public.auth_user_sessions USING btree (user_id);


--
-- Name: idx_auth_user_tenants_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_user_tenants_active ON public.auth_user_tenants USING btree (is_active);


--
-- Name: idx_auth_user_tenants_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_user_tenants_product ON public.auth_user_tenants USING btree (product_id);


--
-- Name: idx_auth_user_tenants_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_user_tenants_product_id ON public.auth_user_tenants USING btree (product_id);


--
-- Name: idx_auth_user_tenants_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_user_tenants_tenant ON public.auth_user_tenants USING btree (tenant_id);


--
-- Name: idx_auth_user_tenants_tenant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_user_tenants_tenant_id ON public.auth_user_tenants USING btree (tenant_id);


--
-- Name: idx_auth_user_tenants_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_user_tenants_user ON public.auth_user_tenants USING btree (user_id);


--
-- Name: idx_auth_user_tenants_user_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_user_tenants_user_active ON public.auth_user_tenants USING btree (user_id, tenant_id, is_active) WHERE (is_active = true);


--
-- Name: idx_auth_user_tenants_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_user_tenants_user_id ON public.auth_user_tenants USING btree (user_id);


--
-- Name: idx_auth_users_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_users_active ON public.auth_users USING btree (is_active);


--
-- Name: idx_auth_users_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_users_email ON public.auth_users USING btree (email);


--
-- Name: idx_auth_users_last_login; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_users_last_login ON public.auth_users USING btree (last_login_at);


--
-- Name: idx_daily_energy_cost_grouping_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_daily_energy_cost_grouping_type ON public.daily_energy_cost_summary USING btree (grouping_type, tenant_id, daily_bucket DESC);


--
-- Name: idx_daily_energy_cost_last_refreshed; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_daily_energy_cost_last_refreshed ON public.daily_energy_cost_summary USING btree (last_refreshed DESC);


--
-- Name: idx_daily_energy_cost_tenant_device_date_quantity_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_daily_energy_cost_tenant_device_date_quantity_type ON public.daily_energy_cost_summary USING btree (tenant_id, device_id, quantity_id, grouping_type, daily_bucket DESC);


--
-- Name: idx_daily_energy_cost_tenant_rate_quantity_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_daily_energy_cost_tenant_rate_quantity_date ON public.daily_energy_cost_summary USING btree (tenant_id, rate_code, quantity_id, daily_bucket DESC) WHERE (grouping_type = 'RATE'::text);


--
-- Name: idx_daily_energy_cost_tenant_shift_quantity_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_daily_energy_cost_tenant_shift_quantity_date ON public.daily_energy_cost_summary USING btree (tenant_id, shift_period, quantity_id, daily_bucket DESC) WHERE (grouping_type = 'SHIFT'::text);


--
-- Name: idx_device_alerts_device; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_alerts_device ON public.device_alerts USING btree (device_id);


--
-- Name: idx_device_alerts_severity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_alerts_severity ON public.device_alerts USING btree (severity);


--
-- Name: idx_device_alerts_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_alerts_tenant ON public.device_alerts USING btree (tenant_id);


--
-- Name: idx_device_files_device; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_files_device ON public.device_files USING btree (device_id);


--
-- Name: idx_device_mappings_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_mappings_active ON public.device_utility_mappings USING btree (is_active);


--
-- Name: idx_device_mappings_device; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_mappings_device ON public.device_mappings USING btree (device_id);


--
-- Name: idx_device_mappings_effective; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_mappings_effective ON public.device_utility_mappings USING btree (effective_from, effective_to);


--
-- Name: idx_device_mappings_external; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_mappings_external ON public.device_mappings USING btree (external_system, external_id);


--
-- Name: idx_device_mappings_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_mappings_lookup ON public.device_utility_mappings USING btree (device_id, is_active, effective_from, effective_to);


--
-- Name: idx_device_mappings_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_mappings_source ON public.device_utility_mappings USING btree (utility_source_id);


--
-- Name: idx_device_mappings_utilities; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_mappings_utilities ON public.device_utility_mappings USING btree (device_id);


--
-- Name: idx_device_patterns_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_patterns_lookup ON public.device_consumption_patterns USING btree (tenant_id, device_id, quantity_id, day_of_week, hour_of_day);


--
-- Name: idx_device_patterns_tenant_device; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_patterns_tenant_device ON public.device_consumption_patterns USING btree (tenant_id, device_id);


--
-- Name: idx_device_tags_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_tags_active ON public.device_tags USING btree (is_active);


--
-- Name: idx_device_tags_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_tags_category ON public.device_tags USING btree (tag_category);


--
-- Name: idx_device_tags_complex; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_tags_complex ON public.device_tags USING btree (tag_key, tag_value, is_active, effective_from, effective_to);


--
-- Name: idx_device_tags_device; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_tags_device ON public.device_tags USING btree (device_id);


--
-- Name: idx_device_tags_device_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_tags_device_active ON public.device_tags USING btree (device_id, is_active);


--
-- Name: idx_device_tags_effective; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_tags_effective ON public.device_tags USING btree (effective_from, effective_to);


--
-- Name: idx_device_tags_key_value; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_device_tags_key_value ON public.device_tags USING btree (tag_key, tag_value);


--
-- Name: idx_devices_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_devices_active ON public.devices USING btree (is_active);


--
-- Name: idx_devices_asset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_devices_asset ON public.devices USING btree (asset_id);


--
-- Name: idx_devices_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_devices_code ON public.devices USING btree (device_code);


--
-- Name: idx_devices_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_devices_status ON public.devices USING btree (status);


--
-- Name: idx_devices_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_devices_tenant ON public.devices USING btree (tenant_id);


--
-- Name: idx_devices_tenant_active_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_devices_tenant_active_id ON public.devices USING btree (tenant_id, is_active, id) WHERE (is_active = true);


--
-- Name: idx_energy_costs_asset_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_energy_costs_asset_date ON public.energy_costs USING btree (asset_id, calculation_date);


--
-- Name: idx_energy_costs_device_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_energy_costs_device_date ON public.energy_costs USING btree (device_id, calculation_date);


--
-- Name: idx_energy_costs_tenant_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_energy_costs_tenant_date ON public.energy_costs USING btree (tenant_id, calculation_date);


--
-- Name: idx_enpi_calculations_asset_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_enpi_calculations_asset_date ON public.enpi_calculations USING btree (asset_id, calculation_date);


--
-- Name: idx_enpi_calculations_tenant_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_enpi_calculations_tenant_date ON public.enpi_calculations USING btree (tenant_id, calculation_date);


--
-- Name: idx_file_storage_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_file_storage_tenant ON public.file_storage USING btree (tenant_id);


--
-- Name: idx_file_storage_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_file_storage_type ON public.file_storage USING btree (file_type);


--
-- Name: idx_file_storage_version; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_file_storage_version ON public.file_storage USING btree (parent_file_id, version);


--
-- Name: idx_hotspot_asset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hotspot_asset ON public.hotspot_coordinates USING btree (asset_id);


--
-- Name: idx_hotspot_device; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hotspot_device ON public.hotspot_coordinates USING btree (device_id);


--
-- Name: idx_hotspot_file; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hotspot_file ON public.hotspot_coordinates USING btree (file_id);


--
-- Name: idx_hotspot_level; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hotspot_level ON public.hotspot_coordinates USING btree (level);


--
-- Name: idx_hotspot_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hotspot_type ON public.hotspot_coordinates USING btree (coordinate_type);


--
-- Name: idx_operational_data_asset_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_operational_data_asset_date ON public.operational_data USING btree (asset_id, data_date);


--
-- Name: idx_operational_data_batch; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_operational_data_batch ON public.operational_data USING btree (batch_id);


--
-- Name: idx_operational_data_tenant_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_operational_data_tenant_date ON public.operational_data USING btree (tenant_id, data_date);


--
-- Name: idx_processed_gaps_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_processed_gaps_lookup ON public.processed_gaps USING btree (tenant_id, device_id, quantity_id, gap_start, gap_end);


--
-- Name: idx_processed_gaps_tenant_device; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_processed_gaps_tenant_device ON public.processed_gaps USING btree (tenant_id, device_id);


--
-- Name: idx_processed_gaps_timerange; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_processed_gaps_timerange ON public.processed_gaps USING btree (gap_start, gap_end);


--
-- Name: idx_quantities_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_quantities_active ON public.quantities USING btree (is_active);


--
-- Name: idx_quantities_active_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_quantities_active_category ON public.quantities USING btree (is_active, category, id) WHERE (is_active = true);


--
-- Name: idx_quantities_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_quantities_category ON public.quantities USING btree (category);


--
-- Name: idx_quantities_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_quantities_code ON public.quantities USING btree (quantity_code);


--
-- Name: idx_quantities_is_cumulative; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_quantities_is_cumulative ON public.quantities USING btree (is_cumulative);


--
-- Name: idx_redistributed_intervals_bucket; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_redistributed_intervals_bucket ON public.redistributed_intervals USING btree (bucket);


--
-- Name: idx_redistributed_intervals_gap; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_redistributed_intervals_gap ON public.redistributed_intervals USING btree (gap_id);


--
-- Name: idx_redistributed_intervals_gap_bucket; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_redistributed_intervals_gap_bucket ON public.redistributed_intervals USING btree (gap_id, bucket);


--
-- Name: idx_sankey_levels_mapping_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sankey_levels_mapping_order ON public.sankey_levels USING btree (sankey_mapping_id, level_order);


--
-- Name: idx_sankey_links_mapping_nodes; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sankey_links_mapping_nodes ON public.sankey_links USING btree (sankey_mapping_id, source_node_id, target_node_id);


--
-- Name: idx_sankey_links_quantity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sankey_links_quantity ON public.sankey_links USING btree (quantity_id) WHERE (quantity_id IS NOT NULL);


--
-- Name: idx_sankey_mappings_tenant_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sankey_mappings_tenant_active ON public.sankey_mappings USING btree (tenant_id, is_active);


--
-- Name: idx_sankey_nodes_asset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sankey_nodes_asset ON public.sankey_nodes USING btree (asset_id) WHERE (asset_id IS NOT NULL);


--
-- Name: idx_sankey_nodes_device; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sankey_nodes_device ON public.sankey_nodes USING btree (device_id) WHERE (device_id IS NOT NULL);


--
-- Name: idx_sankey_nodes_mapping_node; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sankey_nodes_mapping_node ON public.sankey_nodes USING btree (sankey_mapping_id, node_id);


--
-- Name: idx_shift_effective; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_shift_effective ON public.tenant_shift_periods USING btree (effective_from, effective_to);


--
-- Name: idx_shift_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_shift_tenant ON public.tenant_shift_periods USING btree (tenant_id);


--
-- Name: idx_telemetry_device_quantity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_telemetry_device_quantity ON public.telemetry_data USING btree (device_id, quantity_id, "timestamp" DESC);


--
-- Name: idx_telemetry_device_quantity_timestamp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_telemetry_device_quantity_timestamp ON public.telemetry_data USING btree (device_id, quantity_id, "timestamp" DESC, tenant_id);


--
-- Name: idx_telemetry_device_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_telemetry_device_time ON public.telemetry_data USING btree (device_id, "timestamp" DESC);


--
-- Name: idx_telemetry_quality_recent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_telemetry_quality_recent ON public.telemetry_data USING btree (quantity_id, device_id, quality, "timestamp");


--
-- Name: idx_telemetry_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_telemetry_source ON public.telemetry_data USING btree (source_system);


--
-- Name: idx_telemetry_tenant_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_telemetry_tenant_time ON public.telemetry_data USING btree (tenant_id, "timestamp" DESC);


--
-- Name: idx_telemetry_unified_raw_device_qty; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_telemetry_unified_raw_device_qty ON public.telemetry_unified_raw USING btree (device_id, quantity_id);


--
-- Name: idx_telemetry_unified_raw_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_telemetry_unified_raw_tenant ON public.telemetry_unified_raw USING btree (tenant_id);


--
-- Name: idx_telemetry_unified_raw_timestamp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_telemetry_unified_raw_timestamp ON public.telemetry_unified_raw USING btree ("timestamp" DESC);


--
-- Name: idx_telemetry_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_telemetry_unique ON public.telemetry_data USING btree ("timestamp", device_id, quantity_id);


--
-- Name: idx_tenants_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenants_active ON public.tenants USING btree (is_active);


--
-- Name: idx_tenants_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenants_code ON public.tenants USING btree (tenant_code);


--
-- Name: idx_tenants_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tenants_type ON public.tenants USING btree (tenant_type);


--
-- Name: idx_tou_effective; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tou_effective ON public.tou_rate_periods USING btree (effective_from, effective_to);


--
-- Name: idx_tou_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tou_tenant ON public.tou_rate_periods USING btree (tenant_id);


--
-- Name: idx_utility_rates_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_utility_rates_active ON public.utility_rates USING btree (is_active);


--
-- Name: idx_utility_rates_effective; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_utility_rates_effective ON public.utility_rates USING btree (effective_from, effective_to);


--
-- Name: idx_utility_rates_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_utility_rates_lookup ON public.utility_rates USING btree (utility_source_id, rate_structure, is_active, effective_from, effective_to);


--
-- Name: idx_utility_rates_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_utility_rates_source ON public.utility_rates USING btree (utility_source_id);


--
-- Name: idx_utility_rates_source_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_utility_rates_source_active ON public.utility_rates USING btree (utility_source_id, is_active);


--
-- Name: idx_utility_rates_structure; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_utility_rates_structure ON public.utility_rates USING btree (rate_structure);


--
-- Name: idx_utility_sources_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_utility_sources_active ON public.utility_sources USING btree (is_active);


--
-- Name: idx_utility_sources_source_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_utility_sources_source_type ON public.utility_sources USING btree (source_type);


--
-- Name: idx_utility_sources_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_utility_sources_tenant ON public.utility_sources USING btree (tenant_id);


--
-- Name: idx_utility_sources_utility_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_utility_sources_utility_type ON public.utility_sources USING btree (utility_type);


--
-- Name: telemetry_data_timestamp_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX telemetry_data_timestamp_idx ON public.telemetry_data USING btree ("timestamp" DESC);


--
-- Name: _hyper_1_5611_chunk ts_cagg_invalidation_trigger; Type: TRIGGER; Schema: _timescaledb_internal; Owner: -
--

CREATE TRIGGER ts_cagg_invalidation_trigger AFTER INSERT OR DELETE OR UPDATE ON _timescaledb_internal._hyper_1_5611_chunk FOR EACH ROW EXECUTE FUNCTION _timescaledb_functions.continuous_agg_invalidation_trigger('1');


--
-- Name: _hyper_1_5612_chunk ts_cagg_invalidation_trigger; Type: TRIGGER; Schema: _timescaledb_internal; Owner: -
--

CREATE TRIGGER ts_cagg_invalidation_trigger AFTER INSERT OR DELETE OR UPDATE ON _timescaledb_internal._hyper_1_5612_chunk FOR EACH ROW EXECUTE FUNCTION _timescaledb_functions.continuous_agg_invalidation_trigger('1');


--
-- Name: _hyper_1_5613_chunk ts_cagg_invalidation_trigger; Type: TRIGGER; Schema: _timescaledb_internal; Owner: -
--

CREATE TRIGGER ts_cagg_invalidation_trigger AFTER INSERT OR DELETE OR UPDATE ON _timescaledb_internal._hyper_1_5613_chunk FOR EACH ROW EXECUTE FUNCTION _timescaledb_functions.continuous_agg_invalidation_trigger('1');


--
-- Name: _hyper_1_5614_chunk ts_cagg_invalidation_trigger; Type: TRIGGER; Schema: _timescaledb_internal; Owner: -
--

CREATE TRIGGER ts_cagg_invalidation_trigger AFTER INSERT OR DELETE OR UPDATE ON _timescaledb_internal._hyper_1_5614_chunk FOR EACH ROW EXECUTE FUNCTION _timescaledb_functions.continuous_agg_invalidation_trigger('1');


--
-- Name: _hyper_1_5615_chunk ts_cagg_invalidation_trigger; Type: TRIGGER; Schema: _timescaledb_internal; Owner: -
--

CREATE TRIGGER ts_cagg_invalidation_trigger AFTER INSERT OR DELETE OR UPDATE ON _timescaledb_internal._hyper_1_5615_chunk FOR EACH ROW EXECUTE FUNCTION _timescaledb_functions.continuous_agg_invalidation_trigger('1');


--
-- Name: _hyper_1_5616_chunk ts_cagg_invalidation_trigger; Type: TRIGGER; Schema: _timescaledb_internal; Owner: -
--

CREATE TRIGGER ts_cagg_invalidation_trigger AFTER INSERT OR DELETE OR UPDATE ON _timescaledb_internal._hyper_1_5616_chunk FOR EACH ROW EXECUTE FUNCTION _timescaledb_functions.continuous_agg_invalidation_trigger('1');


--
-- Name: _hyper_1_5618_chunk ts_cagg_invalidation_trigger; Type: TRIGGER; Schema: _timescaledb_internal; Owner: -
--

CREATE TRIGGER ts_cagg_invalidation_trigger AFTER INSERT OR DELETE OR UPDATE ON _timescaledb_internal._hyper_1_5618_chunk FOR EACH ROW EXECUTE FUNCTION _timescaledb_functions.continuous_agg_invalidation_trigger('1');


--
-- Name: _hyper_1_5619_chunk ts_cagg_invalidation_trigger; Type: TRIGGER; Schema: _timescaledb_internal; Owner: -
--

CREATE TRIGGER ts_cagg_invalidation_trigger AFTER INSERT OR DELETE OR UPDATE ON _timescaledb_internal._hyper_1_5619_chunk FOR EACH ROW EXECUTE FUNCTION _timescaledb_functions.continuous_agg_invalidation_trigger('1');


--
-- Name: _hyper_1_5620_chunk ts_cagg_invalidation_trigger; Type: TRIGGER; Schema: _timescaledb_internal; Owner: -
--

CREATE TRIGGER ts_cagg_invalidation_trigger AFTER INSERT OR DELETE OR UPDATE ON _timescaledb_internal._hyper_1_5620_chunk FOR EACH ROW EXECUTE FUNCTION _timescaledb_functions.continuous_agg_invalidation_trigger('1');


--
-- Name: _hyper_1_5621_chunk ts_cagg_invalidation_trigger; Type: TRIGGER; Schema: _timescaledb_internal; Owner: -
--

CREATE TRIGGER ts_cagg_invalidation_trigger AFTER INSERT OR DELETE OR UPDATE ON _timescaledb_internal._hyper_1_5621_chunk FOR EACH ROW EXECUTE FUNCTION _timescaledb_functions.continuous_agg_invalidation_trigger('1');


--
-- Name: _hyper_1_5622_chunk ts_cagg_invalidation_trigger; Type: TRIGGER; Schema: _timescaledb_internal; Owner: -
--

CREATE TRIGGER ts_cagg_invalidation_trigger AFTER INSERT OR DELETE OR UPDATE ON _timescaledb_internal._hyper_1_5622_chunk FOR EACH ROW EXECUTE FUNCTION _timescaledb_functions.continuous_agg_invalidation_trigger('1');


--
-- Name: _hyper_1_5623_chunk ts_cagg_invalidation_trigger; Type: TRIGGER; Schema: _timescaledb_internal; Owner: -
--

CREATE TRIGGER ts_cagg_invalidation_trigger AFTER INSERT OR DELETE OR UPDATE ON _timescaledb_internal._hyper_1_5623_chunk FOR EACH ROW EXECUTE FUNCTION _timescaledb_functions.continuous_agg_invalidation_trigger('1');


--
-- Name: _hyper_1_5624_chunk ts_cagg_invalidation_trigger; Type: TRIGGER; Schema: _timescaledb_internal; Owner: -
--

CREATE TRIGGER ts_cagg_invalidation_trigger AFTER INSERT OR DELETE OR UPDATE ON _timescaledb_internal._hyper_1_5624_chunk FOR EACH ROW EXECUTE FUNCTION _timescaledb_functions.continuous_agg_invalidation_trigger('1');


--
-- Name: _hyper_1_5625_chunk ts_cagg_invalidation_trigger; Type: TRIGGER; Schema: _timescaledb_internal; Owner: -
--

CREATE TRIGGER ts_cagg_invalidation_trigger AFTER INSERT OR DELETE OR UPDATE ON _timescaledb_internal._hyper_1_5625_chunk FOR EACH ROW EXECUTE FUNCTION _timescaledb_functions.continuous_agg_invalidation_trigger('1');


--
-- Name: _hyper_1_5626_chunk ts_cagg_invalidation_trigger; Type: TRIGGER; Schema: _timescaledb_internal; Owner: -
--

CREATE TRIGGER ts_cagg_invalidation_trigger AFTER INSERT OR DELETE OR UPDATE ON _timescaledb_internal._hyper_1_5626_chunk FOR EACH ROW EXECUTE FUNCTION _timescaledb_functions.continuous_agg_invalidation_trigger('1');


--
-- Name: _materialized_hypertable_7 ts_insert_blocker; Type: TRIGGER; Schema: _timescaledb_internal; Owner: -
--

CREATE TRIGGER ts_insert_blocker BEFORE INSERT ON _timescaledb_internal._materialized_hypertable_7 FOR EACH ROW EXECUTE FUNCTION _timescaledb_functions.insert_blocker();


--
-- Name: sankey_mappings sankey_mappings_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER sankey_mappings_updated_at BEFORE UPDATE ON public.sankey_mappings FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: auth_oauth_providers trigger_auth_oauth_providers_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_auth_oauth_providers_updated_at BEFORE UPDATE ON public.auth_oauth_providers FOR EACH ROW EXECUTE FUNCTION public.auth_update_updated_at_column();


--
-- Name: auth_products trigger_auth_products_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_auth_products_updated_at BEFORE UPDATE ON public.auth_products FOR EACH ROW EXECUTE FUNCTION public.auth_update_updated_at_column();


--
-- Name: auth_user_oauth trigger_auth_user_oauth_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_auth_user_oauth_updated_at BEFORE UPDATE ON public.auth_user_oauth FOR EACH ROW EXECUTE FUNCTION public.auth_update_updated_at_column();


--
-- Name: auth_user_tenants trigger_auth_user_tenants_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_auth_user_tenants_updated_at BEFORE UPDATE ON public.auth_user_tenants FOR EACH ROW EXECUTE FUNCTION public.auth_update_updated_at_column();


--
-- Name: auth_users trigger_auth_users_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_auth_users_updated_at BEFORE UPDATE ON public.auth_users FOR EACH ROW EXECUTE FUNCTION public.auth_update_updated_at_column();


--
-- Name: device_utility_mappings trigger_device_utility_mappings_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_device_utility_mappings_updated_at BEFORE UPDATE ON public.device_utility_mappings FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: devices trigger_devices_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_devices_updated_at BEFORE UPDATE ON public.devices FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: tenants trigger_tenants_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_tenants_updated_at BEFORE UPDATE ON public.tenants FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: assets trigger_update_utility_path; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_update_utility_path BEFORE INSERT OR UPDATE OF parent_id, utility_type ON public.assets FOR EACH ROW EXECUTE FUNCTION public.update_utility_path();


--
-- Name: utility_rates trigger_utility_rates_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_utility_rates_updated_at BEFORE UPDATE ON public.utility_rates FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: utility_sources trigger_utility_sources_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trigger_utility_sources_updated_at BEFORE UPDATE ON public.utility_sources FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: telemetry_data ts_cagg_invalidation_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ts_cagg_invalidation_trigger AFTER INSERT OR DELETE OR UPDATE ON public.telemetry_data FOR EACH ROW EXECUTE FUNCTION _timescaledb_functions.continuous_agg_invalidation_trigger('1');


--
-- Name: audit_logs ts_insert_blocker; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ts_insert_blocker BEFORE INSERT ON public.audit_logs FOR EACH ROW EXECUTE FUNCTION _timescaledb_functions.insert_blocker();


--
-- Name: telemetry_data ts_insert_blocker; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ts_insert_blocker BEFORE INSERT ON public.telemetry_data FOR EACH ROW EXECUTE FUNCTION _timescaledb_functions.insert_blocker();


--
-- Name: _hyper_6_1_chunk 1_2_audit_logs_tenant_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_6_1_chunk
    ADD CONSTRAINT "1_2_audit_logs_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: _hyper_6_305_chunk 305_744_audit_logs_tenant_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_6_305_chunk
    ADD CONSTRAINT "305_744_audit_logs_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: _hyper_6_5559_chunk 5559_16484_audit_logs_tenant_id_fkey; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_6_5559_chunk
    ADD CONSTRAINT "5559_16484_audit_logs_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: _hyper_1_5611_chunk 5611_16623_fk_telemetry_device; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5611_chunk
    ADD CONSTRAINT "5611_16623_fk_telemetry_device" FOREIGN KEY (device_id) REFERENCES public.devices(id);


--
-- Name: _hyper_1_5611_chunk 5611_16624_fk_telemetry_quantity; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5611_chunk
    ADD CONSTRAINT "5611_16624_fk_telemetry_quantity" FOREIGN KEY (quantity_id) REFERENCES public.quantities(id);


--
-- Name: _hyper_1_5611_chunk 5611_16625_fk_telemetry_tenant; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5611_chunk
    ADD CONSTRAINT "5611_16625_fk_telemetry_tenant" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: _hyper_1_5612_chunk 5612_16626_fk_telemetry_device; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5612_chunk
    ADD CONSTRAINT "5612_16626_fk_telemetry_device" FOREIGN KEY (device_id) REFERENCES public.devices(id);


--
-- Name: _hyper_1_5612_chunk 5612_16627_fk_telemetry_quantity; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5612_chunk
    ADD CONSTRAINT "5612_16627_fk_telemetry_quantity" FOREIGN KEY (quantity_id) REFERENCES public.quantities(id);


--
-- Name: _hyper_1_5612_chunk 5612_16628_fk_telemetry_tenant; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5612_chunk
    ADD CONSTRAINT "5612_16628_fk_telemetry_tenant" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: _hyper_1_5613_chunk 5613_16629_fk_telemetry_device; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5613_chunk
    ADD CONSTRAINT "5613_16629_fk_telemetry_device" FOREIGN KEY (device_id) REFERENCES public.devices(id);


--
-- Name: _hyper_1_5613_chunk 5613_16630_fk_telemetry_quantity; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5613_chunk
    ADD CONSTRAINT "5613_16630_fk_telemetry_quantity" FOREIGN KEY (quantity_id) REFERENCES public.quantities(id);


--
-- Name: _hyper_1_5613_chunk 5613_16631_fk_telemetry_tenant; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5613_chunk
    ADD CONSTRAINT "5613_16631_fk_telemetry_tenant" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: _hyper_1_5614_chunk 5614_16632_fk_telemetry_device; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5614_chunk
    ADD CONSTRAINT "5614_16632_fk_telemetry_device" FOREIGN KEY (device_id) REFERENCES public.devices(id);


--
-- Name: _hyper_1_5614_chunk 5614_16633_fk_telemetry_quantity; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5614_chunk
    ADD CONSTRAINT "5614_16633_fk_telemetry_quantity" FOREIGN KEY (quantity_id) REFERENCES public.quantities(id);


--
-- Name: _hyper_1_5614_chunk 5614_16634_fk_telemetry_tenant; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5614_chunk
    ADD CONSTRAINT "5614_16634_fk_telemetry_tenant" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: _hyper_1_5615_chunk 5615_16635_fk_telemetry_device; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5615_chunk
    ADD CONSTRAINT "5615_16635_fk_telemetry_device" FOREIGN KEY (device_id) REFERENCES public.devices(id);


--
-- Name: _hyper_1_5615_chunk 5615_16636_fk_telemetry_quantity; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5615_chunk
    ADD CONSTRAINT "5615_16636_fk_telemetry_quantity" FOREIGN KEY (quantity_id) REFERENCES public.quantities(id);


--
-- Name: _hyper_1_5615_chunk 5615_16637_fk_telemetry_tenant; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5615_chunk
    ADD CONSTRAINT "5615_16637_fk_telemetry_tenant" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: _hyper_1_5616_chunk 5616_16638_fk_telemetry_device; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5616_chunk
    ADD CONSTRAINT "5616_16638_fk_telemetry_device" FOREIGN KEY (device_id) REFERENCES public.devices(id);


--
-- Name: _hyper_1_5616_chunk 5616_16639_fk_telemetry_quantity; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5616_chunk
    ADD CONSTRAINT "5616_16639_fk_telemetry_quantity" FOREIGN KEY (quantity_id) REFERENCES public.quantities(id);


--
-- Name: _hyper_1_5616_chunk 5616_16640_fk_telemetry_tenant; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5616_chunk
    ADD CONSTRAINT "5616_16640_fk_telemetry_tenant" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: _hyper_1_5618_chunk 5618_16641_fk_telemetry_device; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5618_chunk
    ADD CONSTRAINT "5618_16641_fk_telemetry_device" FOREIGN KEY (device_id) REFERENCES public.devices(id);


--
-- Name: _hyper_1_5618_chunk 5618_16642_fk_telemetry_quantity; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5618_chunk
    ADD CONSTRAINT "5618_16642_fk_telemetry_quantity" FOREIGN KEY (quantity_id) REFERENCES public.quantities(id);


--
-- Name: _hyper_1_5618_chunk 5618_16643_fk_telemetry_tenant; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5618_chunk
    ADD CONSTRAINT "5618_16643_fk_telemetry_tenant" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: _hyper_1_5619_chunk 5619_16644_fk_telemetry_device; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5619_chunk
    ADD CONSTRAINT "5619_16644_fk_telemetry_device" FOREIGN KEY (device_id) REFERENCES public.devices(id);


--
-- Name: _hyper_1_5619_chunk 5619_16645_fk_telemetry_quantity; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5619_chunk
    ADD CONSTRAINT "5619_16645_fk_telemetry_quantity" FOREIGN KEY (quantity_id) REFERENCES public.quantities(id);


--
-- Name: _hyper_1_5619_chunk 5619_16646_fk_telemetry_tenant; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5619_chunk
    ADD CONSTRAINT "5619_16646_fk_telemetry_tenant" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: _hyper_1_5620_chunk 5620_16647_fk_telemetry_device; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5620_chunk
    ADD CONSTRAINT "5620_16647_fk_telemetry_device" FOREIGN KEY (device_id) REFERENCES public.devices(id);


--
-- Name: _hyper_1_5620_chunk 5620_16648_fk_telemetry_quantity; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5620_chunk
    ADD CONSTRAINT "5620_16648_fk_telemetry_quantity" FOREIGN KEY (quantity_id) REFERENCES public.quantities(id);


--
-- Name: _hyper_1_5620_chunk 5620_16649_fk_telemetry_tenant; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5620_chunk
    ADD CONSTRAINT "5620_16649_fk_telemetry_tenant" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: _hyper_1_5621_chunk 5621_16650_fk_telemetry_device; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5621_chunk
    ADD CONSTRAINT "5621_16650_fk_telemetry_device" FOREIGN KEY (device_id) REFERENCES public.devices(id);


--
-- Name: _hyper_1_5621_chunk 5621_16651_fk_telemetry_quantity; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5621_chunk
    ADD CONSTRAINT "5621_16651_fk_telemetry_quantity" FOREIGN KEY (quantity_id) REFERENCES public.quantities(id);


--
-- Name: _hyper_1_5621_chunk 5621_16652_fk_telemetry_tenant; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5621_chunk
    ADD CONSTRAINT "5621_16652_fk_telemetry_tenant" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: _hyper_1_5622_chunk 5622_16653_fk_telemetry_device; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5622_chunk
    ADD CONSTRAINT "5622_16653_fk_telemetry_device" FOREIGN KEY (device_id) REFERENCES public.devices(id);


--
-- Name: _hyper_1_5622_chunk 5622_16654_fk_telemetry_quantity; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5622_chunk
    ADD CONSTRAINT "5622_16654_fk_telemetry_quantity" FOREIGN KEY (quantity_id) REFERENCES public.quantities(id);


--
-- Name: _hyper_1_5622_chunk 5622_16655_fk_telemetry_tenant; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5622_chunk
    ADD CONSTRAINT "5622_16655_fk_telemetry_tenant" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: _hyper_1_5623_chunk 5623_16656_fk_telemetry_device; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5623_chunk
    ADD CONSTRAINT "5623_16656_fk_telemetry_device" FOREIGN KEY (device_id) REFERENCES public.devices(id);


--
-- Name: _hyper_1_5623_chunk 5623_16657_fk_telemetry_quantity; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5623_chunk
    ADD CONSTRAINT "5623_16657_fk_telemetry_quantity" FOREIGN KEY (quantity_id) REFERENCES public.quantities(id);


--
-- Name: _hyper_1_5623_chunk 5623_16658_fk_telemetry_tenant; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5623_chunk
    ADD CONSTRAINT "5623_16658_fk_telemetry_tenant" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: _hyper_1_5624_chunk 5624_16659_fk_telemetry_device; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5624_chunk
    ADD CONSTRAINT "5624_16659_fk_telemetry_device" FOREIGN KEY (device_id) REFERENCES public.devices(id);


--
-- Name: _hyper_1_5624_chunk 5624_16660_fk_telemetry_quantity; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5624_chunk
    ADD CONSTRAINT "5624_16660_fk_telemetry_quantity" FOREIGN KEY (quantity_id) REFERENCES public.quantities(id);


--
-- Name: _hyper_1_5624_chunk 5624_16661_fk_telemetry_tenant; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5624_chunk
    ADD CONSTRAINT "5624_16661_fk_telemetry_tenant" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: _hyper_1_5625_chunk 5625_16662_fk_telemetry_device; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5625_chunk
    ADD CONSTRAINT "5625_16662_fk_telemetry_device" FOREIGN KEY (device_id) REFERENCES public.devices(id);


--
-- Name: _hyper_1_5625_chunk 5625_16663_fk_telemetry_quantity; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5625_chunk
    ADD CONSTRAINT "5625_16663_fk_telemetry_quantity" FOREIGN KEY (quantity_id) REFERENCES public.quantities(id);


--
-- Name: _hyper_1_5625_chunk 5625_16664_fk_telemetry_tenant; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5625_chunk
    ADD CONSTRAINT "5625_16664_fk_telemetry_tenant" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: _hyper_1_5626_chunk 5626_16665_fk_telemetry_device; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5626_chunk
    ADD CONSTRAINT "5626_16665_fk_telemetry_device" FOREIGN KEY (device_id) REFERENCES public.devices(id);


--
-- Name: _hyper_1_5626_chunk 5626_16666_fk_telemetry_quantity; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5626_chunk
    ADD CONSTRAINT "5626_16666_fk_telemetry_quantity" FOREIGN KEY (quantity_id) REFERENCES public.quantities(id);


--
-- Name: _hyper_1_5626_chunk 5626_16667_fk_telemetry_tenant; Type: FK CONSTRAINT; Schema: _timescaledb_internal; Owner: -
--

ALTER TABLE ONLY _timescaledb_internal._hyper_1_5626_chunk
    ADD CONSTRAINT "5626_16667_fk_telemetry_tenant" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: asset_connections asset_connections_source_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_connections
    ADD CONSTRAINT asset_connections_source_asset_id_fkey FOREIGN KEY (source_asset_id) REFERENCES public.assets(id) ON DELETE CASCADE;


--
-- Name: asset_connections asset_connections_target_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_connections
    ADD CONSTRAINT asset_connections_target_asset_id_fkey FOREIGN KEY (target_asset_id) REFERENCES public.assets(id) ON DELETE CASCADE;


--
-- Name: asset_files asset_files_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_files
    ADD CONSTRAINT asset_files_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.file_storage(id) ON DELETE CASCADE;


--
-- Name: asset_tags asset_tags_asset_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.asset_tags
    ADD CONSTRAINT asset_tags_asset_id_fkey FOREIGN KEY (asset_id) REFERENCES public.assets(id) ON DELETE CASCADE;


--
-- Name: assets assets_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.assets(id) ON DELETE CASCADE;


--
-- Name: assets assets_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.assets
    ADD CONSTRAINT assets_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: audit_logs audit_logs_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: auth_audit_logs auth_audit_logs_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_audit_logs
    ADD CONSTRAINT auth_audit_logs_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.auth_user_sessions(id);


--
-- Name: auth_audit_logs auth_audit_logs_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_audit_logs
    ADD CONSTRAINT auth_audit_logs_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: auth_audit_logs auth_audit_logs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_audit_logs
    ADD CONSTRAINT auth_audit_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.auth_users(id);


--
-- Name: auth_email_verifications auth_email_verifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_email_verifications
    ADD CONSTRAINT auth_email_verifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.auth_users(id) ON DELETE CASCADE;


--
-- Name: auth_password_resets auth_password_resets_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_password_resets
    ADD CONSTRAINT auth_password_resets_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.auth_users(id) ON DELETE CASCADE;


--
-- Name: auth_permissions auth_permissions_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_permissions
    ADD CONSTRAINT auth_permissions_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.auth_products(id);


--
-- Name: auth_role_permissions auth_role_permissions_permission_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_role_permissions
    ADD CONSTRAINT auth_role_permissions_permission_id_fkey FOREIGN KEY (permission_id) REFERENCES public.auth_permissions(id) ON DELETE CASCADE;


--
-- Name: auth_role_permissions auth_role_permissions_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_role_permissions
    ADD CONSTRAINT auth_role_permissions_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.auth_roles(id) ON DELETE CASCADE;


--
-- Name: auth_roles auth_roles_parent_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_roles
    ADD CONSTRAINT auth_roles_parent_role_id_fkey FOREIGN KEY (parent_role_id) REFERENCES public.auth_roles(id);


--
-- Name: auth_roles auth_roles_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_roles
    ADD CONSTRAINT auth_roles_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.auth_products(id);


--
-- Name: auth_user_oauth auth_user_oauth_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_user_oauth
    ADD CONSTRAINT auth_user_oauth_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.auth_oauth_providers(id) ON DELETE CASCADE;


--
-- Name: auth_user_oauth auth_user_oauth_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_user_oauth
    ADD CONSTRAINT auth_user_oauth_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.auth_users(id) ON DELETE CASCADE;


--
-- Name: auth_user_sessions auth_user_sessions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_user_sessions
    ADD CONSTRAINT auth_user_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.auth_users(id) ON DELETE CASCADE;


--
-- Name: auth_user_tenants auth_user_tenants_granted_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_user_tenants
    ADD CONSTRAINT auth_user_tenants_granted_by_fkey FOREIGN KEY (granted_by) REFERENCES public.auth_users(id);


--
-- Name: auth_user_tenants auth_user_tenants_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_user_tenants
    ADD CONSTRAINT auth_user_tenants_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.auth_products(id) ON DELETE CASCADE;


--
-- Name: auth_user_tenants auth_user_tenants_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_user_tenants
    ADD CONSTRAINT auth_user_tenants_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: auth_user_tenants auth_user_tenants_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_user_tenants
    ADD CONSTRAINT auth_user_tenants_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.auth_users(id) ON DELETE CASCADE;


--
-- Name: device_alerts device_alerts_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_alerts
    ADD CONSTRAINT device_alerts_device_id_fkey FOREIGN KEY (device_id) REFERENCES public.devices(id) ON DELETE CASCADE;


--
-- Name: device_alerts device_alerts_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_alerts
    ADD CONSTRAINT device_alerts_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: device_files device_files_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_files
    ADD CONSTRAINT device_files_device_id_fkey FOREIGN KEY (device_id) REFERENCES public.devices(id) ON DELETE CASCADE;


--
-- Name: device_files device_files_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_files
    ADD CONSTRAINT device_files_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.file_storage(id) ON DELETE CASCADE;


--
-- Name: device_mappings device_mappings_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_mappings
    ADD CONSTRAINT device_mappings_device_id_fkey FOREIGN KEY (device_id) REFERENCES public.devices(id) ON DELETE CASCADE;


--
-- Name: device_tags device_tags_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_tags
    ADD CONSTRAINT device_tags_device_id_fkey FOREIGN KEY (device_id) REFERENCES public.devices(id) ON DELETE CASCADE;


--
-- Name: device_utility_mappings device_utility_mappings_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_utility_mappings
    ADD CONSTRAINT device_utility_mappings_device_id_fkey FOREIGN KEY (device_id) REFERENCES public.devices(id) ON DELETE CASCADE;


--
-- Name: device_utility_mappings device_utility_mappings_utility_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.device_utility_mappings
    ADD CONSTRAINT device_utility_mappings_utility_source_id_fkey FOREIGN KEY (utility_source_id) REFERENCES public.utility_sources(id) ON DELETE CASCADE;


--
-- Name: devices devices_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.devices
    ADD CONSTRAINT devices_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: enpi_calculations enpi_calculations_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enpi_calculations
    ADD CONSTRAINT enpi_calculations_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: file_storage file_storage_parent_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_storage
    ADD CONSTRAINT file_storage_parent_file_id_fkey FOREIGN KEY (parent_file_id) REFERENCES public.file_storage(id);


--
-- Name: file_storage file_storage_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.file_storage
    ADD CONSTRAINT file_storage_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: energy_costs fk_energy_cost_device; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.energy_costs
    ADD CONSTRAINT fk_energy_cost_device FOREIGN KEY (device_id) REFERENCES public.devices(id);


--
-- Name: energy_costs fk_energy_cost_tenant; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.energy_costs
    ADD CONSTRAINT fk_energy_cost_tenant FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: telemetry_data fk_telemetry_device; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telemetry_data
    ADD CONSTRAINT fk_telemetry_device FOREIGN KEY (device_id) REFERENCES public.devices(id);


--
-- Name: telemetry_data fk_telemetry_quantity; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telemetry_data
    ADD CONSTRAINT fk_telemetry_quantity FOREIGN KEY (quantity_id) REFERENCES public.quantities(id);


--
-- Name: telemetry_data fk_telemetry_tenant; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.telemetry_data
    ADD CONSTRAINT fk_telemetry_tenant FOREIGN KEY (tenant_id) REFERENCES public.tenants(id);


--
-- Name: hotspot_coordinates hotspot_coordinates_chart_data_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hotspot_coordinates
    ADD CONSTRAINT hotspot_coordinates_chart_data_source_id_fkey FOREIGN KEY (chart_data_source_id) REFERENCES public.devices(id);


--
-- Name: hotspot_coordinates hotspot_coordinates_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hotspot_coordinates
    ADD CONSTRAINT hotspot_coordinates_device_id_fkey FOREIGN KEY (device_id) REFERENCES public.devices(id) ON DELETE CASCADE;


--
-- Name: hotspot_coordinates hotspot_coordinates_file_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hotspot_coordinates
    ADD CONSTRAINT hotspot_coordinates_file_id_fkey FOREIGN KEY (file_id) REFERENCES public.file_storage(id) ON DELETE CASCADE;


--
-- Name: operational_data operational_data_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_data
    ADD CONSTRAINT operational_data_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: pme_quantity_mapping pme_quantity_mapping_new_quantity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pme_quantity_mapping
    ADD CONSTRAINT pme_quantity_mapping_new_quantity_id_fkey FOREIGN KEY (new_quantity_id) REFERENCES public.quantities(id);


--
-- Name: processed_gaps processed_gaps_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processed_gaps
    ADD CONSTRAINT processed_gaps_device_id_fkey FOREIGN KEY (device_id) REFERENCES public.devices(id) ON DELETE CASCADE;


--
-- Name: processed_gaps processed_gaps_quantity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processed_gaps
    ADD CONSTRAINT processed_gaps_quantity_id_fkey FOREIGN KEY (quantity_id) REFERENCES public.quantities(id) ON DELETE CASCADE;


--
-- Name: processed_gaps processed_gaps_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processed_gaps
    ADD CONSTRAINT processed_gaps_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: redistributed_intervals redistributed_intervals_gap_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.redistributed_intervals
    ADD CONSTRAINT redistributed_intervals_gap_id_fkey FOREIGN KEY (gap_id) REFERENCES public.processed_gaps(id) ON DELETE CASCADE;


--
-- Name: sankey_levels sankey_levels_sankey_mapping_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sankey_levels
    ADD CONSTRAINT sankey_levels_sankey_mapping_id_fkey FOREIGN KEY (sankey_mapping_id) REFERENCES public.sankey_mappings(id) ON DELETE CASCADE;


--
-- Name: sankey_links sankey_links_quantity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sankey_links
    ADD CONSTRAINT sankey_links_quantity_id_fkey FOREIGN KEY (quantity_id) REFERENCES public.quantities(id);


--
-- Name: sankey_links sankey_links_sankey_mapping_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sankey_links
    ADD CONSTRAINT sankey_links_sankey_mapping_id_fkey FOREIGN KEY (sankey_mapping_id) REFERENCES public.sankey_mappings(id) ON DELETE CASCADE;


--
-- Name: sankey_mappings sankey_mappings_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sankey_mappings
    ADD CONSTRAINT sankey_mappings_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: sankey_nodes sankey_nodes_device_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sankey_nodes
    ADD CONSTRAINT sankey_nodes_device_id_fkey FOREIGN KEY (device_id) REFERENCES public.devices(id) ON DELETE CASCADE;


--
-- Name: sankey_nodes sankey_nodes_level_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sankey_nodes
    ADD CONSTRAINT sankey_nodes_level_id_fkey FOREIGN KEY (level_id) REFERENCES public.sankey_levels(id) ON DELETE CASCADE;


--
-- Name: sankey_nodes sankey_nodes_sankey_mapping_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sankey_nodes
    ADD CONSTRAINT sankey_nodes_sankey_mapping_id_fkey FOREIGN KEY (sankey_mapping_id) REFERENCES public.sankey_mappings(id) ON DELETE CASCADE;


--
-- Name: tenant_shift_periods tenant_shift_periods_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tenant_shift_periods
    ADD CONSTRAINT tenant_shift_periods_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: tou_rate_periods tou_rate_periods_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tou_rate_periods
    ADD CONSTRAINT tou_rate_periods_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: utility_rates utility_rates_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_rates
    ADD CONSTRAINT utility_rates_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: utility_rates utility_rates_utility_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_rates
    ADD CONSTRAINT utility_rates_utility_source_id_fkey FOREIGN KEY (utility_source_id) REFERENCES public.utility_sources(id) ON DELETE CASCADE;


--
-- Name: utility_sources utility_sources_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.utility_sources
    ADD CONSTRAINT utility_sources_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;


--
-- Name: auth_audit_logs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.auth_audit_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: auth_audit_logs auth_service_full_access_audit; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY auth_service_full_access_audit ON public.auth_audit_logs TO auth_service_role USING (true);


--
-- Name: auth_user_sessions auth_service_full_access_sessions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY auth_service_full_access_sessions ON public.auth_user_sessions TO auth_service_role USING (true);


--
-- Name: auth_user_tenants auth_service_full_access_tenants; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY auth_service_full_access_tenants ON public.auth_user_tenants TO auth_service_role USING (true);


--
-- Name: auth_users auth_service_full_access_users; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY auth_service_full_access_users ON public.auth_users TO auth_service_role USING (true);


--
-- Name: auth_user_sessions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.auth_user_sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: auth_user_tenants; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.auth_user_tenants ENABLE ROW LEVEL SECURITY;

--
-- Name: auth_users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.auth_users ENABLE ROW LEVEL SECURITY;

--
-- Name: device_alerts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.device_alerts ENABLE ROW LEVEL SECURITY;

--
-- Name: device_alerts tenant_isolation_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tenant_isolation_policy ON public.device_alerts USING ((tenant_id = (current_setting('app.current_tenant_id'::text))::integer));


--
-- Name: auth_users user_self_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY user_self_access ON public.auth_users FOR SELECT TO graphql_reader USING ((id = (current_setting('auth.user_id'::text))::integer));


--
-- PostgreSQL database dump complete
--

\unrestrict uIKF71osG0k6wYHdN6pcQwmrsSj3BVV3qy72IShNgZsE5lyKVhGmCPyWbTsL1gA

