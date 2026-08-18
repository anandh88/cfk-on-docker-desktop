-- ============================================================================
-- Example Queries (Push and Pull)
-- ============================================================================
-- Run these interactively in ksqlDB CLI or via REST API
-- ============================================================================

-- ----------------------------------------------------------------------------
-- PUSH QUERIES (Continuous / Streaming)
-- ----------------------------------------------------------------------------
-- Push queries continuously emit results as new data arrives
-- Use Ctrl+C to stop a push query

-- Watch all incoming orders in real-time
SELECT * FROM orders_stream EMIT CHANGES;

-- Watch orders from California only
SELECT * FROM orders_stream
WHERE address->state = 'California'
EMIT CHANGES;

-- Watch high-value orders (more than 5 units)
SELECT
    orderid,
    itemid,
    orderunits,
    address->city AS city,
    address->state AS state
FROM orders_stream
WHERE orderunits > 5
EMIT CHANGES;

-- Watch orders with formatted output
SELECT
    orderid,
    itemid,
    CAST(orderunits AS VARCHAR) + ' units' AS quantity,
    address->city + ', ' + address->state AS location
FROM orders_stream
EMIT CHANGES;

-- ----------------------------------------------------------------------------
-- PULL QUERIES (Point-in-time / Request-Response)
-- ----------------------------------------------------------------------------
-- Pull queries return current state from materialized tables
-- They execute once and return results immediately

-- Get current order count by state (requires orders_by_state table)
SELECT * FROM orders_by_state;

-- Get order stats for a specific state
SELECT * FROM orders_by_state WHERE state = 'California';

-- Get current order count by item
SELECT * FROM orders_by_item;

-- Get stats for a specific item
SELECT * FROM orders_by_item WHERE itemid = 'Item_1';

-- ----------------------------------------------------------------------------
-- EXPLAIN QUERIES
-- ----------------------------------------------------------------------------
-- Use EXPLAIN to see the execution plan

EXPLAIN SELECT * FROM orders_stream EMIT CHANGES;

EXPLAIN SELECT * FROM orders_by_state;
