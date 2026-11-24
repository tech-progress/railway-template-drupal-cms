#!/usr/bin/env bash
# Compiles the IaC graph with a scrubbed environment, so no DRUPAL_IAC_*
# source-project credential (or DRUPAL_IAC_SEED) reaches the graph or any
# argument built from it.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"
env -i PATH="${PATH}" HOME="${HOME}" ./node_modules/.bin/railway-iac-ts .railway/railway.ts </dev/null
