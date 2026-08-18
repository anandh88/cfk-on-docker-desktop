-- ============================================================================
-- Aggregation Examples
-- ============================================================================
-- These examples demonstrate ksqlDB's aggregation capabilities
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Orders by State (Materialized Table)
-- ----------------------------------------------------------------------------
-- Creates a continuously updated table of order counts and totals by state

CREATE TABLE IF NOT EXISTS orders_by_state AS
SELECT
    address->state AS state,
    COUNT(*) AS order_count,
    SUM(orderunits) AS total_units,
    COUNT_DISTINCT(itemid) AS unique_items
FROM orders_stream
GROUP BY address->state
EMIT CHANGES;

-- ----------------------------------------------------------------------------
-- Orders by Item (Materialized Table)
-- ----------------------------------------------------------------------------
-- Track which items are most popular

CREATE TABLE IF NOT EXISTS orders_by_item AS
SELECT
    itemid,
    COUNT(*) AS order_count,
    SUM(orderunits) AS total_units
FROM orders_stream
GROUP BY itemid
EMIT CHANGES;

-- ----------------------------------------------------------------------------
-- Windowed Aggregation: Orders per Minute
-- ----------------------------------------------------------------------------
-- Tumbling window showing order volume per minute

CREATE TABLE IF NOT EXISTS orders_per_minute AS
SELECT
    itemid,
    WINDOWSTART AS window_start,
    WINDOWEND AS window_end,
    COUNT(*) AS order_count,
    SUM(orderunits) AS total_units
FROM orders_stream
WINDOW TUMBLING (SIZE 1 MINUTE)
GROUP BY itemid
EMIT CHANGES;

-- ----------------------------------------------------------------------------
-- Hopping Window: 5-minute rolling average
-- ----------------------------------------------------------------------------
-- Hopping window for rolling statistics

CREATE TABLE IF NOT EXISTS orders_rolling_5min AS
SELECT
    address->state AS state,
    WINDOWSTART AS window_start,
    WINDOWEND AS window_end,
    COUNT(*) AS order_count,
    AVG(orderunits) AS avg_units
FROM orders_stream
WINDOW HOPPING (SIZE 5 MINUTES, ADVANCE BY 1 MINUTE)
GROUP BY address->state
EMIT CHANGES;
