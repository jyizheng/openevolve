#!/usr/bin/env bash
# docker-entrypoint.sh — OpenEvolve AWS Batch entrypoint
#
# Responsibilities:
#   1. Download job inputs (program, evaluator, optional config) from S3
#   2. Resume from the latest checkpoint if this is a Spot-interrupted retry
#   3. Run OpenEvolve, syncing checkpoints to S3 every 5 minutes in the background
#   4. On SIGTERM (Spot 2-minute warning): checkpoint cleanly, then sync and exit
#   5. Upload all outputs to S3 on completion
#
# Required env vars (set by the Batch job definition or at submit time):
#   S3_INPUT_PREFIX   — s3://bucket/users/<user>/<job>/input
#   S3_OUTPUT_PREFIX  — s3://bucket/users/<user>/<job>/output
#   GEMINI_API_KEY    — injected from Secrets Manager by the ECS agent
#
# Optional env vars (have defaults in the job definition):
#   ITERATIONS        — number of evolution iterations (default: 100)
#   CONFIG_FILE       — filename of config inside the input prefix (default: config.yaml)
#   LOG_LEVEL         — DEBUG|INFO|WARNING (default: INFO)

set -euo pipefail

# ── Validate required inputs ──────────────────────────────────────────────────
: "${S3_INPUT_PREFIX:?S3_INPUT_PREFIX must be set}"
: "${S3_OUTPUT_PREFIX:?S3_OUTPUT_PREFIX must be set}"
: "${GEMINI_API_KEY:?GEMINI_API_KEY must be set (injected from Secrets Manager)}"

# OpenEvolve's openai client reads OPENAI_API_KEY by default; alias it here
export OPENAI_API_KEY="${GEMINI_API_KEY}"

# AWS Batch sets these automatically; fall back for local testing
JOB_ID="${AWS_BATCH_JOB_ID:-local-$(date +%s)}"
JOB_ATTEMPT="${AWS_BATCH_JOB_ATTEMPT:-0}"

# ── Working directories ───────────────────────────────────────────────────────
WORK_DIR="/tmp/openevolve-${JOB_ID}"
INPUT_DIR="${WORK_DIR}/input"
OUTPUT_DIR="${WORK_DIR}/output"
CHECKPOINT_DIR="${OUTPUT_DIR}/checkpoints"

mkdir -p "${INPUT_DIR}" "${OUTPUT_DIR}"

# ── Logging helper ────────────────────────────────────────────────────────────
log() {
    echo "[$(date -u +%FT%TZ)] $*"
}

log "=== OpenEvolve Batch job starting ==="
log "Job ID: ${JOB_ID}  Attempt: ${JOB_ATTEMPT}"
log "Input:  ${S3_INPUT_PREFIX}"
log "Output: ${S3_OUTPUT_PREFIX}"

# ── S3 sync helper ────────────────────────────────────────────────────────────
sync_outputs() {
    log "Syncing outputs → ${S3_OUTPUT_PREFIX}"
    aws s3 sync "${OUTPUT_DIR}/" "${S3_OUTPUT_PREFIX}/" \
        --exclude "*.tmp"          \
        --exclude "__pycache__/*"  \
        --quiet                    \
        || true   # Never fail the job on a sync error
}

# ── SIGTERM handler (Spot 2-minute interruption warning) ──────────────────────
EVOLVE_PID=""
SYNC_PID=""

cleanup() {
    log "SIGTERM received — checkpointing and syncing to S3..."

    # Ask OpenEvolve to exit gracefully; it will save a checkpoint first
    if [[ -n "${EVOLVE_PID}" ]] && kill -0 "${EVOLVE_PID}" 2>/dev/null; then
        kill -TERM "${EVOLVE_PID}"
        # Give it up to 90 s to checkpoint before we force-kill and exit
        local deadline=$(( $(date +%s) + 90 ))
        while kill -0 "${EVOLVE_PID}" 2>/dev/null && [[ $(date +%s) -lt ${deadline} ]]; do
            sleep 2
        done
        kill -9 "${EVOLVE_PID}" 2>/dev/null || true
    fi

    [[ -n "${SYNC_PID}" ]] && kill "${SYNC_PID}" 2>/dev/null || true

    sync_outputs
    log "Cleanup done — exiting for Spot retry."
    exit 0
}

trap cleanup SIGTERM SIGINT

# ── Download job inputs ───────────────────────────────────────────────────────
log "Downloading inputs from ${S3_INPUT_PREFIX}..."
aws s3 sync "${S3_INPUT_PREFIX}/" "${INPUT_DIR}/"

INITIAL_PROGRAM="${INPUT_DIR}/initial_program.py"
EVALUATOR="${INPUT_DIR}/evaluator.py"

[[ -f "${INITIAL_PROGRAM}" ]] || { log "ERROR: initial_program.py not found in input prefix"; exit 1; }
[[ -f "${EVALUATOR}" ]]       || { log "ERROR: evaluator.py not found in input prefix"; exit 1; }

# ── Checkpoint resume (Spot interruption retry) ───────────────────────────────
RESUME_FLAG=""
if [[ "${JOB_ATTEMPT}" -gt "0" ]]; then
    log "Attempt ${JOB_ATTEMPT} — checking S3 for a previous checkpoint..."

    # Sync any checkpoints written by the previous attempt
    aws s3 sync "${S3_OUTPUT_PREFIX}/checkpoints/" "${CHECKPOINT_DIR}/" --quiet 2>/dev/null || true

    # Find the highest-numbered checkpoint directory
    LATEST_CHECKPOINT=$(
        find "${CHECKPOINT_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | sort -t_ -k2 -n \
        | tail -n1 \
        || true
    )

    if [[ -n "${LATEST_CHECKPOINT}" ]]; then
        log "Resuming from checkpoint: ${LATEST_CHECKPOINT}"
        RESUME_FLAG="--checkpoint ${LATEST_CHECKPOINT}"
    else
        log "No checkpoint found — starting fresh."
    fi
fi

# ── Config ────────────────────────────────────────────────────────────────────
CONFIG_ARG=""
CONFIG_PATH="${INPUT_DIR}/${CONFIG_FILE:-config.yaml}"
if [[ -f "${CONFIG_PATH}" ]]; then
    CONFIG_ARG="--config ${CONFIG_PATH}"
    log "Using config: ${CONFIG_PATH}"
else
    log "No config file found — using OpenEvolve defaults."
fi

# ── Background sync loop ──────────────────────────────────────────────────────
# Syncs the output directory to S3 every 5 minutes so checkpoints survive
# a Spot interruption even if the job doesn't get a clean SIGTERM.
(
    while true; do
        sleep 300
        sync_outputs
    done
) &
SYNC_PID=$!

# ── Run OpenEvolve ────────────────────────────────────────────────────────────
log "Starting evolution: iterations=${ITERATIONS:-100}, log_level=${LOG_LEVEL:-INFO}"

# shellcheck disable=SC2086  # intentional word splitting for optional flags
python /app/openevolve-run.py \
    "${INITIAL_PROGRAM}"   \
    "${EVALUATOR}"         \
    ${CONFIG_ARG}          \
    --iterations "${ITERATIONS:-100}" \
    --log-level  "${LOG_LEVEL:-INFO}" \
    --output     "${OUTPUT_DIR}"      \
    ${RESUME_FLAG}         \
    &

EVOLVE_PID=$!
wait "${EVOLVE_PID}"
EVOLVE_EXIT=$?

# ── Final upload ──────────────────────────────────────────────────────────────
kill "${SYNC_PID}" 2>/dev/null || true
sync_outputs

if [[ "${EVOLVE_EXIT}" -eq 0 ]]; then
    log "=== Evolution complete. Results at ${S3_OUTPUT_PREFIX} ==="
else
    log "=== Evolution exited with code ${EVOLVE_EXIT} ==="
fi

exit "${EVOLVE_EXIT}"
