-- SQL Script to create the Orders database and table for Kafka Connect JDBC Sink
-- Run this script on your MySQL instance before starting the JDBC Sink connector

-- Create the database
CREATE DATABASE IF NOT EXISTS Orders;

USE Orders;

-- Create the orders table
-- Schema matches the Datagen "orders" quickstart after Flatten SMT transformation
-- The Flatten SMT converts nested address struct to flat columns with underscore delimiter
CREATE TABLE IF NOT EXISTS orders (
    orderid INT PRIMARY KEY,
    ordertime BIGINT NOT NULL,
    itemid VARCHAR(255) NOT NULL,
    orderunits DOUBLE NOT NULL,
    address_city VARCHAR(255),
    address_state VARCHAR(255),
    address_zipcode BIGINT
);

-- Create an index on ordertime for time-based queries (idempotent: MySQL has no
-- CREATE INDEX IF NOT EXISTS, so check information_schema first)
SET @idx_exists := (
    SELECT COUNT(1) FROM information_schema.statistics
    WHERE table_schema = 'Orders' AND table_name = 'orders' AND index_name = 'idx_orders_ordertime'
);
SET @idx_sql := IF(@idx_exists > 0, 'SELECT 1', 'CREATE INDEX idx_orders_ordertime ON orders(ordertime)');
PREPARE idx_stmt FROM @idx_sql;
EXECUTE idx_stmt;
DEALLOCATE PREPARE idx_stmt;

-- Create admin user if it doesn't exist and grant permissions
CREATE USER IF NOT EXISTS 'admin'@'%' IDENTIFIED BY 'admin';
GRANT SELECT, INSERT, UPDATE, DELETE ON Orders.orders TO 'admin'@'%';
FLUSH PRIVILEGES;

-- Verify table structure
DESCRIBE orders;
