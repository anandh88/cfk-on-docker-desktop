# Kafka REST Proxy Guide

This guide covers using Confluent REST Proxy to interact with Kafka via HTTP.

---

## Table of Contents

1. [What is REST Proxy?](#what-is-rest-proxy)
2. [When to Use REST Proxy](#when-to-use-rest-proxy)
3. [Producing Messages](#producing-messages)
4. [Consuming Messages](#consuming-messages)
5. [Serialization Formats](#serialization-formats)
6. [Schema Registry Integration](#schema-registry-integration)
7. [REST Proxy vs Native Kafka Clients](#rest-proxy-vs-native-kafka-clients)

---

## What is REST Proxy?

Confluent REST Proxy provides a RESTful HTTP interface to Kafka, allowing clients to produce and consume messages without using the native Kafka protocol.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    REST PROXY ARCHITECTURE                                      │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   ┌─────────────┐       ┌─────────────┐       ┌─────────────┐                   │
│   │   Browser   │       │             │       │             │                   │
│   │   (JS App)  │──────►│             │       │             │                   │
│   └─────────────┘       │             │       │             │                   │
│                    HTTP │    REST     │ Kafka │    Kafka    │                   │
│   ┌─────────────┐       │    Proxy    │ Proto │   Brokers   │                   │
│   │   Legacy    │──────►│             │──────►│             │                   │
│   │   System    │       │   :8082     │       │   :9092     │                   │
│   └─────────────┘       │             │       │             │                   │
│                         │             │       │             │                   │
│   ┌─────────────┐       │             │       │             │                   │
│   │   cURL /    │──────►│             │       │             │                   │
│   │   Scripts   │       │             │       │             │                   │
│   └─────────────┘       └──────┬──────┘       └─────────────┘                   │
│                                │                                                │
│                                ▼                                                │
│                         ┌─────────────┐                                         │
│                         │   Schema    │                                         │
│                         │  Registry   │                                         │
│                         │   :8081     │                                         │
│                         └─────────────┘                                         │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## When to Use REST Proxy

### Good Use Cases

| Scenario | Why REST Proxy |
|----------|----------------|
| **Browser/JavaScript apps** | Can't use native Kafka protocol |
| **Legacy systems** | Only support HTTP |
| **Firewall restrictions** | Only port 80/443 allowed |
| **Languages without Kafka clients** | Simple HTTP calls work everywhere |
| **Quick integrations** | No client library needed |
| **Testing/debugging** | Easy to use with cURL |

### When NOT to Use REST Proxy

| Scenario | Why Native Client is Better |
|----------|----------------------------|
| **High-throughput apps (>10K msgs/sec)** | HTTP overhead too high |
| **Low-latency requirements (<10ms)** | Native protocol is faster |
| **Need transactions** | Not supported in REST Proxy |
| **Exactly-once semantics** | Not supported in REST Proxy |
| **Native client available** | Always prefer native when possible |

---

## Producing Messages

### Simple JSON Produce

```bash
curl -X POST http://rest-proxy:8082/topics/my-topic \
  -H "Content-Type: application/vnd.kafka.json.v2+json" \
  -d '{
    "records": [
      {"value": {"name": "test", "count": 1}}
    ]
  }'
```

### Produce with Key

```bash
curl -X POST http://rest-proxy:8082/topics/my-topic \
  -H "Content-Type: application/vnd.kafka.json.v2+json" \
  -d '{
    "records": [
      {
        "key": "user-123",
        "value": {"name": "test", "count": 1}
      }
    ]
  }'
```

### Produce to Specific Partition

```bash
curl -X POST http://rest-proxy:8082/topics/my-topic \
  -H "Content-Type: application/vnd.kafka.json.v2+json" \
  -d '{
    "records": [
      {
        "partition": 0,
        "value": {"name": "test"}
      }
    ]
  }'
```

### Batch Produce

```bash
curl -X POST http://rest-proxy:8082/topics/my-topic \
  -H "Content-Type: application/vnd.kafka.json.v2+json" \
  -d '{
    "records": [
      {"value": {"order_id": 1}},
      {"value": {"order_id": 2}},
      {"value": {"order_id": 3}}
    ]
  }'
```

---

## Consuming Messages

Consuming via REST Proxy requires three steps:

### Step 1: Create Consumer Instance

```bash
curl -X POST http://rest-proxy:8082/consumers/my-group \
  -H "Content-Type: application/vnd.kafka.v2+json" \
  -d '{
    "name": "my-consumer",
    "format": "json",
    "auto.offset.reset": "earliest"
  }'
```

Response:
```json
{
  "instance_id": "my-consumer",
  "base_uri": "http://rest-proxy:8082/consumers/my-group/instances/my-consumer"
}
```

### Step 2: Subscribe to Topics

```bash
curl -X POST http://rest-proxy:8082/consumers/my-group/instances/my-consumer/subscription \
  -H "Content-Type: application/vnd.kafka.v2+json" \
  -d '{"topics": ["my-topic"]}'
```

### Step 3: Consume Messages

```bash
curl -X GET http://rest-proxy:8082/consumers/my-group/instances/my-consumer/records \
  -H "Accept: application/vnd.kafka.json.v2+json"
```

Response:
```json
[
  {
    "topic": "my-topic",
    "key": null,
    "value": {"name": "test", "count": 1},
    "partition": 0,
    "offset": 0
  }
]
```

### Step 4: Commit Offsets (Optional)

```bash
curl -X POST http://rest-proxy:8082/consumers/my-group/instances/my-consumer/offsets \
  -H "Content-Type: application/vnd.kafka.v2+json"
```

### Step 5: Delete Consumer (Cleanup)

```bash
curl -X DELETE http://rest-proxy:8082/consumers/my-group/instances/my-consumer
```

---

## Serialization Formats

REST Proxy supports multiple serialization formats, specified via the `Content-Type` header.

### Supported Formats

| Format | Content-Type Header | Schema Registry |
|--------|---------------------|-----------------|
| **JSON (raw)** | `application/vnd.kafka.json.v2+json` | No |
| **Avro** | `application/vnd.kafka.avro.v2+json` | Yes |
| **Protobuf** | `application/vnd.kafka.protobuf.v2+json` | Yes |
| **JSON Schema** | `application/vnd.kafka.jsonschema.v2+json` | Yes |
| **Binary** | `application/vnd.kafka.binary.v2+json` | No (base64) |

### JSON (No Schema) - Simplest

```bash
curl -X POST http://rest-proxy:8082/topics/orders \
  -H "Content-Type: application/vnd.kafka.json.v2+json" \
  -d '{
    "records": [
      {"value": {"order_id": 123, "item": "widget", "quantity": 5}}
    ]
  }'
```

- No schema validation
- Easy to use but no guarantees on data structure
- Good for testing, not recommended for production

### Binary (Base64 Encoded)

```bash
curl -X POST http://rest-proxy:8082/topics/my-topic \
  -H "Content-Type: application/vnd.kafka.binary.v2+json" \
  -d '{
    "records": [
      {"value": "SGVsbG8gV29ybGQ="}
    ]
  }'
```

- Value is base64 encoded
- Useful for binary data without schema

---

## Schema Registry Integration

For production use, integrate REST Proxy with Schema Registry for schema validation and evolution.

### How It Works

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    REST PROXY SERIALIZATION FLOW                                │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   PRODUCE (with Avro):                                                          │
│                                                                                 │
│   HTTP Client ──► REST Proxy ──► Schema Registry (register/lookup schema)       │
│       │              │                    │                                     │
│       │              │                    ▼                                     │
│       │              │           Schema ID returned                             │
│       │              │                    │                                     │
│       │              ▼                    │                                     │
│       │         Serialize to Avro bytes ◄─┘                                     │
│       │              │                                                          │
│       │              ▼                                                          │
│       │         Produce to Kafka                                                │
│                                                                                 │
│   CONSUME (with Avro):                                                          │
│                                                                                 │
│   Kafka ──► REST Proxy ──► Schema Registry (lookup schema by ID)                │
│                 │                   │                                           │
│                 │                   ▼                                           │
│                 │          Schema returned                                      │
│                 │                   │                                           │
│                 ▼                   │                                           │
│         Deserialize Avro to JSON ◄──┘                                           │
│                 │                                                               │
│                 ▼                                                               │
│         Return JSON to HTTP Client                                              │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Avro - Recommended for Production

**First request (with full schema):**

```bash
curl -X POST http://rest-proxy:8082/topics/orders \
  -H "Content-Type: application/vnd.kafka.avro.v2+json" \
  -d '{
    "value_schema": "{\"type\":\"record\",\"name\":\"Order\",\"fields\":[{\"name\":\"order_id\",\"type\":\"int\"},{\"name\":\"item\",\"type\":\"string\"},{\"name\":\"quantity\",\"type\":\"int\"}]}",
    "records": [
      {"value": {"order_id": 123, "item": "widget", "quantity": 5}}
    ]
  }'
```

Response includes the schema ID:
```json
{
  "offsets": [{"partition": 0, "offset": 0}],
  "key_schema_id": null,
  "value_schema_id": 1
}
```

**Subsequent requests (using schema ID):**

```bash
curl -X POST http://rest-proxy:8082/topics/orders \
  -H "Content-Type: application/vnd.kafka.avro.v2+json" \
  -d '{
    "value_schema_id": 1,
    "records": [
      {"value": {"order_id": 124, "item": "gadget", "quantity": 10}}
    ]
  }'
```

### Avro with Key Schema

```bash
curl -X POST http://rest-proxy:8082/topics/orders \
  -H "Content-Type: application/vnd.kafka.avro.v2+json" \
  -d '{
    "key_schema": "{\"type\":\"string\"}",
    "value_schema_id": 1,
    "records": [
      {
        "key": "order-123",
        "value": {"order_id": 123, "item": "widget", "quantity": 5}
      }
    ]
  }'
```

### Consuming Avro Data

```bash
# Create consumer with Avro format
curl -X POST http://rest-proxy:8082/consumers/my-group \
  -H "Content-Type: application/vnd.kafka.v2+json" \
  -d '{
    "name": "my-consumer",
    "format": "avro",
    "auto.offset.reset": "earliest"
  }'

# Subscribe
curl -X POST http://rest-proxy:8082/consumers/my-group/instances/my-consumer/subscription \
  -H "Content-Type: application/vnd.kafka.v2+json" \
  -d '{"topics": ["orders"]}'

# Consume - returns deserialized JSON
curl -X GET http://rest-proxy:8082/consumers/my-group/instances/my-consumer/records \
  -H "Accept: application/vnd.kafka.avro.v2+json"
```

Response (automatically deserialized from Avro to JSON):
```json
[
  {
    "topic": "orders",
    "partition": 0,
    "offset": 0,
    "key": null,
    "value": {"order_id": 123, "item": "widget", "quantity": 5}
  }
]
```

### Protobuf

```bash
curl -X POST http://rest-proxy:8082/topics/orders \
  -H "Content-Type: application/vnd.kafka.protobuf.v2+json" \
  -d '{
    "value_schema": "syntax=\"proto3\"; message Order { int32 order_id = 1; string item = 2; int32 quantity = 3; }",
    "records": [
      {"value": {"order_id": 123, "item": "widget", "quantity": 5}}
    ]
  }'
```

### JSON Schema

```bash
curl -X POST http://rest-proxy:8082/topics/orders \
  -H "Content-Type: application/vnd.kafka.jsonschema.v2+json" \
  -d '{
    "value_schema": "{\"type\":\"object\",\"properties\":{\"order_id\":{\"type\":\"integer\"},\"item\":{\"type\":\"string\"},\"quantity\":{\"type\":\"integer\"}}}",
    "records": [
      {"value": {"order_id": 123, "item": "widget", "quantity": 5}}
    ]
  }'
```

---

## REST Proxy vs Native Kafka Clients

### Comparison

| Aspect | Native Kafka Client | REST Proxy |
|--------|---------------------|------------|
| **Performance** | High throughput, low latency | Lower (HTTP overhead) |
| **Protocol** | Binary TCP (Kafka protocol) | HTTP/HTTPS |
| **Connection** | Persistent TCP | Request/response |
| **Features** | Full (transactions, exactly-once) | Limited subset |
| **Compression** | Supported (gzip, snappy, lz4, zstd) | Limited |
| **Consumer Groups** | Full support | Supported but stateless |
| **Best for** | High-volume production apps | Simple integrations, non-Kafka clients |

### Interoperability

**Key Point:** Native Kafka clients and REST Proxy clients can interoperate seamlessly:

- Native client produces Avro → REST Proxy consumes (with Schema Registry)
- REST Proxy produces Avro → Native client consumes (with Schema Registry)

As long as both use the same Schema Registry, serialization is handled transparently.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    INTEROPERABILITY                                             │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   ┌─────────────────┐                          ┌─────────────────┐              │
│   │  Java Producer  │                          │  REST Consumer  │              │
│   │  (Native Avro)  │──────┐           ┌───────│  (HTTP + Avro)  │              │
│   └─────────────────┘      │           │       └─────────────────┘              │
│                            ▼           │                                        │
│                      ┌───────────┐     │                                        │
│                      │   Kafka   │─────┘                                        │
│                      │  Brokers  │─────┐                                        │
│                      └───────────┘     │                                        │
│                            ▲           │                                        │
│   ┌─────────────────┐      │           │       ┌─────────────────┐              │
│   │  REST Producer  │──────┘           └───────│ Python Consumer │              │
│   │  (HTTP + Avro)  │                          │  (Native Avro)  │              │
│   └─────────────────┘                          └─────────────────┘              │
│                                                                                 │
│   All clients use the same Schema Registry for schema management                │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Additional Resources

- [Confluent REST Proxy Documentation](https://docs.confluent.io/platform/current/kafka-rest/index.html)
- [REST Proxy API Reference](https://docs.confluent.io/platform/current/kafka-rest/api.html)
- [Schema Registry Documentation](https://docs.confluent.io/platform/current/schema-registry/index.html)
