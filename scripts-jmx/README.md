# JMX Manifest Scripts

These scripts provide a parallel setup/teardown flow that uses the JMX manifest copy set with Prometheus rules removed.

Default manifest source:
- `manifests-jmx-no-prometheus-20260617-135249/`

## Files

- `setup.sh` - Deploy CFK components using manifests from `MANIFESTS_DIR` and then run monitoring deploy.
- `destroy.sh` - Teardown CFK components using manifests from `MANIFESTS_DIR` and cleanup namespace resources.
- `validate-jmx.sh` - Validate Datadog JMXFetch and `confluent_platform` check status after deployment.

## Usage

```bash
# From repository root
chmod +x scripts-jmx/*.sh

# Deploy using default JMX manifest folder
./scripts-jmx/setup.sh

# Deploy using a different manifest folder
MANIFESTS_DIR=/path/to/manifest-folder ./scripts-jmx/setup.sh

# Teardown
./scripts-jmx/destroy.sh

# Validate Datadog JMX status
./scripts-jmx/validate-jmx.sh
```

## Notes

- Existing scripts under `scripts/` are unchanged.
- These scripts are additive and safe to use as an alternate path.
- `setup.sh` still reuses `scripts/deploy-monitoring.sh` for monitoring and Datadog install.
