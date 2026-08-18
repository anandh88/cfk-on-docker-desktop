# TODO - Future Improvements

A tracker for potential improvements to this Confluent Platform on Kubernetes demo environment.

---

## Quick Wins

- [x] **Add validation script** - Create `scripts/validate.sh` to verify all components are healthy after deployment
- [x] **Add health-check script** - Create `scripts/health-check.sh` for quick status check with colored output
- [ ] **Externalize credentials** - Move hardcoded `admin/admin` credentials to Kubernetes Secrets
- [x] **Enhance alerting rules** - Add Kafka-specific alerts to `monitoring/alertrules.yaml`:
  - [x] Under-replicated partitions
  - [x] Offline partitions
  - [x] Consumer lag threshold
  - [x] Broker count changes
  - [x] Connect task failures

---

## Medium Effort

- [ ] **Parameterize replica counts** - Add environment variable or config to switch between:
  - Lightweight mode (1 replica each) for resource-constrained environments
  - Full mode (3 replicas) for realistic testing
- [ ] **Add more connector examples**:
  - [ ] S3 Sink connector
  - [ ] Elasticsearch Sink connector
  - [ ] Debezium MySQL CDC Source connector
  - [ ] File Stream connectors (for simple testing)
- [x] **Add ksqlDB examples** - Create `ksqldb/` with:
  - [x] Stream creation from Orders topic
  - [x] Aggregation queries (by state, by item, windowed)
  - [x] Push/Pull query examples
  - [x] Deploy script and README
- [x] **Add Kafka CLI cheat sheet** - Quick reference for common `kafka-*` commands

---

## Nice to Have

- [ ] **Backup/restore scripts** - Scripts for backing up and restoring topic data
- [ ] **Load testing setup** - Add performance testing tools (kafka-producer-perf-test examples)

---

## Completed

- [x] Initial repository setup
- [x] Confluent Platform deployment (KRaft mode)
- [x] Prometheus/Grafana monitoring integration
- [x] Grafana dashboards for all components
- [x] Sample Datagen connector
- [x] Sample JDBC Sink connector with MySQL
- [x] Comprehensive README documentation
- [x] Cleanup unused files
- [x] **Kafka REST Proxy Guide** - REST Proxy documentation (`docs/kafka-rest-proxy.md`):
  - [x] REST Proxy architecture and use cases
  - [x] Producing and consuming messages
  - [x] Serialization formats (JSON, Avro, Protobuf, JSON Schema)
  - [x] Schema Registry integration
  - [x] REST Proxy vs Native Kafka clients comparison
- [x] **CFK Configuration Guide** - Detailed documentation of all YAML files (`docs/cfk-configuration-guide.md`):
  - [x] Architecture overview with diagrams
  - [x] Deployment order and dependencies
  - [x] Each component's configuration explained
  - [x] Common configuration patterns
  - [x] Resource planning tables
  - [x] Troubleshooting guide
- [x] **Monitoring Guide** - Comprehensive monitoring documentation (`monitoring/monitoring-guide.md`):
  - [x] Monitoring architecture with flow diagrams
  - [x] Prometheus configuration explained
  - [x] Alert rules documentation
  - [x] Grafana dashboards overview
  - [x] Key metrics to watch
  - [x] PromQL cheat sheet
- [x] **Production Considerations Guide** - What's needed for production (`docs/production-considerations.md`):
  - [x] Supported environments (K8s 1.26-1.34, OpenShift 4.13-4.20)
  - [x] OS and kernel requirements (RHCOS, AWS Linux, Ubuntu, RHEL, Debian)
  - [x] Prerequisites (Helm 3, kubectl, exhaustive RBAC examples with Confluent docs reference)
  - [x] Key planning decisions table with best practices
  - [x] CI/CD pipeline deployment examples (Azure DevOps, GitHub Actions, GitLab CI)
  - [x] Cluster design and node pool architecture
  - [x] Instance type examples (AWS, Azure, GCP, Self-managed/bare metal)
  - [x] Pod placement and multi-zone deployment
  - [x] TLS/SSL configuration examples
  - [x] Authentication methods (SASL, mTLS, OAuth, LDAP, Kerberos)
  - [x] Authorization (ACLs and RBAC)
  - [x] Secrets management best practices
  - [x] High availability configuration
  - [x] Storage (block storage, dynamic vs pre-provisioned, SAN, OpenShift)
  - [x] Storage class immutability warning
  - [x] Official Confluent resource sizing (24 CPU, 64GB RAM for brokers)
  - [x] Networking (ports, external access: LoadBalancer, NodePort, Routes, Ingress)
  - [x] Network policies examples
  - [x] Backup and DR strategies
  - [x] Production checklist

---

## Notes

- This is a **demo/POC environment**, not intended for production use
- Focus is on ease of use and learning, not production hardening
- Contributions and suggestions welcome
