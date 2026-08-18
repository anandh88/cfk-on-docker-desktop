# Kafka Connect Connectors

This folder contains sample Kafka Connect connectors that demonstrate a complete data pipeline: generating data, streaming through Kafka, and sinking to a database.

## What is Kafka Connect?

Kafka Connect is a framework for streaming data between Kafka and external systems (databases, file systems, cloud services, etc.) without writing code. It uses **connectors** - pre-built plugins that handle the data movement.

- **Source Connectors**: Pull data INTO Kafka from external systems
- **Sink Connectors**: Push data OUT OF Kafka to external systems

## Where Does This Fit in the Setup?

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        SETUP FLOW & CONNECTOR PLACEMENT                         │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   1. ./scripts/setup.sh                                                         │
│      ├── Deploys CFK Operator                                                   │
│      ├── Deploys KRaft Controllers                                              │
│      ├── Deploys Kafka Brokers                                                  │
│      ├── Deploys Schema Registry                                                │
│      ├── Deploys Kafka Connect  ◄─── Connect is deployed here                   │
│      ├── Deploys ksqlDB                                                         │
│      ├── Deploys REST Proxy                                                     │
│      ├── Deploys Control Center                                                 │
│      └── Deploys Monitoring                                                     │
│                                                                                 │
│   2. MANUALLY DEPLOY CONNECTORS (this folder!)                                  │
│      └── ./connectors/deploy-connectors.sh  ◄─── You run this after setup       │
│                                                                                 │
│   3. (Optional) ./ksqldb/deploy-ksqldb-objects.sh                               │
│      └── Creates streams/tables that read from the Orders topic                 │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Important**: Connectors are NOT deployed automatically by the setup script. You deploy them manually after the platform is running.

## The Data Pipeline

This folder implements the following pipeline:

```
┌──────────────────┐      ┌──────────────────┐      ┌──────────────────┐
│                  │      │                  │      │                  │
│  DATAGEN         │      │  KAFKA TOPIC     │      │  MySQL           │
│  CONNECTOR       │─────►│  "Orders"        │─────►│  DATABASE        │
│  (Source)        │      │                  │      │  (Sink)          │
│                  │      │                  │      │                  │
└──────────────────┘      └──────────────────┘      └──────────────────┘
     Generates               Stores the              Receives the
     fake order              streaming data          data for
     data                                            persistence

     datagen-orders.json                             jdbc-sink-orders.json
```

## Files in This Folder

| File | Type | Purpose |
|------|------|---------|
| `datagen-orders.json` | Source Connector Config | Generates fake order data into the "Orders" topic |
| `jdbc-sink-orders.json` | Sink Connector Config | Writes data from "Orders" topic to MySQL |
| `deploy-connectors.sh` | Shell Script | Deploys both connectors via the Connect REST API |
| `mysql-db-scripts/orders-table.sql` | SQL Script | Creates the MySQL database, table, and user |

## Step-by-Step Guide

### Prerequisites

Before deploying connectors, ensure:

1. ✅ Confluent Platform is running (`./scripts/setup.sh` completed)
2. ✅ Kafka Connect pod is ready:
   ```bash
   kubectl get pods -n confluent -l app=connect
   # Should show: connect-0   1/1   Running
   ```

### Step 1: Start Port-Forward to Kafka Connect

Kafka Connect exposes a REST API on port 8083. You need to forward this port to access it from your machine:

```bash
kubectl port-forward svc/connect -n confluent 8083:8083
```

Keep this terminal open. Open a new terminal for the next steps.

### Step 2: Verify Connect is Ready

```bash
# Check Connect is responding
curl http://localhost:8083/

# List available connector plugins
curl http://localhost:8083/connector-plugins | jq '.[].class'
```

You should see plugins including:
- `io.confluent.kafka.connect.datagen.DatagenConnector`
- `io.confluent.connect.jdbc.JdbcSinkConnector`

### Step 3: Deploy the Datagen Connector

The Datagen connector generates sample data - no external system needed!

```bash
# Deploy using the script
./connectors/deploy-connectors.sh

# OR deploy manually
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d @connectors/datagen-orders.json
```

### Step 4: Verify Data is Flowing

```bash
# Check connector status
curl http://localhost:8083/connectors/datagen-orders/status | jq .

# You should see:
# "state": "RUNNING"
# "tasks": [{"state": "RUNNING", ...}]
```

Check the topic in Control Center (http://localhost:9021) or via CLI:

```bash
kubectl exec -n confluent kafka-0 -- \
  kafka-console-consumer --bootstrap-server kafka:9092 \
  --topic Orders --from-beginning --max-messages 5
```

### Step 5 (Optional): Set Up MySQL for JDBC Sink

If you want to sink data to MySQL:

#### 5a. Install and Start MySQL

```bash
# macOS
brew install mysql
brew services start mysql
```

#### 5b. Create Database and Table

```bash
mysql -u root < connectors/mysql-db-scripts/orders-table.sql
```

This creates:
- Database: `Orders`
- Table: `orders`
- User: `admin` with password `admin`

#### 5c. Deploy JDBC Sink Connector

The deploy script will prompt you, or deploy manually:

```bash
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d @connectors/jdbc-sink-orders.json
```

#### 5d. Verify Data in MySQL

```bash
mysql -u admin -padmin -e "SELECT * FROM Orders.orders LIMIT 5;"
```

## Connector Configuration Explained

### datagen-orders.json

```json
{
  "name": "datagen-orders",           // Unique connector name
  "config": {
    "connector.class": "...DatagenConnector",  // Plugin to use
    "tasks.max": "1",                 // Parallelism (1 task)
    "kafka.topic": "Orders",          // Target topic
    "quickstart": "orders",           // Built-in schema template
    "key.converter": "StringConverter",
    "value.converter": "AvroConverter",
    "value.converter.schema.registry.url": "http://schemaregistry:8081",
    "max.interval": "1000",           // Generate every 1 second
    "iterations": "-1"                // Run forever (-1 = infinite)
  }
}
```

### jdbc-sink-orders.json

```json
{
  "name": "jdbc-sink-orders",
  "config": {
    "connector.class": "...JdbcSinkConnector",
    "topics": "Orders",               // Source topic
    "connection.url": "jdbc:mysql://host.docker.internal:3306/Orders",
    "connection.user": "admin",
    "connection.password": "admin",
    "insert.mode": "upsert",          // Insert or update
    "pk.mode": "record_value",        // Primary key from message
    "pk.fields": "orderid",           // Which field is PK
    "transforms": "flatten",          // Flatten nested structs
    "transforms.flatten.type": "...Flatten$Value"
  }
}
```

## Common Operations

### Check All Connectors

```bash
curl http://localhost:8083/connectors | jq .
```

### Check Connector Status

```bash
curl http://localhost:8083/connectors/datagen-orders/status | jq .
```

### Pause a Connector

```bash
curl -X PUT http://localhost:8083/connectors/datagen-orders/pause
```

### Resume a Connector

```bash
curl -X PUT http://localhost:8083/connectors/datagen-orders/resume
```

### Restart a Connector

```bash
curl -X POST http://localhost:8083/connectors/datagen-orders/restart
```

### Delete a Connector

```bash
curl -X DELETE http://localhost:8083/connectors/datagen-orders
```

### Update Connector Config

```bash
curl -X PUT http://localhost:8083/connectors/datagen-orders/config \
  -H "Content-Type: application/json" \
  -d '{...new config...}'
```

## Troubleshooting

### Connector Shows "FAILED" Status

```bash
# Check the error message
curl http://localhost:8083/connectors/datagen-orders/status | jq '.tasks[0].trace'
```

### JDBC Sink Can't Connect to MySQL

1. Ensure MySQL is running: `brew services list | grep mysql`
2. Ensure `host.docker.internal` resolves (Docker Desktop feature)
3. Check MySQL user permissions:
   ```bash
   mysql -u admin -padmin -e "SELECT 1;"
   ```

### No Data in Topic

1. Check connector is RUNNING (not PAUSED or FAILED)
2. Check Schema Registry is accessible
3. Look at Connect logs:
   ```bash
   kubectl logs connect-0 -n confluent | tail -50
   ```

### Schema Registry Errors

Ensure Schema Registry URL is correct in the connector config:
```
http://schemaregistry.confluent.svc.cluster.local:8081
```

## Data Schema

The Datagen "orders" quickstart generates this schema:

| Field | Type | Description |
|-------|------|-------------|
| `orderid` | INT | Unique order identifier |
| `ordertime` | BIGINT | Order timestamp (epoch ms) |
| `itemid` | STRING | Item being ordered |
| `orderunits` | DOUBLE | Quantity ordered |
| `address.city` | STRING | Customer city |
| `address.state` | STRING | Customer state |
| `address.zipcode` | BIGINT | Customer zip code |

The JDBC Sink uses a `Flatten` transform to convert `address.city` → `address_city` for the database table.

## Next Steps

After deploying connectors:

1. **View in Control Center**: http://localhost:9021 → Connect → Connectors
2. **Process with ksqlDB**: See `../ksqldb/` for stream processing examples
3. **Monitor in Grafana**: Check the Connect dashboard for metrics

## Additional Resources

- [Kafka Connect Documentation](https://docs.confluent.io/platform/current/connect/index.html)
- [Datagen Connector](https://docs.confluent.io/kafka-connectors/datagen/current/index.html)
- [JDBC Connector](https://docs.confluent.io/kafka-connectors/jdbc/current/index.html)
- [Connect REST API](https://docs.confluent.io/platform/current/connect/references/restapi.html)
