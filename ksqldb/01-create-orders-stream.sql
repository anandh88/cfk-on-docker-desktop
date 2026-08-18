-- ============================================================================
-- Create Orders Stream from Kafka Topic
-- ============================================================================
-- This stream reads from the 'Orders' topic populated by the Datagen connector.
-- The schema matches the Datagen "orders" quickstart format.
-- ============================================================================

CREATE STREAM IF NOT EXISTS orders_stream (
    orderid VARCHAR KEY,
    ordertime BIGINT,
    itemid VARCHAR,
    orderunits DOUBLE,
    address STRUCT<
        city VARCHAR,
        state VARCHAR,
        zipcode BIGINT
    >
) WITH (
    KAFKA_TOPIC = 'Orders',
    VALUE_FORMAT = 'AVRO'
);

-- Verify the stream was created
DESCRIBE orders_stream;
