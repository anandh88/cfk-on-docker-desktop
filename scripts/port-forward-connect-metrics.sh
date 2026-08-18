#!/usr/bin/env bash
set -euo pipefail

kubectl port-forward pod/connect-0 -n confluent 7778:7778