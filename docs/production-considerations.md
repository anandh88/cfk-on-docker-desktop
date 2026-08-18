# Production Deployment Considerations

This guide outlines the key considerations for deploying Confluent Platform on Kubernetes in a production environment. The configurations in this repository are optimized for learning and development - **they are NOT production-ready**.

---

## Table of Contents

1. [What This Repository Does NOT Include](#what-this-repository-does-not-include)
2. [Supported Environments](#supported-environments)
   - [Kubernetes Version Matrix](#kubernetes-version-matrix)
   - [Operating System Requirements](#operating-system-requirements)
   - [Processor Architecture](#processor-architecture)
3. [Prerequisites](#prerequisites)
   - [Required Tools](#required-tools)
   - [Kubernetes RBAC Configuration](#kubernetes-rbac-configuration)
4. [Cluster Design](#cluster-design)
   - [Node Pool Architecture](#node-pool-architecture)
   - [Pod Placement Strategy](#pod-placement-strategy)
   - [Multi-Zone Deployment](#multi-zone-deployment)
5. [Security](#security)
   - [TLS/SSL Encryption](#tlsssl-encryption)
   - [Authentication](#authentication)
   - [Authorization (ACLs & RBAC)](#authorization-acls--rbac)
   - [Secrets Management](#secrets-management)
6. [High Availability](#high-availability)
7. [Storage](#storage)
   - [Block Storage Requirements](#confluent-platform-block-storage-requirements)
   - [Dynamic vs Pre-Provisioned Volumes](#dynamic-provisioning-vs-pre-provisioned-volumes)
   - [Pod Volume Reattachment](#how-pods-reattach-to-existing-volumes-statefulset-behavior)
   - [SAN Integration](#storage-area-network-san-integration)
   - [Self-Managed K8s vs OpenShift](#self-managed-kubernetes-vs-openshift)
   - [Storage Class Immutability](#storage-class-immutability)
8. [Resource Sizing](#resource-sizing)
   - [Confluent Official Recommendations](#confluent-official-production-recommendations)
   - [Development vs Production Comparison](#development-vs-production-comparison)
9. [Networking](#networking)
   - [Required Ports](#required-ports)
   - [External Access Methods](#external-access-methods)
   - [IPv6 and Dual-Stack](#ipv6-and-dual-stack)
10. [Backup and Disaster Recovery](#backup-and-disaster-recovery)
11. [Monitoring and Alerting](#monitoring-and-alerting)
12. [Operational Considerations](#operational-considerations)
13. [Production Checklist](#production-checklist)

---

## What This Repository Does NOT Include

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    THIS REPO vs PRODUCTION DEPLOYMENT                                   │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│   THIS REPOSITORY (Dev/Learning)          PRODUCTION REQUIRES                           │
│   ══════════════════════════════          ═══════════════════                           │
│                                                                                         │
│   ✗ PLAINTEXT communication               ✓ TLS encryption everywhere                   │
│   ✗ No authentication                     ✓ SASL/mTLS authentication                    │
│   ✗ No authorization                      ✓ ACLs and/or RBAC                            │
│   ✗ Hardcoded credentials                 ✓ Kubernetes Secrets / Vault                  │
│   ✗ replication.factor=1                  ✓ replication.factor=3                        │
│   ✗ min.insync.replicas=1                 ✓ min.insync.replicas=2                       │
│   ✗ Minimal resources                     ✓ Properly sized resources                    │
│   ✗ Default storage class                 ✓ SAN or block, expandable storage            │
│   ✗ No network policies                   ✓ Strict network policies                     │
│   ✗ No backup strategy                    ✓ Regular backups, DR plan                    │
│   ✗ Basic alerting                        ✓ Comprehensive alerting + on-call            │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Supported Environments

> **Reference:** [Confluent for Kubernetes Planning Guide](https://docs.confluent.io/operator/current/co-plan.html)

CFK requires a CNCF-conformant Kubernetes distribution. This section outlines officially supported versions and platforms.

### Kubernetes Version Matrix

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                    CFK 3.1.x COMPATIBILITY MATRIX (as of 2024)                                      │
├─────────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                     │
│   KUBERNETES VERSIONS              OPENSHIFT VERSIONS           CONFLUENT PLATFORM                  │
│   ═══════════════════              ══════════════════           ══════════════════                  │
│                                                                                                     │
│   1.26 - 1.34                      4.13 - 4.20                  7.3.x - 8.1.x                       │
│                                                                                                     │
│   Standard Support End: October 15, 2027                                                            │
│                                                                                                     │
├─────────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                     │
│   SUPPORTED MANAGED KUBERNETES SERVICES:                                                            │
│   ══════════════════════════════════════                                                            │
│                                                                                                     │
│   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐           │
│   │     AWS     │   │    Azure    │   │    GCP      │   │   Red Hat   │   │  Self-Mgd   │           │
│   │     EKS     │   │     AKS     │   │     GKE     │   │  OpenShift  │   │  (Rancher,  │           │
│   │             │   │             │   │             │   │             │   │  kubeadm)   │           │
│   └─────────────┘   └─────────────┘   └─────────────┘   └─────────────┘   └─────────────┘           │
│         ✓                 ✓                 ✓                 ✓                 ✓                   │
│                                                                                                     │
│   Any CNCF-conformant Kubernetes distribution is supported                                          │
│                                                                                                     │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Version Selection Guidance:**

| Environment | Recommendation |
|-------------|----------------|
| **New deployments** | Use latest supported Kubernetes version |
| **Upgrades** | Follow CFK → K8s → CP upgrade order |
| **OpenShift** | Ensure SCC (Security Context Constraints) are configured |
| **Air-gapped** | Verify image availability in private registry |

### Operating System Requirements

CFK 3.1 supports worker nodes running the following Linux kernel versions:

| Operating System | Linux Kernel Version | Notes |
|------------------|---------------------|-------|
| **AWS Linux 2023** | 6.1 | Recommended for EKS |
| **Debian 12** | 6.1 | |
| **Ubuntu 22.04 LTS** | 5.15 | Common choice for self-managed K8s |
| **RHCOS (Red Hat CoreOS)** | 5.14 (OCP 4.13+) | **Recommended for OpenShift** - immutable, container-optimized |
| **RHEL 9** | 5.14 | For OpenShift worker nodes (optional) or standalone |
| **RHEL 8** | 4.18 | Legacy support |

> **Note:** Container-optimized operating systems (e.g., Bottlerocket, Flatcar) based on supported kernels are acceptable alternatives.

**OpenShift Recommendation:**
- **RHCOS** is the default and recommended OS for OpenShift Container Platform
- RHCOS is immutable and managed via the Machine Config Operator (MCO)
- RHEL worker nodes can be added to OpenShift clusters if needed for specific workloads
- RHCOS automatically inherits security updates through OpenShift upgrades

### Processor Architecture

| Architecture | Support Status | Notes |
|--------------|----------------|-------|
| **x86_64 (AMD64)** | Fully Supported | Primary architecture |
| **ARM64 (AArch64)** | Supported | AWS Graviton, Azure Ampere |

---

## Prerequisites

Before deploying Confluent Platform on Kubernetes, ensure the following prerequisites are met. The approach differs based on your deployment method.

### Required Tools

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                           REQUIRED TOOLS                                                │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│   TOOL                VERSION         PURPOSE                                           │
│   ════                ═══════         ═══════                                           │
│                                                                                         │
│   Helm                3.x+            CFK operator installation                         │
│                                       Helm 2 is NOT supported                           │
│                                                                                         │
│   kubectl             Matches K8s     Cluster management, debugging                     │
│                       version         Must be within ±1 minor version                   │
│                                                                                         │
│   kubeconfig          N/A             Valid config for target cluster                   │
│                                       Cluster-admin or appropriate RBAC                 │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

### Deployment Method: Jumpbox / Admin Workstation

If deploying manually from a jumpbox or administration workstation:

**Verification Commands:**

```bash
# Verify Helm version
helm version
# Should show v3.x.x

# Verify kubectl version
kubectl version --client
# Should be within ±1 minor version of cluster

# Verify cluster access
kubectl cluster-info
kubectl auth can-i create deployments --namespace confluent
```

### Deployment Method: CI/CD Pipeline

For enterprise deployments, CFK is typically deployed via CI/CD pipelines. The pipeline must install or have access to the required tools.

#### Azure DevOps Pipeline

```yaml
# azure-pipelines.yml
trigger:
  - main

pool:
  vmImage: 'ubuntu-latest'

steps:
  # Install kubectl
  - task: KubectlInstaller@0
    displayName: 'Install kubectl'
    inputs:
      kubectlVersion: 'latest'

  # Install Helm
  - task: HelmInstaller@1
    displayName: 'Install Helm'
    inputs:
      helmVersionToInstall: 'latest'

  # Configure kubeconfig (AKS example)
  - task: AzureCLI@2
    displayName: 'Get AKS credentials'
    inputs:
      azureSubscription: '$(azureServiceConnection)'
      scriptType: 'bash'
      scriptLocation: 'inlineScript'
      inlineScript: |
        az aks get-credentials --resource-group $(resourceGroup) --name $(aksClusterName)

  # Deploy CFK Operator
  - task: HelmDeploy@0
    displayName: 'Deploy CFK Operator'
    inputs:
      connectionType: 'Kubernetes Service Connection'
      namespace: 'confluent'
      command: 'upgrade'
      chartType: 'Name'
      chartName: 'confluentinc/confluent-for-kubernetes'
      releaseName: 'cfk-operator'
      install: true
      arguments: '--create-namespace'

  # Apply Confluent Platform CRs
  - task: Kubernetes@1
    displayName: 'Deploy Confluent Platform'
    inputs:
      connectionType: 'Kubernetes Service Connection'
      namespace: 'confluent'
      command: 'apply'
      arguments: '-f manifests/'
```

#### GitHub Actions

```yaml
# .github/workflows/deploy-cfk.yml
name: Deploy CFK

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install kubectl
        uses: azure/setup-kubectl@v3

      - name: Install Helm
        uses: azure/setup-helm@v3

      - name: Configure AWS credentials (EKS example)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-1

      - name: Update kubeconfig
        run: aws eks update-kubeconfig --name ${{ vars.EKS_CLUSTER_NAME }}

      - name: Deploy CFK
        run: |
          helm repo add confluentinc https://packages.confluent.io/helm
          helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes \
            --namespace confluent --create-namespace
          kubectl apply -f manifests/
```

#### GitLab CI

```yaml
# .gitlab-ci.yml
deploy-cfk:
  image: alpine/k8s:1.28.0  # Includes kubectl and helm
  stage: deploy
  script:
    - kubectl config use-context $KUBE_CONTEXT
    - helm repo add confluentinc https://packages.confluent.io/helm
    - helm upgrade --install cfk-operator confluentinc/confluent-for-kubernetes
        --namespace confluent --create-namespace
    - kubectl apply -f manifests/
  only:
    - main
```

#### CI/CD Best Practices

| Practice | Description |
|----------|-------------|
| **Service Connections** | Use managed identities or service principals, not user credentials |
| **Secret Management** | Store kubeconfig and credentials in pipeline secrets/vaults |
| **Version Pinning** | Pin tool versions for reproducible deployments |
| **Approval Gates** | Require manual approval for production deployments |
| **Dry Run First** | Use `--dry-run` flag to validate before applying |
| **GitOps** | Consider ArgoCD or Flux for declarative, Git-driven deployments |

### Kubernetes RBAC Configuration

> **Reference:** [Confluent Kubernetes RBAC Examples](https://github.com/confluentinc/confluent-kubernetes-examples/tree/master/security/kubernetes-rbac)

CFK can be deployed in two modes:

| Mode | Scope | Use Case |
|------|-------|----------|
| **Namespaced** | Single namespace | Multi-tenant clusters, restricted access |
| **Cluster-wide** | All namespaces | Central platform team manages all Kafka |

> **Note:** By default, when you deploy CFK via Helm, it automatically creates the required RBAC resources. If your cluster admin pre-creates RBAC resources, use `--set rbac=false` during Helm installation.

#### Cluster-Wide RBAC (Complete Configuration)

```yaml
# Source: https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/security/kubernetes-rbac/cluster-role-rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: confluent-operator
rules:
  # Confluent Platform CRDs - full access
  - apiGroups:
      - platform.confluent.io
    resources:
      - '*'
    verbs:
      - '*'
  # Pod Disruption Budgets
  - apiGroups:
      - policy
    resources:
      - poddisruptionbudgets
    verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
  # OpenShift Routes (only needed on OpenShift)
  - apiGroups:
      - route.openshift.io
    resources:
      - routes
      - routes/custom-host
    verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
  # StatefulSets
  - apiGroups:
      - apps
    resources:
      - statefulsets
      - statefulsets/scale
      - statefulsets/status
    verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
  # Core resources
  - apiGroups:
      - ""
    resources:
      - configmaps
      - events
      - persistentvolumeclaims
      - persistentvolumes
      - secrets
      - secrets/finalizers
      - pods
      - services
    verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
  # Ingresses
  - apiGroups:
      - networking.k8s.io
    resources:
      - ingresses
      - ingresses/status
    verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
  # Namespaces (for cluster-wide deployments)
  - apiGroups:
      - ""
    resources:
      - namespaces
    verbs:
      - get
      - list
      - watch
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: confluent-operator
subjects:
  - kind: ServiceAccount
    name: confluent-for-kubernetes  # Customize as required
    namespace: confluent             # Customize to your namespace
roleRef:
  kind: ClusterRole
  name: confluent-operator
  apiGroup: rbac.authorization.k8s.io
```

#### Namespaced RBAC (Complete Configuration)

For namespace-scoped deployments, use `Role` and `RoleBinding` instead:

```yaml
# Source: https://github.com/confluentinc/confluent-kubernetes-examples/blob/master/security/kubernetes-rbac/namespaced-rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: confluent-operator
  namespace: confluent  # Change to your namespace
rules:
  # Confluent Platform CRDs - full access
  - apiGroups:
      - platform.confluent.io
    resources:
      - '*'
    verbs:
      - '*'
  # Pod Disruption Budgets
  - apiGroups:
      - policy
    resources:
      - poddisruptionbudgets
    verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
  # OpenShift Routes (only needed on OpenShift)
  - apiGroups:
      - route.openshift.io
    resources:
      - routes
      - routes/custom-host
    verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
  # StatefulSets
  - apiGroups:
      - apps
    resources:
      - statefulsets
      - statefulsets/scale
      - statefulsets/status
    verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
  # Deployments (read-only)
  - apiGroups:
      - apps
    resources:
      - deployments
    verbs:
      - get
  # Core resources
  - apiGroups:
      - ""
    resources:
      - configmaps
      - events
      - persistentvolumeclaims
      - persistentvolumes
      - secrets
      - secrets/finalizers
      - pods
      - services
    verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
  # Ingresses
  - apiGroups:
      - networking.k8s.io
    resources:
      - ingresses
      - ingresses/status
    verbs:
      - get
      - list
      - watch
      - create
      - update
      - patch
      - delete
  # Namespaces (read-only for namespaced deployment)
  - apiGroups:
      - ""
    resources:
      - namespaces
    verbs:
      - get
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: confluent-operator
  namespace: confluent  # Change to your namespace
subjects:
  - kind: ServiceAccount
    name: confluent-for-kubernetes  # Customize as required
    namespace: confluent             # Customize to your namespace
roleRef:
  kind: Role
  name: confluent-operator
  apiGroup: rbac.authorization.k8s.io
```

#### Additional ClusterRole for Webhooks (Optional)

If using CFK webhooks for validation, add this ClusterRole:

```yaml
# Required only when webhook is enabled
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: confluent-operator-webhook
rules:
  - apiGroups:
      - admissionregistration.k8s.io
    resources:
      - validatingwebhookconfigurations
    verbs:
      - get
      - update
  - apiGroups:
      - ""
    resources:
      - persistentvolumes
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - ""
    resources:
      - namespaces
    verbs:
      - get
      - list
      - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: confluent-operator-webhook
subjects:
  - kind: ServiceAccount
    name: confluent-for-kubernetes
    namespace: confluent
roleRef:
  kind: ClusterRole
  name: confluent-operator-webhook
  apiGroup: rbac.authorization.k8s.io
```

#### RBAC Summary Table

| API Group | Resources | Purpose |
|-----------|-----------|---------|
| `platform.confluent.io` | `*` | Manage all Confluent Platform CRDs |
| `policy` | `poddisruptionbudgets` | Ensure HA during updates |
| `route.openshift.io` | `routes`, `routes/custom-host` | OpenShift external access |
| `apps` | `statefulsets` | Manage Kafka/KRaft pods |
| `""` (core) | `configmaps`, `secrets`, `pods`, `services`, `pvc`, `pv` | Core K8s resources |
| `networking.k8s.io` | `ingresses` | Ingress-based external access |
| `admissionregistration.k8s.io` | `validatingwebhookconfigurations` | CFK webhooks (optional) |

### Inter-Broker Protocol Version

> **Important:** Specify the Kafka Inter-Broker Protocol (IBP) version that matches your deployment.

The IBP version controls the protocol used between brokers and must be set appropriately for upgrades.

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
spec:
  configOverrides:
    server:
      - inter.broker.protocol.version=3.7  # Match your Kafka version
      - log.message.format.version=3.7
```

| Confluent Platform | Kafka Version | IBP Version |
|--------------------|---------------|-------------|
| 7.9.x | 3.9.x | 3.9 |
| 7.8.x | 3.8.x | 3.8 |
| 7.7.x | 3.7.x | 3.7 |
| 7.6.x | 3.6.x | 3.6 |

### Key Planning Decisions

Before deployment, make these architectural decisions:

| Decision | Options | Considerations | Best Practice |
|----------|---------|----------------|---------------|
| **RBAC Scope** | Namespaced vs Cluster-wide | Multi-tenancy, security boundaries | Namespaced for multi-tenant; Cluster-wide for dedicated platform team |
| **Security** | mTLS, SASL/PLAIN, SASL/SCRAM, LDAP, OAuth | Enterprise integration, complexity | mTLS for service-to-service; LDAP/OAuth for user authentication |
| **TLS** | Auto-generated, Cert-Manager, External CA | Certificate lifecycle management | Cert-Manager or External CA for production; auto-generated for dev only |
| **External Access** | LoadBalancer, NodePort, Routes, Ingress | Cost, complexity, security | LoadBalancer (cloud) or Routes (OpenShift) with TLS passthrough |
| **Logging** | Stdout, EFK/ELK, Splunk, CloudWatch | Compliance, debugging needs | Centralized logging (EFK/Splunk) with retention per compliance requirements |
| **Monitoring** | Prometheus/Grafana, Datadog | Existing infrastructure | Prometheus/Grafana with Confluent-specific dashboards and alerts |

---

## Cluster Design

Proper cluster design is critical for a production Kafka deployment. This section covers node pool architecture, pod placement, and multi-zone considerations.

### Node Pool Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                    RECOMMENDED NODE POOL ARCHITECTURE                                               │
├─────────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                     │
│                              ┌─────────────────────────────────────────┐                            │
│                              │          KUBERNETES CLUSTER             │                            │
│                              └─────────────────────────────────────────┘                            │
│                                                │                                                    │
│                 ┌──────────────────────────────┼──────────────────────────────┐                     │
│                 │                              │                              │                     │
│                 ▼                              ▼                              ▼                     │
│   ┌──────────────────────────┐  ┌──────────────────────────┐  ┌──────────────────────────┐          │
│   │     KAFKA NODE POOL      │  │    KRAFT NODE POOL       │  │   SERVICES NODE POOL     │          │
│   │                          │  │                          │  │                          │          │
│   │  • 3+ nodes (one per AZ) │  │  • 3-5 nodes             │  │  • 2+ nodes              │          │
│   │  • High CPU (24+ cores)  │  │  • Medium CPU (4-8 cores)│  │  • Medium CPU            │          │
│   │  • High Memory (64GB+)   │  │  • Low Memory (4-8GB)    │  │  • Medium Memory         │          │
│   │  • High IOPS SSD         │  │  • Low-latency SSD       │  │  • Standard SSD          │          │
│   │  • Network optimized     │  │                          │  │                          │          │
│   │                          │  │                          │  │  Schema Registry         │          │
│   │  kafka-0  kafka-1  ...   │  │  kraft-0  kraft-1  ...   │  │  Connect                 │          │
│   │                          │  │                          │  │  ksqlDB                  │          │
│   └──────────────────────────┘  └──────────────────────────┘  │  Control Center          │          │
│                                                               │  REST Proxy              │          │
│                                                               └──────────────────────────┘          │
│                                                                                                     │
│   INSTANCE TYPE EXAMPLES:                                                                           │
│   ═══════════════════════                                                                           │
│                                                                                                     │
│   AWS:        m6i.4xlarge / r6i.4xlarge (Kafka), m6i.xlarge (KRaft), m6i.2xlarge (Services)         │
│   Azure:      Standard_D16s_v5 (Kafka), Standard_D4s_v5 (KRaft), Standard_D8s_v5 (Services)         │
│   GCP:        n2-standard-16 (Kafka), n2-standard-4 (KRaft), n2-standard-8 (Services)               │
│   Self-Mgd:   24 vCPU / 64GB RAM / NVMe (Kafka), 8 vCPU / 8GB RAM (KRaft), 16 vCPU / 32GB (Svc)     │
│               (Bare metal, VMware, Proxmox, Nutanix, OpenStack VMs)                                 │
│                                                                                                     │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Confluent Recommended Minimum Cluster Size:**

> **Recommendation:** 10-node cluster minimum for production
> - 6 nodes for KRaft controllers + Kafka brokers
> - 4 nodes for other components

### Pod Placement Strategy

**Critical Rule:** Never place multiple replicas of the same component on a single node.

```yaml
# Anti-affinity to spread Kafka brokers across nodes
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
spec:
  podTemplate:
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
                - key: app.kubernetes.io/name
                  operator: In
                  values:
                    - kafka
            topologyKey: kubernetes.io/hostname
      # Prefer spreading across zones
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                  - key: app.kubernetes.io/name
                    operator: In
                    values:
                      - kafka
              topologyKey: topology.kubernetes.io/zone
```

**Node Selectors and Taints:**

```yaml
# Use node selectors to target specific node pools
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
spec:
  podTemplate:
    nodeSelector:
      workload-type: kafka
    tolerations:
      - key: "dedicated"
        operator: "Equal"
        value: "kafka"
        effect: "NoSchedule"
```

### Multi-Zone Deployment

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    MULTI-ZONE KAFKA DEPLOYMENT                                          │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│      AVAILABILITY ZONE A        AVAILABILITY ZONE B        AVAILABILITY ZONE C          │
│   ┌───────────────────────┐  ┌───────────────────────┐  ┌───────────────────────┐       │
│   │                       │  │                       │  │                       │       │
│   │   ┌───────────────┐   │  │   ┌───────────────┐   │  │   ┌───────────────┐   │       │
│   │   │   kafka-0     │   │  │   │   kafka-1     │   │  │   │   kafka-2     │   │       │
│   │   │   kraft-0     │   │  │   │   kraft-1     │   │  │   │   kraft-2     │   │       │
│   │   └───────────────┘   │  │   └───────────────┘   │  │   └───────────────┘   │       │
│   │                       │  │                       │  │                       │       │
│   │   ┌───────────────┐   │  │   ┌───────────────┐   │  │   ┌───────────────┐   │       │
│   │   │   sr-0        │   │  │   │   sr-1        │   │  │   │   connect-0   │   │       │
│   │   │   connect-1   │   │  │   │   ksqldb-0    │   │  │   │   ksqldb-1    │   │       │
│   │   └───────────────┘   │  │   └───────────────┘   │  │   └───────────────┘   │       │
│   │                       │  │                       │  │                       │       │
│   └───────────────────────┘  └───────────────────────┘  └───────────────────────┘       │
│                                                                                         │
│   BENEFITS:                                                                             │
│   ═════════                                                                             │
│   • Zone failure does not take down the cluster                                         │
│   • Data remains available (RF=3 across 3 zones)                                        │
│   • Automatic leader election on zone failure                                           │
│                                                                                         │
│   CONFIGURATION: Set min.insync.replicas=2 with replication.factor=3                    │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

**Rack Awareness Configuration:**

```yaml
# Enable rack awareness for zone-aware replica placement
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
spec:
  configOverrides:
    server:
      - broker.rack=${ZONE}  # Set from node label
  rackAssignment:
    nodeLabels:
      - topology.kubernetes.io/zone
```

---

## Security

### TLS/SSL Encryption

**Why it matters:** Without TLS, all data (including credentials) travels in plaintext and can be intercepted.

#### What Needs TLS

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                           TLS ENCRYPTION POINTS                                         │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│                              ┌─────────────┐                                            │
│                              │   Clients   │                                            │
│                              └──────┬──────┘                                            │
│                                     │ TLS                                               │
│                                     ▼                                                   │
│   ┌──────────────────────────────────────────────────────────────────────────────┐      │
│   │                          KAFKA CLUSTER                                       │      │
│   │                                                                              │      │
│   │    ┌──────────┐    TLS    ┌──────────┐    TLS    ┌──────────┐                │      │
│   │    │ Broker 0 │◄─────────►│ Broker 1 │◄─────────►│ Broker 2 │                │      │
│   │    └────┬─────┘           └────┬─────┘           └────┬─────┘                │      │
│   │         │                      │                      │                      │      │
│   │         └──────────────────────┼──────────────────────┘                      │      │
│   │                                │ TLS                                         │      │
│   │                                ▼                                             │      │
│   │                    ┌─────────────────────┐                                   │      │
│   │                    │   KRaft Controllers │                                   │      │
│   │                    └─────────────────────┘                                   │      │
│   └──────────────────────────────────────────────────────────────────────────────┘      │
│                                     │                                                   │
│                                     │ TLS                                               │
│                                     ▼                                                   │
│   ┌──────────────────────────────────────────────────────────────────────────────┐      │
│   │  Schema Registry    Connect    ksqlDB    REST Proxy    Control Center        │      │
│   │       │                │          │          │               │               │      │
│   │       └────────────────┴──────────┴──────────┴───────────────┘               │      │
│   │                                TLS between all                               │      │
│   └──────────────────────────────────────────────────────────────────────────────┘      │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

#### TLS Configuration Example

```yaml
# Example: Kafka with TLS
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
metadata:
  name: kafka
  namespace: confluent
spec:
  replicas: 3

  # TLS Configuration
  tls:
    # Auto-generate certificates (for testing)
    autoGeneratedCerts: true

    # OR use your own certificates
    # secretRef: kafka-tls-secret

  listeners:
    internal:
      authentication:
        type: mtls  # Mutual TLS
      tls:
        enabled: true
    external:
      authentication:
        type: mtls
      tls:
        enabled: true
```

#### Certificate Management Options

| Option | Description | Use Case |
|--------|-------------|----------|
| `autoGeneratedCerts: true` | CFK generates self-signed certs | Testing, development |
| `secretRef` | Use pre-created Kubernetes secrets | Production with own PKI |
| Cert-Manager integration | Automatic certificate management | Production with cert-manager |
| External CA | Certificates from enterprise CA | Enterprise environments |

#### Production TLS Checklist

- [ ] Use certificates from a trusted CA (not self-signed)
- [ ] Implement certificate rotation strategy
- [ ] Set appropriate certificate validity periods
- [ ] Store private keys securely (Kubernetes Secrets, Vault)
- [ ] Enable TLS for ALL internal and external communication
- [ ] Configure proper cipher suites (disable weak ciphers)
- [ ] Monitor certificate expiration

---

### Authentication

**Why it matters:** Without authentication, anyone who can reach your Kafka cluster can read/write data.

#### Authentication Methods

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                        AUTHENTICATION METHODS                                            │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   METHOD              DESCRIPTION                      WHEN TO USE                       │
│   ══════              ═══════════                      ═══════════                       │
│                                                                                          │
│   SASL/PLAIN          Username/password                Simple setups, internal           │
│                       (over TLS only!)                 services                          │
│                                                                                          │
│   SASL/SCRAM          Salted Challenge Response        Better than PLAIN,                │
│                       (SHA-256 or SHA-512)             user management needed            │
│                                                                                          │
│   mTLS                Mutual TLS with client           High security,                    │
│                       certificates                     certificate-based identity        │
│                                                                                          │
│   SASL/OAUTHBEARER    OAuth 2.0 / OIDC tokens          Integration with                  │
│                                                        identity providers                │
│                                                                                          │
│   LDAP                LDAP/Active Directory            Enterprise environments           │
│                       integration                      with existing directory           │
│                                                                                          │
│   Kerberos            SASL/GSSAPI with Kerberos        Enterprise with                   │
│                                                        Kerberos infrastructure           │
│                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

#### SASL/SCRAM Configuration Example

```yaml
# Create credentials secret first
apiVersion: v1
kind: Secret
metadata:
  name: kafka-client-credentials
  namespace: confluent
type: Opaque
data:
  plain.txt: |
    username=admin
    password=admin-secret
  # Base64 encoded

---
# Kafka with SASL/SCRAM
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
metadata:
  name: kafka
  namespace: confluent
spec:
  listeners:
    internal:
      authentication:
        type: scram
        jaasConfig:
          secretRef: kafka-server-credentials
      tls:
        enabled: true
    external:
      authentication:
        type: scram
        jaasConfig:
          secretRef: kafka-server-credentials
      tls:
        enabled: true
```

#### mTLS Configuration Example

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
metadata:
  name: kafka
  namespace: confluent
spec:
  listeners:
    internal:
      authentication:
        type: mtls
        principalMappingRules:
          - RULE:^CN=([a-zA-Z0-9]*).*$/$1/
      tls:
        enabled: true
```

#### Production Authentication Checklist

- [ ] Never use PLAINTEXT in production
- [ ] Never use SASL/PLAIN without TLS
- [ ] Implement strong password policies for SASL
- [ ] Use certificate-based auth (mTLS) for service accounts
- [ ] Rotate credentials regularly
- [ ] Audit authentication failures
- [ ] Implement account lockout policies

---

### Authorization (ACLs & RBAC)

**Why it matters:** Authentication tells you WHO the user is. Authorization controls WHAT they can do.

#### ACLs vs RBAC

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                           ACLs vs RBAC                                                  │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│   ACLs (Access Control Lists)              RBAC (Role-Based Access Control)             │
│   ═══════════════════════════              ════════════════════════════════             │
│                                                                                         │
│   • Native Kafka feature                   • Confluent Platform feature                 │
│   • Fine-grained permissions               • Role-based (predefined + custom)           │
│   • Per-principal, per-resource            • Easier to manage at scale                  │
│   • Can become complex at scale            • Centralized management                     │
│                                                                                         │
│   Example ACL:                             Example RBAC:                                │
│   ┌────────────────────────────────┐      ┌─────────────────────────────────┐           │
│   │ Principal: User:alice          │      │ Role: DeveloperRead             │           │
│   │ Permission: ALLOW              │      │ Principals: alice, bob          │           │
│   │ Operation: READ                │      │ Resources: Topic:orders-*       │           │
│   │ Resource: Topic:orders         │      │ Operations: Read, Describe      │           │
│   └────────────────────────────────┘      └─────────────────────────────────┘           │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

#### ACL Configuration

```bash
# Example: Grant read access to a topic
kafka-acls --bootstrap-server kafka:9092 \
  --command-config client.properties \
  --add \
  --allow-principal User:alice \
  --operation Read \
  --operation Describe \
  --topic orders

# Example: Grant write access to a topic
kafka-acls --bootstrap-server kafka:9092 \
  --command-config client.properties \
  --add \
  --allow-principal User:producer-service \
  --operation Write \
  --operation Describe \
  --topic orders

# Example: Grant consumer group access
kafka-acls --bootstrap-server kafka:9092 \
  --command-config client.properties \
  --add \
  --allow-principal User:consumer-service \
  --operation Read \
  --group my-consumer-group
```

#### Common ACL Patterns

| Use Case | Principal | Operations | Resource |
|----------|-----------|------------|----------|
| Producer | Service account | Write, Describe | Topic |
| Consumer | Service account | Read, Describe | Topic + Group |
| Admin | Admin user | All | Cluster |
| Stream processor | Service account | Read, Write | Multiple topics |
| Schema Registry | SR service | Read, Write | `_schemas` topic |
| Connect | Connect service | Read, Write | Multiple topics |

#### RBAC with Confluent Platform

```yaml
# Enable RBAC in Kafka
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
metadata:
  name: kafka
spec:
  authorization:
    type: rbac
    superUsers:
      - User:kafka
      - User:admin
```

#### Production Authorization Checklist

- [ ] Enable authorization (ACLs or RBAC)
- [ ] Follow principle of least privilege
- [ ] Create service accounts for applications (not shared accounts)
- [ ] Document all ACLs/role assignments
- [ ] Regularly audit permissions
- [ ] Implement approval process for permission changes
- [ ] Monitor for unauthorized access attempts

---

### Secrets Management

**Why it matters:** Hardcoded credentials in YAML files can be exposed in version control, logs, or container inspection.

#### Bad Practice (This Repository)

```yaml
# DON'T DO THIS IN PRODUCTION
configOverrides:
  server:
    - connection.user=admin
    - connection.password=admin  # Exposed in plain text!
```

#### Good Practice

```yaml
# Use Kubernetes Secrets
apiVersion: v1
kind: Secret
metadata:
  name: database-credentials
  namespace: confluent
type: Opaque
stringData:
  username: admin
  password: super-secret-password-123

---
# Reference secret in CFK resource
apiVersion: platform.confluent.io/v1beta1
kind: Connect
spec:
  configOverrides:
    server:
      - connection.user=${file:/mnt/secrets/credentials/username}
      - connection.password=${file:/mnt/secrets/credentials/password}
  mountedSecrets:
    - secretRef: database-credentials
      mountPath: /mnt/secrets/credentials
```

#### Better Practice: External Secrets Operator

```yaml
# Using External Secrets Operator with HashiCorp Vault
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: kafka-credentials
  namespace: confluent
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: kafka-credentials
    creationPolicy: Owner
  data:
    - secretKey: password
      remoteRef:
        key: secret/kafka/admin
        property: password
```

#### Production Secrets Checklist

- [ ] Never commit secrets to version control
- [ ] Use Kubernetes Secrets at minimum
- [ ] Consider external secrets management (Vault, AWS Secrets Manager)
- [ ] Implement secret rotation
- [ ] Encrypt secrets at rest (Kubernetes encryption provider)
- [ ] Audit secret access
- [ ] Use different secrets per environment

---

## High Availability

### Replication Configuration

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                        REPLICATION FOR HIGH AVAILABILITY                                │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│   DEVELOPMENT (This Repo)                  PRODUCTION                                   │
│   ═══════════════════════                  ══════════                                   │
│                                                                                         │
│   replication.factor = 1                   replication.factor = 3                       │
│                                                                                         │
│   ┌─────────┐                              ┌─────────┐  ┌─────────┐  ┌─────────┐        │
│   │Broker 0 │                              │Broker 0 │  │Broker 1 │  │Broker 2 │        │
│   │ ┌─────┐ │                              │ ┌─────┐ │  │ ┌─────┐ │  │ ┌─────┐ │        │
│   │ │ P0  │ │ ◄── Single copy              │ │ P0  │ │  │ │ P0  │ │  │ │ P0  │ │        │
│   │ └─────┘ │     of data                  │ │(L)  │ │  │ │(F)  │ │  │ │(F)  │ │        │
│   └─────────┘                              │ └─────┘ │  │ └─────┘ │  │ └─────┘ │        │
│                                            └─────────┘  └─────────┘  └─────────┘        │
│   If Broker 0 fails:                                                                    │
│   ✗ DATA LOST                              ✓ Followers become leaders                   │
│   ✗ Partition offline                      ✓ No data loss                               │
│                                            ✓ Continued availability                     │
│                                                                                         │
│   L = Leader, F = Follower                                                              │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

### Production Replication Settings

```yaml
# kafka.yaml for production
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
spec:
  replicas: 3  # Minimum 3 brokers
  configOverrides:
    server:
      # Internal topics
      - offsets.topic.replication.factor=3
      - transaction.state.log.replication.factor=3
      - transaction.state.log.min.isr=2

      # Confluent topics
      - confluent.license.topic.replication.factor=3
      - confluent.metadata.topic.replication.factor=3
      - confluent.balancer.topic.replication.factor=3

      # Default for new topics
      - default.replication.factor=3
      - min.insync.replicas=2
```

### Component Redundancy

| Component | Dev Replicas | Prod Replicas | Notes |
|-----------|--------------|---------------|-------|
| KRaft Controllers | 3 | 3 or 5 | Always odd number |
| Kafka Brokers | 3 | 3+ | Based on throughput needs |
| Schema Registry | 1 | 2+ | Stateless, easy to scale |
| Kafka Connect | 1 | 2+ | Based on connector count |
| ksqlDB | 1 | 2+ | For query HA |
| REST Proxy | 1 | 2+ | Stateless |
| Control Center | 1 | 1-2 | Usually single instance |

### Pod Disruption Budgets

```yaml
# Prevent too many pods being unavailable during updates
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: kafka-pdb
  namespace: confluent
spec:
  minAvailable: 2  # At least 2 brokers must be available
  selector:
    matchLabels:
      app: kafka
```

### Anti-Affinity Rules

```yaml
# Spread pods across nodes/zones
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
spec:
  podTemplate:
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
                - key: app
                  operator: In
                  values:
                    - kafka
            topologyKey: kubernetes.io/hostname
```

### Production HA Checklist

- [ ] Minimum 3 Kafka brokers
- [ ] Minimum 3 KRaft controllers (or 5 for higher availability)
- [ ] Replication factor of 3 for all topics
- [ ] min.insync.replicas = 2
- [ ] Deploy across multiple availability zones
- [ ] Configure pod anti-affinity
- [ ] Set up Pod Disruption Budgets
- [ ] Test failover scenarios regularly

---

## Storage

Storage is one of the most critical aspects of a Kafka deployment. Kafka is fundamentally a distributed log system that relies heavily on disk I/O performance. Understanding storage options, provisioning methods, and platform-specific considerations is essential for a successful production deployment.

### Confluent Platform Block Storage Requirements

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    CONFLUENT PLATFORM STORAGE REQUIREMENTS                              │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│   REQUIREMENT                 DESCRIPTION                                               │
│   ═══════════                 ═══════════                                               │
│                                                                                         │
│   Block Storage Only          Kafka requires block storage (not NFS/file storage)       │
│                               • Direct block device access needed for performance       │
│                               • File-based storage (NFS, EFS) causes severe degradation │
│                                                                                         │
│   ReadWriteOnce (RWO)         Volumes must support RWO access mode                      │
│                               • Each broker needs exclusive access to its volume        │
│                               • ReadWriteMany (RWX) is NOT required or recommended      │
│                                                                                         │
│   High IOPS                   Kafka is I/O intensive                                    │
│                               • Minimum: 3,000 IOPS per broker                          │
│                               • Recommended: 10,000+ IOPS for high-throughput           │
│                                                                                         │
│   Low Latency                 Sub-millisecond latency preferred                         │
│                               • SSD/NVMe strongly recommended                           │
│                               • Spinning disks (HDD) only for cold storage tiers        │
│                                                                                         │
│   Consistent Performance      Avoid "burstable" storage in production                   │
│                               • Provisioned IOPS preferred over burst credits           │
│                               • Network-attached storage latency should be consistent   │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

**Why Block Storage?**

Kafka's performance depends on sequential disk I/O and OS page cache. Block storage provides:
- Direct device access without network file system overhead
- Consistent latency characteristics
- Better integration with OS-level caching
- Support for disk flush operations critical for durability

**What Happens with File Storage (NFS)?**
- Dramatic throughput reduction (often 10x slower)
- Inconsistent latency causing producer timeouts
- File locking issues
- Cache coherency problems
- **Not supported by Confluent for production use**

---

### Kafka Data Volumes: Event Logs vs Service Logs

Understanding the difference between Kafka's event log storage and service/application logs is important for storage planning.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                    KAFKA STORAGE TYPES                                                               │
├──────────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                      │
│   STORAGE TYPE          DESCRIPTION                    REQUIREMENTS           RECOMMENDATION         │
│   ════════════          ═══════════                    ════════════           ══════════════         │
│                                                                                                      │
│   Event Log             Kafka partition data           High IOPS, Low         Single high-perf       │
│   (data volume)         (messages, offsets)            latency, Large         SSD/NVMe volume        │
│                         /var/lib/kafka/data            capacity               per broker             │
│                                                                                                      │
│   Service Logs          Application logs               Low IOPS,              Stdout (K8s native)    │
│   (log volume)          (server.log, controller.log)   Small capacity         or log rotation        │
│                         /var/log/kafka                                                               │
│                                                                                                      │
└──────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

### Recommended: Single Volume + Stdout Logging

For most production deployments, use a **single volume for event logs** and send **service logs to stdout** (Kubernetes-native logging).

```
┌──────────────────────────────────────────────────-─────────────────────────┐
│                    RECOMMENDED ARCHITECTURE                                │
├────────────────────────────────────────────────────────────────────────────┤
│                                                                            │
│   ┌────────────────────────────────────────────────────────────────────┐   │
│   │                         Kafka Broker Pod                           │   │
│   │                                                                    │   │
│   │   ┌─────────────────────┐        ┌─────────────────────┐           │   │
│   │   │    Event Logs       │        │    Service Logs     │           │   │
│   │   │  (partition data)   │        │  (server.log, etc)  │           │   │
│   │   │                     │        │                     │           │   │
│   │   │         │           │        │         │           │           │   │
│   │   │         ▼           │        │         ▼           │           │   │
│   │   │   ┌─────────┐       │        │      stdout         │           │   │
│   │   │   │   PVC   │       │        │         │           │           │   │
│   │   │   │  (SSD)  │       │        │         ▼           │           │   │
│   │   │   └─────────┘       │        │   K8s Logging       │           │   │
│   │   └─────────────────────┘        │  (Fluentd, Loki)    │           │   │
│   │                                  └─────────────────────┘           │   │
│   └────────────────────────────────────────────────────────────────────┘   │
│                                                                            │
│   BENEFITS:                                                                │
│   • Single PVC per broker (simpler management)                             │
│   • Service logs collected by K8s logging stack (centralized)              │
│   • No additional storage costs for logs                                   │
│   • Standard kubectl logs command works                                    │
│   • CFK default behavior                                                   │
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘
```

#### Configuration: Single Volume + Stdout

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
metadata:
  name: kafka
  namespace: confluent
spec:
  replicas: 3

  # Single volume for event logs (Kafka partition data)
  dataVolumeCapacity: 2Ti
  storageClass:
    name: kafka-data-ssd               # High IOPS SSD storage class

  # Service logs to stdout - collected by K8s logging infrastructure
  configOverrides:
    log4j:
      - log4j.rootLogger=INFO, stdout
      - log4j.appender.stdout=org.apache.log4j.ConsoleAppender
      - log4j.appender.stdout.layout=org.apache.log4j.PatternLayout
      - log4j.appender.stdout.layout.ConversionPattern=[%d] %p %m (%c)%n
```

#### Alternative: Single Volume + Log Rotation

If you prefer file-based service logs on the same volume:

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
metadata:
  name: kafka
  namespace: confluent
spec:
  replicas: 3
  dataVolumeCapacity: 2Ti
  storageClass:
    name: kafka-data-ssd

  # Service logs with rotation (prevents filling the volume)
  configOverrides:
    log4j:
      - log4j.appender.kafkaAppender=org.apache.log4j.RollingFileAppender
      - log4j.appender.kafkaAppender.MaxFileSize=100MB
      - log4j.appender.kafkaAppender.MaxBackupIndex=10
      - log4j.appender.kafkaAppender.File=/var/log/kafka/server.log
```

---

### Dynamic vs Pre-Provisioned PVs

Whether you use single volume or multiple volumes, you need to choose between dynamic and pre-provisioned PVs.

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    DYNAMIC PROVISIONING (Cloud)                                         │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│   CFK Creates PVC  ────►  StorageClass Provisioner  ────►  PV Auto-Created & Bound      │
│                           (EBS, Azure Disk, GCP PD)                                     │
│                                                                                         │
│   No manual PV creation required - fully automated                                      │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    PRE-PROVISIONED PVs (SAN/Enterprise)                                 │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│   Storage Admin      ────►  CFK Creates PVC  ────►  PVC Binds to Existing PV            │
│   Pre-creates PVs           (storageClass:"")       (via labels/selector)               │
│                                                                                         │
│   PVs must exist BEFORE Kafka deployment                                                │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

#### Dynamic Provisioning Example

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
metadata:
  name: kafka
  namespace: confluent
spec:
  replicas: 3
  dataVolumeCapacity: 2Ti
  storageClass:
    name: kafka-data-ssd               # StorageClass creates PV automatically
```

#### Pre-Provisioned PV Example

**Step 1: Storage Admin creates PVs (before Kafka deployment)**

```yaml
# Repeat for each broker: kafka-0, kafka-1, kafka-2
apiVersion: v1
kind: PersistentVolume
metadata:
  name: kafka-data-pv-0
  labels:
    app: kafka
    broker: kafka-0
spec:
  capacity:
    storage: 2Ti
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""                 # Empty = static provisioning
  csi:
    driver: your-san-csi-driver        # e.g., pure-csi, netapp-trident, dell-csi
    volumeHandle: san-lun-kafka-data-0
    fsType: xfs
```

**Step 2: Deploy Kafka (PVCs bind to existing PVs)**

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
metadata:
  name: kafka
  namespace: confluent
spec:
  replicas: 3
  dataVolumeCapacity: 2Ti
  storageClass:
    name: ""                           # Empty = use pre-provisioned PVs
```

#### Comparison: Dynamic vs Pre-Provisioned

| Aspect | Dynamic Provisioning | Pre-Provisioned PVs |
|--------|---------------------|---------------------|
| **PV Creation** | Automatic by StorageClass | Manual by storage admin |
| **Best For** | Cloud (AWS, Azure, GCP) | SAN, enterprise storage |
| **Flexibility** | Easy scaling | Requires pre-planning |
| **Storage Class** | Specify class name | Use empty string `""` |
| **Use Cases** | EBS, Azure Disk, GCP PD | Pure, NetApp, Dell EMC, HPE |

---

### When to Use Separate Volumes for Service Logs (Advanced)

In most cases, single volume + stdout is sufficient. However, separate volumes may be warranted for:

| Scenario | Reason |
|----------|--------|
| **Compliance requirements** | Regulations require separate log retention |
| **Extremely high throughput (>500 MB/s)** | Isolate service log I/O from event log I/O |
| **Cost optimization on expensive SAN** | Use cheaper storage for non-critical logs |

<details>
<summary><strong>Click to expand: Two-Volume Configuration (Advanced)</strong></summary>

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
metadata:
  name: kafka
  namespace: confluent
spec:
  replicas: 3

  # Event logs - high performance SSD
  dataVolumeCapacity: 2Ti
  storageClass:
    name: kafka-data-ssd

  # Service logs - separate standard storage (only if required)
  mountedVolumes:
    volumeClaimTemplates:
      - metadata:
          name: service-logs
        spec:
          accessModes:
            - ReadWriteOnce
          storageClassName: standard
          resources:
            requests:
              storage: 10Gi
    volumeMounts:
      - name: service-logs
        mountPath: /var/log/kafka
```

> **Note:** This adds complexity (2 PVCs per broker). Only use if you have a specific requirement.

</details>

---

### Avoid JBOD Configuration

> **JBOD (Just a Bunch of Disks)** refers to using multiple independent disks per broker without RAID. While Kafka supports JBOD, it introduces significant operational complexity and risks.

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                    WHY AVOID JBOD IN KUBERNETES                                                     │
├─────────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                     │
│   JBOD CONFIGURATION                           SINGLE VOLUME (RECOMMENDED)                          │
│   ══════════════════                           ════════════════════════════                         │
│                                                                                                     │
│   ┌──────────────────────┐                     ┌──────────────────────┐                             │
│   │      Broker Pod      │                     │      Broker Pod      │                             │
│   │                      │                     │                      │                             │
│   │  /data0  /data1 ...  │                     │       /data          │                             │
│   │    │       │         │                     │         │            │                             │
│   │    ▼       ▼         │                     │         ▼            │                             │
│   │  ┌───┐   ┌───┐       │                     │      ┌──────┐        │                             │
│   │  │PV1│   │PV2│  ...  │                     │      │  PV  │        │                             │
│   │  └───┘   └───┘       │                     │      └──────┘        │                             │
│   └──────────────────────┘                     └──────────────────────┘                             │
│                                                                                                     │
│   PROBLEMS WITH JBOD:                          BENEFITS OF SINGLE VOLUME:                           │
│   ───────────────────                          ─────────────────────────                            │
│   ✗ Disk failure = partial data loss           ✓ Simpler failure handling                           │
│   ✗ Uneven partition distribution              ✓ Consistent performance                             │
│   ✗ Complex self-balancing                     ✓ Self-Balancing works optimally                     │
│   ✗ StatefulSet PVC management issues          ✓ Clean StatefulSet semantics                        │
│   ✗ Recovery requires manual intervention      ✓ Pod restart = full recovery                        │
│   ✗ Monitoring complexity                      ✓ Simplified monitoring                              │
│                                                                                                     │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

**JBOD Risks in Detail:**

| Risk | Description |
|------|-------------|
| **Partial Broker Failure** | If one disk fails, only partitions on that disk are affected. Broker stays "healthy" but serves incomplete data. |
| **Self-Balancing Complications** | Confluent Self-Balancing Cluster (SBC) optimizes at broker level, not disk level. Uneven disk usage causes suboptimal balancing. |
| **Partition Reassignment Complexity** | Moving partitions between disks on the same broker requires manual `kafka-reassign-partitions` operations. |
| **Kubernetes PVC Mismatch** | StatefulSets expect predictable PVC-to-pod mapping. Multiple PVCs per pod complicates scaling and recovery. |

**Recommendation:** Use a single, large, high-performance volume per broker.

---

### Self-Balancing Cluster Storage Requirements

Confluent Self-Balancing Cluster (SBC) automatically balances partition distribution across brokers. Proper storage configuration is essential for SBC to work effectively.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                    SELF-BALANCING CLUSTER STORAGE REQUIREMENTS                                       │
├──────────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                      │
│   REQUIREMENT                  WHY IT MATTERS                        RECOMMENDATION                  │
│   ═══════════                  ══════════════                        ══════════════                  │
│                                                                                                      │
│   Uniform Storage Size         SBC balances by broker, not disk.     Same dataVolumeCapacity         │
│                                Unequal sizes = unbalanced cluster.   for all brokers                 │
│                                                                                                      │
│   Consistent IOPS              SBC moves data during rebalancing.    Use provisioned IOPS,           │
│                                Slow disks bottleneck the process.    avoid burstable storage         │
│                                                                                                      │
│   Headroom for Rebalancing     SBC needs free space to move data.    Keep disk usage < 70%           │
│                                Full disks prevent rebalancing.       Alert at 60%, critical 80%      │
│                                                                                                      │
│   Single Volume per Broker     JBOD complicates SBC decisions.       Avoid JBOD configuration        │
│                                SBC sees broker, not individual       Use one large volume            │
│                                disks.                                                                │
│                                                                                                      │
│   Network Bandwidth            Rebalancing moves data over network.  Ensure sufficient network       │
│                                Slow network = slow rebalancing.      bandwidth between brokers       │
│                                                                                                      │
└──────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

**Self-Balancing Configuration Example:**

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
spec:
  replicas: 6
  dataVolumeCapacity: 2Ti   # Same for all brokers
  storageClass:
    name: kafka-ssd-provisioned  # Consistent IOPS

  configOverrides:
    server:
      # Enable Self-Balancing
      - confluent.balancer.enable=true

      # Disk threshold for triggering rebalance (default 80%)
      - confluent.balancer.disk.max.load=0.70

      # Throttle rebalancing to avoid impacting production traffic
      - confluent.balancer.throttle.bytes.per.second=52428800  # 50 MB/s

      # Heal after broker failure
      - confluent.balancer.heal.uneven.load.trigger=ANY_UNEVEN_LOAD
```

**Monitoring Self-Balancing:**

| Metric | Alert Threshold | Action |
|--------|-----------------|--------|
| `kafka.server:type=KafkaServer,name=BrokerState` | Broker offline | Check disk, pod health |
| `confluent.balancer:type=SelfBalancingMetrics,name=DiskUsage` | > 70% | Add storage or brokers |
| `confluent.balancer:type=SelfBalancingMetrics,name=RebalanceInProgress` | Extended duration | Check network, throttle settings |

---

### Dynamic Provisioning vs Pre-Provisioned Volumes

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    DYNAMIC vs PRE-PROVISIONED VOLUMES                                   │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│   DYNAMIC PROVISIONING                     PRE-PROVISIONED VOLUMES                      │
│   ════════════════════                     ═══════════════════════                      │
│                                                                                         │
│   StorageClass + PVC                       PersistentVolume (PV) + PVC                  │
│         │                                         │                                     │
│         ▼                                         ▼                                     │
│   ┌───────────────┐                       ┌───────────────┐                             │
│   │ Pod requests  │                       │ Admin creates │                             │
│   │ storage via   │                       │ PV manually   │                             │
│   │ PVC           │                       │ or via script │                             │
│   └───────┬───────┘                       └───────┬───────┘                             │
│           │                                       │                                     │
│           ▼                                       ▼                                     │
│   ┌───────────────┐                       ┌───────────────┐                             │
│   │ K8s calls     │                       │ PVC binds to  │                             │
│   │ provisioner   │                       │ existing PV   │                             │
│   │ (CSI driver)  │                       │ (by selector  │                             │
│   └───────┬───────┘                       │ or name)      │                             │
│           │                               └───────┬───────┘                             │
│           ▼                                       │                                     │
│   ┌───────────────┐                               │                                     │
│   │ Volume created│                               │                                     │
│   │ automatically │◄──────────────────────────────┘                                     │
│   └───────────────┘                                                                     │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

#### Dynamic Provisioning

**How it works:**
1. Administrator creates a StorageClass defining the provisioner and parameters
2. Pod/StatefulSet requests storage via PersistentVolumeClaim (PVC)
3. Kubernetes calls the CSI driver to create the volume automatically
4. Volume is bound to the PVC and mounted to the pod

**Advantages:**
| Advantage | Description |
|-----------|-------------|
| Automation | Volumes created on-demand without manual intervention |
| Self-service | Developers can request storage without admin involvement |
| Scalability | Easy to scale up - just add more replicas |
| Consistency | All volumes have consistent configuration |
| Cloud-native | Works seamlessly with cloud storage (EBS, Azure Disk, etc.) |

**Disadvantages:**
| Disadvantage | Description |
|--------------|-------------|
| Less control | Limited control over exact volume placement |
| Cloud dependency | Requires cloud provider or CSI driver support |
| Cost | May provision more storage than needed |
| Complexity | CSI driver issues can be hard to debug |

**Example: Dynamic Provisioning Configuration**

```yaml
# 1. StorageClass (created by admin once)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: kafka-storage
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Retain

---
# 2. CFK Kafka resource references the StorageClass
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
metadata:
  name: kafka
spec:
  replicas: 3
  dataVolumeCapacity: 500Gi
  storageClass:
    name: kafka-storage  # References the StorageClass above
```

#### Pre-Provisioned Volumes

**How it works:**
1. Administrator manually creates storage (LUNs, disks, etc.)
2. Administrator creates PersistentVolume (PV) objects in Kubernetes
3. PVCs bind to matching PVs based on labels, capacity, or access modes
4. Pods mount the pre-existing storage

**Advantages:**
| Advantage | Description |
|-----------|-------------|
| Full control | Complete control over storage placement and configuration |
| Existing infrastructure | Use existing SAN, NAS, or local storage |
| Performance tuning | Can optimize individual volumes |
| No CSI dependency | Works without dynamic provisioners |
| Compliance | Easier to meet specific storage compliance requirements |

**Disadvantages:**
| Disadvantage | Description |
|--------------|-------------|
| Manual effort | Requires manual creation and management |
| Scaling complexity | Adding capacity requires admin intervention |
| Error prone | Mismatched PV/PVC configurations cause binding failures |
| Inventory management | Must track which PVs are used/available |

**Example: Pre-Provisioned Volumes Configuration**

```yaml
# 1. PersistentVolume (created by admin for each broker)
apiVersion: v1
kind: PersistentVolume
metadata:
  name: kafka-pv-0
  labels:
    app: kafka
    broker: "0"
spec:
  capacity:
    storage: 500Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""  # Empty for static provisioning
  # For SAN/FC storage
  fc:
    targetWWNs:
      - "50060160c46036df"
    lun: 0
    fsType: xfs
  # OR for iSCSI
  # iscsi:
  #   targetPortal: 10.0.2.15:3260
  #   iqn: iqn.2001-04.com.example:storage.kafka
  #   lun: 0
  #   fsType: xfs

---
# 2. PVC that binds to specific PV
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data0-kafka-0  # CFK naming convention: data0-<kafka-name>-<ordinal>
  namespace: confluent
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 500Gi
  storageClassName: ""  # Must match PV
  selector:
    matchLabels:
      app: kafka
      broker: "0"
```

#### When to Use Which?

| Scenario | Recommendation |
|----------|----------------|
| Cloud environments (AWS, Azure, GCP) | Dynamic provisioning |
| Existing SAN infrastructure | Pre-provisioned |
| Greenfield on-premises | Dynamic with CSI driver (if available) |
| Strict compliance requirements | Pre-provisioned |
| Rapid scaling needs | Dynamic provisioning |
| Local NVMe disks | Pre-provisioned or local volume provisioner |

---

### How Pods Reattach to Existing Volumes (StatefulSet Behavior)

Understanding how Kafka pods reconnect to their data after restarts is critical for operations.

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    STATEFULSET VOLUME REATTACHMENT                                      │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│   STATEFULSET GUARANTEES:                                                               │
│   ══════════════════════                                                                │
│                                                                                         │
│   1. STABLE NETWORK IDENTITY                                                            │
│      • kafka-0 is always kafka-0 (not random like Deployments)                          │
│      • DNS: kafka-0.kafka.confluent.svc.cluster.local                                   │
│                                                                                         │
│   2. STABLE STORAGE                                                                     │
│      • PVC name is deterministic: data0-kafka-0, data0-kafka-1, etc.                    │
│      • Pod always reattaches to the SAME PVC                                            │
│                                                                                         │
│   3. ORDERED OPERATIONS                                                                 │
│      • Pods created in order: kafka-0, then kafka-1, then kafka-2                       │
│      • Pods deleted in reverse order: kafka-2, then kafka-1, then kafka-0               │
│                                                                                         │
│                                                                                         │
│   REATTACHMENT FLOW:                                                                    │
│   ══════════════════                                                                    │
│                                                                                         │
│   Initial State:                     After Pod Restart:                                 │
│   ══════════════                     ══════════════════                                 │
│                                                                                         │
│   ┌──────────┐                       ┌──────────┐                                       │
│   │ kafka-0  │───────┐               │ kafka-0  │───────┐                               │
│   └──────────┘       │               │  (new)   │       │                               │
│                      ▼               └──────────┘       ▼                               │
│   ┌──────────────────────┐           ┌──────────────────────┐                           │
│   │ PVC: data0-kafka-0   │           │ PVC: data0-kafka-0   │  ◄── Same PVC!            │
│   │ Status: Bound        │           │ Status: Bound        │                           │
│   └──────────┬───────────┘           └──────────┬───────────┘                           │
│              │                                  │                                       │
│              ▼                                  ▼                                       │
│   ┌──────────────────────┐           ┌──────────────────────┐                           │
│   │ PV: pvc-abc123       │           │ PV: pvc-abc123       │  ◄── Same data!           │
│   │ Data: 500GB          │           │ Data: 500GB          │                           │
│   └──────────────────────┘           └──────────────────────┘                           │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

#### What Determines Pod-to-Volume Binding?

| Factor | Description |
|--------|-------------|
| **Pod ordinal** | StatefulSet assigns ordinal (0, 1, 2...) to each pod |
| **PVC naming** | PVC name follows pattern: `<volumeClaimTemplate-name>-<statefulset-name>-<ordinal>` |
| **PVC persistence** | PVCs are NOT deleted when pods are deleted (by default) |
| **PV binding** | Once PVC binds to PV, binding persists until PVC deleted |

#### CFK PVC Naming Convention

```
data0-kafka-0
│     │     │
│     │     └── Ordinal (pod number)
│     └── StatefulSet name (from CFK Kafka CR)
└── Volume claim template name (CFK uses "data0")
```

#### Critical Considerations

**1. PVC Retention on StatefulSet Deletion**

```yaml
# CFK Kafka resource - PVCs persist by default
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
metadata:
  name: kafka
spec:
  replicas: 3
  # PVCs will remain after Kafka CR is deleted
  # This is controlled by StatefulSet's persistentVolumeClaimRetentionPolicy (K8s 1.23+)
```

**2. Manual PVC Cleanup (when needed)**

```bash
# List PVCs for Kafka
kubectl get pvc -n confluent -l app=kafka

# Delete PVCs (CAUTION: Data loss!)
kubectl delete pvc data0-kafka-0 data0-kafka-1 data0-kafka-2 -n confluent
```

**3. Recovering Data After Accidental Pod Deletion**

When a pod is deleted (but not the PVC):
1. StatefulSet controller recreates the pod with same ordinal
2. Pod mounts the existing PVC
3. All data is preserved
4. Broker rejoins cluster with existing data

**4. Node Failure Scenarios**

| Scenario | Volume Type | Behavior |
|----------|-------------|----------|
| Node failure | Cloud block storage | Volume detaches, reattaches to new node |
| Node failure | Local storage | Data unavailable until node recovers |
| Node cordoned | Any | Pod rescheduled, volume follows |
| Node deleted | Cloud block storage | Volume reattaches to pod on new node |
| Node deleted | Local storage | Data LOST (unless replicated) |

---

### Storage Area Network (SAN) Integration

SAN provides enterprise-grade shared block storage for Kubernetes, commonly used in on-premises deployments.

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    SAN ARCHITECTURE WITH KUBERNETES                                     │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│   │                         KUBERNETES CLUSTER                                      │   │
│   │                                                                                 │   │
│   │   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐                        │   │
│   │   │   Worker     │   │   Worker     │   │   Worker     │                        │   │
│   │   │   Node 1     │   │   Node 2     │   │   Node 3     │                        │   │
│   │   │              │   │              │   │              │                        │   │
│   │   │ ┌──────────┐ │   │ ┌──────────┐ │   │ ┌──────────┐ │                        │   │
│   │   │ │ kafka-0  │ │   │ │ kafka-1  │ │   │ │ kafka-2  │ │                        │   │
│   │   │ └────┬─────┘ │   │ └────┬─────┘ │   │ └────┬─────┘ │                        │   │
│   │   │      │       │   │      │       │   │      │       │                        │   │
│   │   │   ┌──┴──┐    │   │   ┌──┴──┐    │   │   ┌──┴──┐    │                        │   │
│   │   │   │ HBA │    │   │   │ HBA │    │   │   │ HBA │    │                        │   │
│   │   │   └──┬──┘    │   │   └──┬──┘    │   │   └──┬──┘    │                        │   │
│   │   └──────┼───────┘   └──────┼───────┘   └──────┼───────┘                        │   │
│   │          │                  │                  │                                │   │
│   └──────────┼──────────────────┼──────────────────┼────────────────────────────────┘   │
│              │                  │                  │                                    │
│              │    FIBRE CHANNEL / iSCSI FABRIC     │                                    │
│              │                  │                  │                                    │
│   ┌──────────┴──────────────────┴──────────────────┴────────────────────────────────┐   │
│   │                                                                                 │   │
│   │                         SAN STORAGE ARRAY                                       │   │
│   │   ┌─────────────────────────────────────────────────────────────────────────┐   │   │
│   │   │                         STORAGE POOL                                    │   │   │
│   │   │   ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐   │   │   │
│   │   │   │  LUN 0  │   │  LUN 1  │   │  LUN 2  │   │  LUN 3  │   │  LUN 4  │   │   │   │
│   │   │   │ kafka-0 │   │ kafka-1 │   │ kafka-2 │   │   SR    │   │ Connect │   │   │   │
│   │   │   │  500GB  │   │  500GB  │   │  500GB  │   │  50GB   │   │  100GB  │   │   │   │
│   │   │   └─────────┘   └─────────┘   └─────────┘   └─────────┘   └─────────┘   │   │   │
│   │   └─────────────────────────────────────────────────────────────────────────┘   │   │
│   │                                                                                 │   │
│   │   Features: Snapshots, Replication, Thin Provisioning, QoS, Encryption          │   │
│   │                                                                                 │   │
│   └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘

   HBA = Host Bus Adapter (Fibre Channel) or iSCSI Initiator
   LUN = Logical Unit Number (a carved-out portion of storage)
```

#### SAN Protocols

| Protocol | Description | Use Case |
|----------|-------------|----------|
| **Fibre Channel (FC)** | High-speed, low-latency, dedicated fabric | Enterprise, highest performance |
| **iSCSI** | Block storage over IP network | Cost-effective, easier setup |
| **FC over Ethernet (FCoE)** | FC protocol over Ethernet | Converged infrastructure |
| **NVMe-oF** | NVMe over Fabric (FC, RDMA, TCP) | Highest performance, newer deployments |

#### SAN Integration Methods

**1. Direct FC/iSCSI PersistentVolumes**

```yaml
# Fibre Channel PV
apiVersion: v1
kind: PersistentVolume
metadata:
  name: kafka-pv-fc-0
spec:
  capacity:
    storage: 500Gi
  accessModes:
    - ReadWriteOnce
  fc:
    targetWWNs:
      - "50060160c46036df"
      - "50060160c46036e0"  # Multipath
    lun: 0
    fsType: xfs
    readOnly: false
  persistentVolumeReclaimPolicy: Retain

---
# iSCSI PV
apiVersion: v1
kind: PersistentVolume
metadata:
  name: kafka-pv-iscsi-0
spec:
  capacity:
    storage: 500Gi
  accessModes:
    - ReadWriteOnce
  iscsi:
    targetPortal: 10.0.2.15:3260
    iqn: iqn.2001-04.com.example:storage.kafka0
    lun: 0
    fsType: xfs
    readOnly: false
  persistentVolumeReclaimPolicy: Retain
```

**2. CSI Drivers for SAN (Recommended)**

Most SAN vendors provide CSI drivers for dynamic provisioning:

| Vendor | CSI Driver | Features |
|--------|------------|----------|
| Dell EMC PowerStore | dell-csi-powerstore | Snapshots, clones, replication |
| NetApp ONTAP | trident | Snapshots, clones, QoS |
| Pure Storage | pure-csi | Snapshots, clones |
| HPE | hpe-csi-driver | Snapshots, clones |
| IBM Spectrum | ibm-spectrum-scale-csi | Snapshots, tiering |

**Example: NetApp Trident CSI**

```yaml
# TridentBackendConfig for SAN
apiVersion: trident.netapp.io/v1
kind: TridentBackendConfig
metadata:
  name: ontap-san
  namespace: trident
spec:
  version: 1
  storageDriverName: ontap-san
  managementLIF: 10.0.0.1
  dataLIF: 10.0.0.2
  svm: kafka_svm
  credentials:
    name: ontap-credentials

---
# StorageClass using Trident
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: kafka-san-storage
provisioner: csi.trident.netapp.io
parameters:
  backendType: ontap-san
  fsType: xfs
allowVolumeExpansion: true
reclaimPolicy: Retain
```

---

### Self-Managed Kubernetes vs OpenShift

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    STORAGE: SELF-MANAGED K8S vs OPENSHIFT                               │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│   SELF-MANAGED KUBERNETES                  OPENSHIFT                                    │
│   (Rancher, kubeadm, kOps, etc.)           (OpenShift Container Platform)               │
│   ═══════════════════════════              ══════════════════════════════               │
│                                                                                         │
│   Storage Responsibility:                  Storage Responsibility:                      │
│   ───────────────────────                  ───────────────────────                      │
│   • You install/manage CSI drivers         • Many CSI drivers pre-certified             │
│   • You configure storage classes          • ODF (OpenShift Data Foundation) option     │
│   • You handle multipath setup             • OperatorHub for easy CSI installation      │
│   • Full flexibility, full responsibility  • Guided setup, tested configurations        │
│                                                                                         │
│   Common Storage Solutions:                Common Storage Solutions:                    │
│   ────────────────────────                 ────────────────────────                     │
│   • Longhorn (Rancher native)              • ODF (Ceph-based, included option)          │
│   • Rook-Ceph                              • Partner CSI drivers (certified)            │
│   • Vendor CSI drivers                     • External SAN with CSI                      │
│   • Local Path Provisioner                 • Local Storage Operator                     │
│   • OpenEBS                                                                             │
│                                                                                         │
│   Security Context:                        Security Context:                            │
│   ─────────────────                        ─────────────────                            │
│   • Default: permissive                    • Default: restricted (SCCs)                 │
│   • Configure as needed                    • Must grant appropriate SCC                 │
│                                            • anyuid, privileged may be needed           │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

#### Self-Managed Kubernetes (Rancher, kubeadm, etc.)

**Storage Setup Steps:**

1. **Install CSI Driver**
```bash
# Example: Install Longhorn (Rancher)
helm repo add longhorn https://charts.longhorn.io
helm install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace

# Example: Install vendor CSI (Dell EMC)
helm install dell-csi-powerstore dell/dell-csi-powerstore -n dell-csi --create-namespace
```

2. **Configure Multipath (for SAN)**
```bash
# On each worker node
yum install device-mapper-multipath -y
mpathconf --enable
systemctl enable multipathd
systemctl start multipathd
```

3. **Create StorageClass**
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: kafka-storage
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: driver.longhorn.io  # or your CSI driver
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "2880"
  fsType: xfs
reclaimPolicy: Retain
allowVolumeExpansion: true
```

**Rancher-Specific Considerations:**

| Feature | Implementation |
|---------|----------------|
| Longhorn | Native integration, easy setup via Rancher UI |
| Storage monitoring | Built into Rancher dashboard |
| Cluster templates | Can include storage class definitions |
| Multi-cluster | Consistent storage config across clusters |

#### OpenShift Storage

**1. OpenShift Data Foundation (ODF)**

ODF provides integrated Ceph-based storage:

```yaml
# ODF StorageCluster (simplified)
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: openshift-storage
spec:
  storageDeviceSets:
    - name: ocs-deviceset
      count: 3
      dataPVCTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 500Gi
          storageClassName: localblock
```

**2. Security Context Constraints (SCC)**

OpenShift has stricter security by default. Confluent pods may need elevated permissions:

```yaml
# Grant anyuid SCC to Confluent service accounts
oc adm policy add-scc-to-user anyuid -z default -n confluent
oc adm policy add-scc-to-user anyuid -z kafka -n confluent
oc adm policy add-scc-to-user anyuid -z connect -n confluent

# Or create custom SCC for Confluent
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: confluent-scc
allowPrivilegedContainer: false
runAsUser:
  type: MustRunAsRange
  uidRangeMin: 1000
  uidRangeMax: 65535
fsGroup:
  type: MustRunAs
  ranges:
    - min: 1000
      max: 65535
volumes:
  - configMap
  - emptyDir
  - persistentVolumeClaim
  - secret
```

**3. OpenShift CSI Driver Installation**

```bash
# Via OperatorHub (recommended)
# 1. Navigate to OperatorHub in OpenShift Console
# 2. Search for vendor CSI driver
# 3. Install operator
# 4. Create driver instance

# Or via CLI
oc apply -f https://vendor.example.com/csi-operator.yaml
```

#### Platform Comparison for Kafka Storage

| Aspect | Self-Managed K8s | OpenShift |
|--------|------------------|-----------|
| **CSI Driver Install** | Manual Helm/YAML | OperatorHub or manual |
| **Default Storage** | None | ODF available |
| **Security** | Flexible | SCC must be configured |
| **Multipath** | Manual setup on nodes | Manual or MachineConfig |
| **Monitoring** | Deploy separately | Integrated (if ODF used) |
| **Support** | Community or vendor | Red Hat + vendor |
| **Complexity** | Higher | Lower (more integrated) |

---

### Storage Sizing

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                           STORAGE SIZING FORMULA                                        │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│   Required Storage = Daily_Data × Retention_Days × Replication_Factor × 1.2             │
│                                                                                         │
│   Example:                                                                              │
│   ════════                                                                              │
│   • Daily data ingestion: 100 GB                                                        │
│   • Retention period: 7 days                                                            │
│   • Replication factor: 3                                                               │
│   • Safety margin: 20%                                                                  │
│                                                                                         │
│   Storage per broker = (100 GB × 7 days × 3 replicas × 1.2) / 3 brokers                 │
│   Storage per broker = 840 GB                                                           │
│                                                                                         │
│   Recommendation: Round up to 1 TB per broker                                           │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

### Storage Class Selection Examples

```yaml
# AWS EBS (gp3)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: kafka-storage-aws
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Retain

---
# Azure Managed Disk (Premium SSD)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: kafka-storage-azure
provisioner: disk.csi.azure.com
parameters:
  skuName: Premium_LRS
  cachingMode: None  # Important for Kafka
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Retain

---
# GCP Persistent Disk (SSD)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: kafka-storage-gcp
provisioner: pd.csi.storage.gke.io
parameters:
  type: pd-ssd
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Retain

---
# On-premises with Longhorn
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: kafka-storage-longhorn
provisioner: driver.longhorn.io
parameters:
  numberOfReplicas: "2"
  dataLocality: "best-effort"
  staleReplicaTimeout: "2880"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Retain
```

### Production Storage Configuration

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
spec:
  dataVolumeCapacity: 1Ti  # Use appropriate unit (Gi, Ti)
  storageClass:
    name: kafka-storage

  # For tiered storage (Confluent Platform)
  configOverrides:
    server:
      - confluent.tier.enable=true
      - confluent.tier.backend=S3
      - confluent.tier.s3.bucket=my-kafka-tiered-storage
      - confluent.tier.s3.region=us-east-1
```

### Storage Class Immutability

> **⚠️ CRITICAL WARNING:** You **cannot** change the storage class used to create Persistent Volume Claims for Confluent components after initial deployment.

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                    STORAGE CLASS IMMUTABILITY                                           │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│   ┌─────────────────────────────────────────────────────────────────────────────────┐   │
│   │                                                                                 │   │
│   │   INITIAL DEPLOYMENT               AFTER DEPLOYMENT                             │   │
│   │   ══════════════════               ════════════════                             │   │
│   │                                                                                 │   │
│   │   Kafka CR references              StorageClass is                              │   │
│   │   StorageClass: "gp2"              LOCKED to "gp2"                              │   │
│   │          │                                │                                     │   │
│   │          ▼                                │                                     │   │
│   │   PVCs created with                       ▼                                     │   │
│   │   storageClassName: gp2            ┌──────────────────┐                         │   │
│   │          │                         │ Cannot change to │                         │   │
│   │          ▼                         │ "gp3" or any     │                         │   │
│   │   PVs bound to PVCs                │ other class!     │                         │   │
│   │                                    └──────────────────┘                         │   │
│   │                                                                                 │   │
│   └─────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                         │
│   TO CHANGE STORAGE CLASS, YOU MUST:                                                    │
│   ══════════════════════════════════                                                    │
│   1. Backup all data (MirrorMaker, volume snapshots)                                    │
│   2. Delete the Confluent CR (Kafka, Connect, etc.)                                     │
│   3. Delete the PVCs                                                                    │
│   4. Recreate with new StorageClass                                                     │
│   5. Restore data                                                                       │
│                                                                                         │
│   ⚠️  This is a DESTRUCTIVE operation - plan storage class carefully BEFORE deployment  │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

**Best Practice:** Choose your production storage class carefully before initial deployment. Consider:
- IOPS requirements
- Encryption needs
- Future expansion requirements
- Cost implications

### Production Storage Checklist

- [ ] Use block storage (NOT NFS/file storage)
- [ ] Use SSD-backed storage (gp3, io2 on AWS; Premium SSD on Azure)
- [ ] Ensure minimum 3,000 IOPS per broker (10,000+ recommended)
- [ ] Enable volume expansion for future growth
- [ ] Use `reclaimPolicy: Retain` to prevent accidental data loss
- [ ] Configure `volumeBindingMode: WaitForFirstConsumer` for topology awareness
- [ ] Set up multipath for SAN environments
- [ ] Test failover scenarios (node failure, volume detach/reattach)
- [ ] Monitor disk usage and set alerts at 70%, 80%, 90%
- [ ] Document volume-to-broker mapping for troubleshooting
- [ ] Plan for storage growth (add monitoring)
- [ ] Consider tiered storage for cost optimization (long retention)
- [ ] **Choose storage class carefully before deployment (immutable)**

---

## Resource Sizing

> **Reference:** [Confluent for Kubernetes Planning Guide](https://docs.confluent.io/operator/current/co-plan.html)

### Confluent Official Production Recommendations

These are Confluent's **official minimum recommendations** for production deployments. Your actual requirements may be higher based on throughput, partition count, and use case.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                    CONFLUENT OFFICIAL PRODUCTION RESOURCE SIZING                                         │
├──────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                          │
│   COMPONENT           PODS     CPU/pod    MEMORY/pod    STORAGE/pod     NOTES                            │
│   ═════════           ════     ═══════    ══════════    ═══════════     ═════                            │
│                                                                                                          │
│   KRaft Controllers   5        5          4 GB          64 GB (SSD)     Always odd number (3 or 5)       │
│                                                                                                          │
│   Kafka Brokers       3+       24         64 GB         12 TB           Scale based on throughput        │
│                                                                                                          │
│   Schema Registry     2        2          4 GB          N/A             Stateless, scale horizontally    │
│                                                                                                          │
│   Kafka Connect       2+       12         24 GB         50 GB           Scale based on connector count   │
│                                                                                                          │
│   Control Center      1        4          8 GB          200 GB (SSD)    Usually single instance          │
│                                                                                                          │
│   ksqlDB              2        4          32 GB         100 GB (SSD)    Scale based on query complexity  │
│                                                                                                          │
├──────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                          │
│   ⚠️  IMPORTANT: These are PRODUCTION minimums. This demo repo uses much smaller values for              │
│      development purposes only. Do NOT use demo values for production workloads.                         │
│                                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Development vs Production Comparison

| Component | This Repo (Dev) | Production Minimum | Factor |
|-----------|-----------------|-------------------|--------|
| **Kafka Broker CPU** | 500m | 24 cores | 48x |
| **Kafka Broker Memory** | 1 GB | 64 GB | 64x |
| **Kafka Broker Storage** | 5 GB | 12 TB | 2400x |
| **KRaft Controllers** | 3 | 5 | 1.7x |
| **KRaft CPU** | 200m | 5 cores | 25x |
| **KRaft Memory** | 512 MB | 4 GB | 8x |
| **Connect CPU** | 500m | 12 cores | 24x |
| **Connect Memory** | 1 GB | 24 GB | 24x |

> **Why such large resources for Kafka brokers?**
> - 64 GB memory allows significant OS page cache for better read performance
> - 24 cores handle high partition counts and connection volumes
> - 12 TB storage supports multi-day retention with replication factor 3

### Production Kafka Configuration Example

```yaml
# Production-grade Kafka configuration
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
metadata:
  name: kafka
  namespace: confluent
spec:
  replicas: 3  # Minimum 3, add more for higher throughput
  image:
    application: confluentinc/cp-server:7.9.0
    init: confluentinc/confluent-init-container:2.10.0

  # Production storage sizing
  dataVolumeCapacity: 12Ti
  storageClass:
    name: kafka-storage-ssd

  # Production resource allocation
  podTemplate:
    resources:
      requests:
        cpu: "20"
        memory: 56Gi  # Leave room for OS page cache
      limits:
        cpu: "24"
        memory: 64Gi

    # Anti-affinity for HA
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app.kubernetes.io/name: kafka
            topologyKey: kubernetes.io/hostname

    # Target dedicated Kafka node pool
    nodeSelector:
      workload-type: kafka
    tolerations:
      - key: "dedicated"
        operator: "Equal"
        value: "kafka"
        effect: "NoSchedule"

  # Production JVM settings
  configOverrides:
    jvm:
      - -Xms30g
      - -Xmx30g
      - -XX:+UseG1GC
      - -XX:MaxGCPauseMillis=20
      - -XX:InitiatingHeapOccupancyPercent=35
      - -XX:+ExplicitGCInvokesConcurrent
      - -XX:G1HeapRegionSize=16M
      - -Djava.awt.headless=true
    server:
      # Replication for HA
      - default.replication.factor=3
      - min.insync.replicas=2
      - offsets.topic.replication.factor=3
      - transaction.state.log.replication.factor=3
      - transaction.state.log.min.isr=2
      - confluent.balancer.topic.replication.factor=3

      # Performance tuning
      - num.io.threads=16
      - num.network.threads=8
      - num.replica.fetchers=4
      - socket.receive.buffer.bytes=102400
      - socket.send.buffer.bytes=102400
      - socket.request.max.bytes=104857600
```

### Production KRaft Controller Configuration

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: KRaftController
metadata:
  name: kraftcontroller
  namespace: confluent
spec:
  replicas: 5  # 5 for higher availability
  image:
    application: confluentinc/cp-server:7.9.0
    init: confluentinc/confluent-init-container:2.10.0

  dataVolumeCapacity: 64Gi
  storageClass:
    name: kafka-storage-ssd

  podTemplate:
    resources:
      requests:
        cpu: "4"
        memory: 3Gi
      limits:
        cpu: "5"
        memory: 4Gi

    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app.kubernetes.io/name: kraftcontroller
            topologyKey: kubernetes.io/hostname
```

### When to Exceed Minimum Recommendations

| Scenario | What to Increase |
|----------|------------------|
| **High throughput (>100 MB/s)** | More Kafka brokers, more CPU, faster storage |
| **Many partitions (>10K)** | More Kafka memory, more broker CPU |
| **Many connections (>10K)** | More network threads, more CPU |
| **Long retention (>7 days)** | More storage, consider tiered storage |
| **Complex ksqlDB queries** | More ksqlDB memory and CPU |
| **Many connectors (>50)** | More Connect workers |
| **Heavy schema usage** | More Schema Registry replicas |

### Production Resource Checklist

- [ ] Resources meet or exceed Confluent's production minimums
- [ ] Dedicated node pools for Kafka brokers
- [ ] JVM heap sized to 40-50% of container memory (rest for page cache)
- [ ] G1GC configured for Kafka brokers
- [ ] Anti-affinity rules prevent broker co-location
- [ ] Resource requests and limits are set
- [ ] Node taints/tolerations isolate workloads
- [ ] Vertical Pod Autoscaler (VPA) considered for dynamic sizing
- [ ] Resource usage monitored and alerts configured

---

## Networking

### Required Ports

Understanding Confluent Platform port requirements is essential for network planning and firewall configuration.

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                    CONFLUENT PLATFORM DEFAULT PORTS                                                      │
├──────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                          │
│   COMPONENT           PORT        PROTOCOL    PURPOSE                                                    │
│   ═════════           ════        ════════    ═══════                                                    │
│                                                                                                          │
│   Kafka               9092        TCP         External client connections                                │
│                       9071        TCP         Internal (inter-broker) communication                      │
│                       9072        TCP         Replication listener                                       │
│                                                                                                          │
│   KRaft Controller    9073        TCP         Controller quorum communication                            │
│                       9071        TCP         Internal communication                                     │
│                                                                                                          │
│   Schema Registry     8081        TCP         HTTP API                                                   │
│                       9081        TCP         Internal/HTTPS (when TLS enabled)                          │
│                                                                                                          │
│   Kafka Connect       8083        TCP         REST API                                                   │
│                       9083        TCP         Internal/HTTPS (when TLS enabled)                          │
│                                                                                                          │
│   ksqlDB              8088        TCP         HTTP API                                                   │
│                       9088        TCP         Internal/HTTPS (when TLS enabled)                          │
│                                                                                                          │
│   Control Center      9021        TCP         Web UI                                                     │
│                                                                                                          │
│   REST Proxy          8082        TCP         HTTP API                                                   │
│                       9082        TCP         Internal/HTTPS (when TLS enabled)                          │
│                                                                                                          │
│   MDS (RBAC)          8090        TCP         Metadata Service HTTP                                      │
│                       9090        TCP         Metadata Service HTTPS                                     │
│                                                                                                          │
│   JMX Metrics         7203        TCP         JMX Exporter (Prometheus)                                  │
│                                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### External Access Methods

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                    EXTERNAL ACCESS OPTIONS                                                               │
├──────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                          │
│   METHOD              PROTOCOL    BEST FOR                 KAFKA SUPPORT    NOTES                        │
│   ══════              ════════    ════════                 ═════════════    ═════                        │
│                                                                                                          │
│   LoadBalancer        L4 (TCP)    Cloud environments       ✓ Full           One LB per broker or         │
│   (TLS Passthrough)               (AWS, Azure, GCP)                         shared with SNI routing      │
│                                                                                                          │
│   NodePort            TCP         On-premises, simple      ✓ Full           Port range 30000-32767       │
│                                   external access                           One port per broker          │
│                                                                                                          │
│   OpenShift Routes    L4 (TLS     OpenShift clusters       ✓ Full           TLS passthrough required     │
│   (Passthrough)       Passthru)                                             Route per broker             │
│                                                                                                          │
│   Static Host-Based   L4 (TCP)    External LB/proxy        ✓ Full           Use with F5, HAProxy,        │
│   Routing                         you manage                                NGINX Stream, etc.           │
│                                                                                                          │
│   Ingress             L7 (HTTP)   REST APIs only           ✗ Not for        SR, Connect, ksqlDB,         │
│                                                            Kafka            Control Center only          │
│                                                                                                          │
│   Host Network        TCP         High performance,        ✓ Full           Security implications,       │
│                                   bare metal                                port conflicts possible      │
│                                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────┘

   ⚠️  Kafka requires Layer 4 (TCP) access due to its binary protocol. HTTP/L7 Ingress won't work for Kafka.
```

**LoadBalancer Example (Cloud):**

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
spec:
  listeners:
    external:
      externalAccess:
        type: loadBalancer
        loadBalancer:
          domain: kafka.example.com
          # Each broker gets: kafka-0.kafka.example.com, kafka-1.kafka.example.com, etc.
      authentication:
        type: mtls
      tls:
        enabled: true
```

**NodePort Example (On-premises):**

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
spec:
  listeners:
    external:
      externalAccess:
        type: nodePort
        nodePort:
          host: kafka.internal.example.com
          nodePortOffset: 30092  # Brokers get 30092, 30093, 30094...
      authentication:
        type: mtls
      tls:
        enabled: true
```

**OpenShift Route Example (Passthrough TLS):**

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
spec:
  listeners:
    external:
      externalAccess:
        type: route
        route:
          domain: apps.ocp-cluster.example.com
          # Creates routes: kafka-0.apps.ocp-cluster.example.com, etc.
          wildcardPolicy: None  # or Subdomain for wildcard certs
      authentication:
        type: mtls
      tls:
        enabled: true  # Required - Routes use TLS passthrough for Kafka
```

> **OpenShift Route Notes:**
> - Routes must use **TLS passthrough** for Kafka (not edge or reencrypt termination)
> - Each broker requires its own route for direct broker access
> - Ensure the OpenShift Router (HAProxy) is configured for TCP/TLS passthrough
> - Wildcard DNS or individual DNS entries needed for broker routes
> - For HTTP-based components (Schema Registry, Connect, Control Center), edge termination works fine

**Static Host-Based Routing Example:**

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
spec:
  listeners:
    external:
      externalAccess:
        type: staticForHostBasedRouting
        staticForHostBasedRouting:
          domain: kafka.example.com
          port: 443
      authentication:
        type: mtls
      tls:
        enabled: true
```

### IPv6 and Dual-Stack

CFK supports IPv4, IPv6, and dual-stack deployments.

| Configuration | Requirements | Use Case |
|---------------|--------------|----------|
| **IPv4 Only** | Default | Most deployments |
| **IPv6 Only** | Java 11+, KRaft mode | IPv6-native environments |
| **Dual-Stack** | Java 11+, KRaft mode, K8s 1.23+ | Transitional environments |

> **Note:** IPv6 and dual-stack require KRaft mode.

### Network Policies

```yaml
# Allow only required traffic to Kafka
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kafka-network-policy
  namespace: confluent
spec:
  podSelector:
    matchLabels:
      app: kafka
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # From other Kafka brokers
    - from:
        - podSelector:
            matchLabels:
              app: kafka
      ports:
        - port: 9071
    # From KRaft controllers
    - from:
        - podSelector:
            matchLabels:
              app: kraftcontroller
      ports:
        - port: 9071
    # From allowed clients
    - from:
        - namespaceSelector:
            matchLabels:
              kafka-client: "true"
      ports:
        - port: 9092
  egress:
    # To other Kafka brokers
    - to:
        - podSelector:
            matchLabels:
              app: kafka
    # To KRaft controllers
    - to:
        - podSelector:
            matchLabels:
              app: kraftcontroller
    # DNS
    - to:
        - namespaceSelector: {}
      ports:
        - port: 53
          protocol: UDP
```

### Production Network Checklist

- [ ] Implement network policies to restrict traffic
- [ ] Use private subnets/VPCs for Kafka brokers
- [ ] Expose only necessary ports through firewall
- [ ] Use Layer 4 load balancers for Kafka (TLS passthrough)
- [ ] Configure proper DNS with wildcard or per-broker entries
- [ ] Enable TLS for all external access
- [ ] Consider service mesh (Istio, Linkerd) for mTLS
- [ ] Document all port mappings and access paths
- [ ] Test failover of load balancers and DNS
- [ ] Configure health checks on load balancers

---

## Backup and Disaster Recovery

### What to Back Up

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                           BACKUP STRATEGY                                               │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│   COMPONENT              WHAT TO BACKUP                HOW                              │
│   ═════════              ══════════════                ═══                              │
│                                                                                         │
│   Kafka Data             Topic data                    MirrorMaker 2, Cluster Linking   │
│                                                                                         │
│   Kafka Configs          Topic configs, ACLs           kafka-configs export             │
│                                                        kubectl get kafka -o yaml        │
│                                                                                         │
│   Schema Registry        All schemas                   SR API export                    │
│                          _schemas topic                Cluster Linking                  │
│                                                                                         │
│   Connect                Connector configs             Connect REST API                 │
│                          Offsets (connect-offsets)     Topic backup                     │
│                                                                                         │
│   ksqlDB                 Stream/Table definitions      ksqlDB API                       │
│                          State stores                  Topic backup                     │
│                                                                                         │
│   Kubernetes             CFK CRDs                      kubectl get -o yaml              │
│                          Secrets, ConfigMaps           Velero, native backup            │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

### MirrorMaker 2 for Replication

```yaml
# Replicate data to DR cluster
apiVersion: platform.confluent.io/v1beta1
kind: KafkaMirrorMaker
metadata:
  name: mm2
  namespace: confluent
spec:
  replicas: 2
  sourceCluster:
    bootstrapEndpoint: source-kafka:9092
  targetCluster:
    bootstrapEndpoint: target-kafka:9092
  mirrors:
    - sourcePrefix: ""
      targetPrefix: "source."
      topicsPattern: ".*"
```

### Disaster Recovery Checklist

- [ ] Document RTO (Recovery Time Objective)
- [ ] Document RPO (Recovery Point Objective)
- [ ] Set up cross-region/DC replication
- [ ] Regularly test DR procedures
- [ ] Back up Kubernetes configurations
- [ ] Back up Schema Registry schemas
- [ ] Document manual failover procedures
- [ ] Automate where possible

---

## Monitoring and Alerting

### Production Alert Thresholds

| Alert | Warning | Critical | Rationale |
|-------|---------|----------|-----------|
| Broker Down | - | Immediate | Data availability |
| Under-replicated Partitions | >0 for 1m | >0 for 5m | Replication health |
| Offline Partitions | - | >0 | Data unavailable |
| Consumer Lag | >10K for 5m | >100K for 5m | Processing delays |
| Disk Usage | >70% | >85% | Prevent out of space |
| CPU Usage | >70% for 10m | >90% for 5m | Performance impact |
| JVM Heap | >80% | >90% | GC pressure |
| Request Latency (p99) | >500ms | >2000ms | Client impact |

### Additional Production Alerts

```yaml
# Add these to alertrules.yaml for production
- alert: KafkaDiskUsageHigh
  expr: (kubelet_volume_stats_used_bytes{persistentvolumeclaim=~".*kafka.*"} / kubelet_volume_stats_capacity_bytes{persistentvolumeclaim=~".*kafka.*"}) > 0.7
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Kafka disk usage above 70%"
    description: "Disk usage is {{ $value | humanizePercentage }}"

- alert: KafkaNetworkThroughputHigh
  expr: rate(kafka_server_brokertopicmetrics_bytesinpersec_count[5m]) > 100000000  # 100MB/s
  for: 10m
  labels:
    severity: warning
  annotations:
    summary: "High network throughput on Kafka"
    description: "Ingress rate is {{ $value | humanize }}B/s"
```

### Production Monitoring Checklist

- [ ] Configure alerts for all critical metrics
- [ ] Set up PagerDuty/OpsGenie integration
- [ ] Create runbooks for each alert
- [ ] Implement on-call rotation
- [ ] Set up dashboards for key metrics
- [ ] Enable audit logging
- [ ] Retain logs for compliance period
- [ ] Monitor certificate expiration

---

## Operational Considerations

### Upgrade Strategy

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                           UPGRADE STRATEGY                                              │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                         │
│   1. Pre-upgrade                                                                        │
│      • Review release notes                                                             │
│      • Test in staging environment                                                      │
│      • Back up configurations                                                           │
│      • Notify stakeholders                                                              │
│                                                                                         │
│   2. Upgrade order (for minor versions)                                                 │
│      a. CFK Operator                                                                    │
│      b. KRaft Controllers (one at a time)                                               │
│      c. Kafka Brokers (rolling update)                                                  │
│      d. Other components                                                                │
│                                                                                         │
│   3. Post-upgrade                                                                       │
│      • Verify all pods healthy                                                          │
│      • Run validation tests                                                             │
│      • Monitor for errors                                                               │
│                                                                                         │
│   ⚠️  For major version upgrades, consult Confluent documentation                       │
│                                                                                         │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

### Log Management

```yaml
# Configure log retention and format
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
spec:
  configOverrides:
    log4j:
      - log4j.rootLogger=INFO, stdout
      - log4j.appender.stdout=org.apache.log4j.ConsoleAppender
      - log4j.appender.stdout.layout=org.apache.log4j.PatternLayout
      - log4j.appender.stdout.layout.ConversionPattern=[%d] %p %m (%c)%n
```

### Capacity Planning

- Monitor growth trends weekly
- Plan for 6-12 months ahead
- Have procedures for scaling:
  - Adding brokers
  - Increasing storage
  - Adding partitions

---

## Production Checklist

### Security

- [ ] TLS enabled for all communication
- [ ] Authentication configured (SASL or mTLS)
- [ ] Authorization enabled (ACLs or RBAC)
- [ ] Secrets managed securely (not in plain text)
- [ ] Network policies implemented
- [ ] Audit logging enabled
- [ ] Regular security assessments

### High Availability

- [ ] 3+ Kafka brokers
- [ ] 3+ KRaft controllers
- [ ] replication.factor=3
- [ ] min.insync.replicas=2
- [ ] Multi-AZ deployment
- [ ] Pod anti-affinity configured
- [ ] PodDisruptionBudgets set

### Storage

- [ ] SSD-backed storage class
- [ ] Appropriate capacity provisioned
- [ ] Volume expansion enabled
- [ ] Retain reclaim policy
- [ ] Tiered storage considered

### Operations

- [ ] Monitoring and alerting configured
- [ ] On-call rotation established
- [ ] Runbooks documented
- [ ] Backup strategy implemented
- [ ] DR plan tested
- [ ] Upgrade procedures documented
- [ ] Capacity planning in place

### Compliance (if applicable)

- [ ] Data encryption at rest
- [ ] Log retention policies
- [ ] Access audit trails
- [ ] Data residency requirements met
- [ ] PII handling procedures

---

## Resources

### Confluent Documentation

- [CFK Security](https://docs.confluent.io/operator/current/co-security.html)
- [CFK Production Recommendations](https://docs.confluent.io/operator/current/co-plan.html)
- [Kafka Security](https://docs.confluent.io/platform/current/security/index.html)

### Kubernetes Documentation

- [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Secrets Management](https://kubernetes.io/docs/concepts/configuration/secret/)

---

*Remember: Security is not a one-time setup. It requires continuous monitoring, regular updates, and periodic reviews.*
