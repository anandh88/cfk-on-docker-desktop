-- ============================================================================
-- Create Flattened Orders Stream
-- ============================================================================
-- This stream extracts nested address fields into a flat structure
-- Useful for downstream processing and analytics
-- ============================================================================

CREATE STREAM IF NOT EXISTS orders_flat AS
SELECT
    orderid,
    ordertime,
    TIMESTAMPTOSTRING(ordertime, 'yyyy-MM-dd HH:mm:ss') AS order_datetime,
    itemid,
    orderunits,
    address->city AS city,
    address->state AS state,
    address->zipcode AS zipcode
FROM orders_stream
EMIT CHANGES;

-- Verify the stream
DESCRIBE orders_flat;
