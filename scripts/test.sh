#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
swift run --package-path "$project_dir" --scratch-path "${GPUBAR_BUILD_DIR:-$project_dir/.build}" GPUBarChecks
