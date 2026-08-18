# Kafka CLI Cheat Sheet

Quick reference for common Kafka CLI commands in this Kubernetes environment.

## Accessing the CLI

All commands should be run from inside a Kafka broker pod:

```bash
# Interactive shell
kubectl exec -it kafka-0 -n confluent -- bash

# Or prefix each command with:
kubectl exec -n confluent kafka-0 --
```

## Bootstrap Server

For all commands, use:
```
--bootstrap-server kafka:9092
```

Or from outside the cluster (with port-forward):
```
--bootstrap-server localhost:9092
```

---

## Topics

### List Topics

```bash
kafka-topics --bootstrap-server kafka:9092 --list
```

### Create Topic

```bash
kafka-topics --bootstrap-server kafka:9092 \
  --create \
  --topic my-topic \
  --partitions 3 \
  --replication-factor 3
```

### Describe Topic

```bash
kafka-topics --bootstrap-server kafka:9092 \
  --describe \
  --topic my-topic
```

### Delete Topic

```bash
kafka-topics --bootstrap-server kafka:9092 \
  --delete \
  --topic my-topic
```

### Alter Topic (Add Partitions)

```bash
kafka-topics --bootstrap-server kafka:9092 \
  --alter \
  --topic my-topic \
  --partitions 6
```

### List Topics with Details

```bash
kafka-topics --bootstrap-server kafka:9092 \
  --describe \
  --under-replicated-partitions
```

---

## Producing Messages

### Simple Producer

```bash
kafka-console-producer --bootstrap-server kafka:9092 \
  --topic my-topic
```

### Producer with Key

```bash
kafka-console-producer --bootstrap-server kafka:9092 \
  --topic my-topic \
  --property "parse.key=true" \
  --property "key.separator=:"
```

Then type: `key1:value1`

### Producer with Headers

```bash
kafka-console-producer --bootstrap-server kafka:9092 \
  --topic my-topic \
  --property "parse.headers=true" \
  --property "headers.delimiter=\t" \
  --property "headers.separator=," \
  --property "headers.key.separator=:"
```

---

## Consuming Messages

### Simple Consumer (from beginning)

```bash
kafka-console-consumer --bootstrap-server kafka:9092 \
  --topic my-topic \
  --from-beginning
```

### Consumer with Key and Timestamp

```bash
kafka-console-consumer --bootstrap-server kafka:9092 \
  --topic my-topic \
  --from-beginning \
  --property print.key=true \
  --property print.timestamp=true \
  --property key.separator=" | "
```

### Consumer with Partition and Offset

```bash
kafka-console-consumer --bootstrap-server kafka:9092 \
  --topic my-topic \
  --partition 0 \
  --offset 100
```

### Consumer with Group

```bash
kafka-console-consumer --bootstrap-server kafka:9092 \
  --topic my-topic \
  --group my-consumer-group
```

### Consume Limited Messages

```bash
kafka-console-consumer --bootstrap-server kafka:9092 \
  --topic my-topic \
  --from-beginning \
  --max-messages 10
```

---

## Consumer Groups

### List Consumer Groups

```bash
kafka-consumer-groups --bootstrap-server kafka:9092 --list
```

### Describe Consumer Group

```bash
kafka-consumer-groups --bootstrap-server kafka:9092 \
  --describe \
  --group my-consumer-group
```

### Describe All Groups

```bash
kafka-consumer-groups --bootstrap-server kafka:9092 \
  --describe \
  --all-groups
```

### Reset Offsets (Dry Run)

```bash
kafka-consumer-groups --bootstrap-server kafka:9092 \
  --group my-consumer-group \
  --topic my-topic \
  --reset-offsets \
  --to-earliest \
  --dry-run
```

### Reset Offsets (Execute)

```bash
kafka-consumer-groups --bootstrap-server kafka:9092 \
  --group my-consumer-group \
  --topic my-topic \
  --reset-offsets \
  --to-earliest \
  --execute
```

### Reset to Specific Offset

```bash
kafka-consumer-groups --bootstrap-server kafka:9092 \
  --group my-consumer-group \
  --topic my-topic \
  --reset-offsets \
  --to-offset 1000 \
  --execute
```

### Reset to Timestamp

```bash
kafka-consumer-groups --bootstrap-server kafka:9092 \
  --group my-consumer-group \
  --topic my-topic \
  --reset-offsets \
  --to-datetime 2024-01-01T00:00:00.000 \
  --execute
```

### Delete Consumer Group

```bash
kafka-consumer-groups --bootstrap-server kafka:9092 \
  --delete \
  --group my-consumer-group
```

---

## Cluster Information

### Cluster ID

```bash
kafka-cluster cluster-id --bootstrap-server kafka:9092
```

### Broker API Versions

```bash
kafka-broker-api-versions --bootstrap-server kafka:9092
```

### Describe Log Dirs

```bash
kafka-log-dirs --bootstrap-server kafka:9092 \
  --describe \
  --broker-list 0,1,2
```

---

## ACLs (Access Control)

### List ACLs

```bash
kafka-acls --bootstrap-server kafka:9092 --list
```

### Add ACL

```bash
kafka-acls --bootstrap-server kafka:9092 \
  --add \
  --allow-principal User:alice \
  --operation Read \
  --topic my-topic
```

### Remove ACL

```bash
kafka-acls --bootstrap-server kafka:9092 \
  --remove \
  --allow-principal User:alice \
  --operation Read \
  --topic my-topic
```

---

## Configuration

### Describe Topic Config

```bash
kafka-configs --bootstrap-server kafka:9092 \
  --describe \
  --entity-type topics \
  --entity-name my-topic
```

### Alter Topic Config

```bash
kafka-configs --bootstrap-server kafka:9092 \
  --alter \
  --entity-type topics \
  --entity-name my-topic \
  --add-config retention.ms=86400000
```

### Delete Topic Config

```bash
kafka-configs --bootstrap-server kafka:9092 \
  --alter \
  --entity-type topics \
  --entity-name my-topic \
  --delete-config retention.ms
```

### Describe Broker Config

```bash
kafka-configs --bootstrap-server kafka:9092 \
  --describe \
  --entity-type brokers \
  --entity-name 0
```

---

## Performance Testing

### Producer Performance Test

```bash
kafka-producer-perf-test \
  --topic perf-test \
  --num-records 100000 \
  --record-size 1024 \
  --throughput -1 \
  --producer-props bootstrap.servers=kafka:9092
```

### Consumer Performance Test

```bash
kafka-consumer-perf-test \
  --bootstrap-server kafka:9092 \
  --topic perf-test \
  --messages 100000 \
  --threads 1
```

---

## Schema Registry (with Avro)

### Consume Avro Messages

```bash
kafka-avro-console-consumer \
  --bootstrap-server kafka:9092 \
  --topic Orders \
  --property schema.registry.url=http://schemaregistry:8081 \
  --from-beginning \
  --max-messages 5
```

### Produce Avro Messages

```bash
kafka-avro-console-producer \
  --bootstrap-server kafka:9092 \
  --topic my-avro-topic \
  --property schema.registry.url=http://schemaregistry:8081 \
  --property value.schema='{"type":"record","name":"Test","fields":[{"name":"field1","type":"string"}]}'
```

---

## Useful One-Liners

### Count Messages in Topic

```bash
kafka-run-class kafka.tools.GetOffsetShell \
  --broker-list kafka:9092 \
  --topic my-topic \
  --time -1 | awk -F: '{sum += $3} END {print sum}'
```

### Get Latest Offset per Partition

```bash
kafka-run-class kafka.tools.GetOffsetShell \
  --broker-list kafka:9092 \
  --topic my-topic \
  --time -1
```

### Get Earliest Offset per Partition

```bash
kafka-run-class kafka.tools.GetOffsetShell \
  --broker-list kafka:9092 \
  --topic my-topic \
  --time -2
```

### Check Under-Replicated Partitions

```bash
kafka-topics --bootstrap-server kafka:9092 \
  --describe \
  --under-replicated-partitions
```

### Check Unavailable Partitions

```bash
kafka-topics --bootstrap-server kafka:9092 \
  --describe \
  --unavailable-partitions
```

---

## Quick Reference Table

| Task | Command |
|------|---------|
| List topics | `kafka-topics --list` |
| Create topic | `kafka-topics --create --topic X` |
| Describe topic | `kafka-topics --describe --topic X` |
| Delete topic | `kafka-topics --delete --topic X` |
| Produce | `kafka-console-producer --topic X` |
| Consume | `kafka-console-consumer --topic X --from-beginning` |
| List groups | `kafka-consumer-groups --list` |
| Describe group | `kafka-consumer-groups --describe --group X` |
| Reset offsets | `kafka-consumer-groups --reset-offsets --to-earliest` |
| Cluster ID | `kafka-cluster cluster-id` |

---

## Environment-Specific Commands

### From Local Machine (with port-forward)

```bash
# Start port-forward
kubectl port-forward svc/kafka -n confluent 9092:9092 &

# Then use localhost
kafka-topics --bootstrap-server localhost:9092 --list
```

### Inside Kubernetes Cluster

```bash
# From any pod in the cluster
kafka-topics --bootstrap-server kafka.confluent.svc.cluster.local:9092 --list
```
