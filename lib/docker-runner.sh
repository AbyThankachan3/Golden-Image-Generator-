#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  Docker runner — launches Docker with lib directory mounted
# ═══════════════════════════════════════════════════════════

# run_docker_phase <phase> <extra_env_args...>
# Phases: "analyze", "build"
run_docker_phase() {
    local PHASE="$1"; shift
    local EXTRA_ARGS=("$@")

    # Validate Docker is running
    if ! docker info &>/dev/null; then
        die "Docker is not running. Please start Docker first."
    fi

    # Ensure amd64 platform support
    local PLATFORM_FLAG="--platform linux/amd64"

    info "Launching Docker (phase: $PHASE)..."

    docker run --rm \
        $PLATFORM_FLAG \
        --privileged \
        -e "PHASE=$PHASE" \
        -e "UBUNTU_VERSION=${FULL_VERSION}" \
        -e "MAJOR_MINOR=${MAJOR_MINOR}" \
        -e "ISO_NAME=${ISO_NAME}" \
        -v "${CACHE_DIR}:/input:ro" \
        -v "${OUTPUT_DIR}:/output" \
        -v "${PROJECT_DIR}/lib:/lib-golden:ro" \
        "${EXTRA_ARGS[@]}" \
        "${DOCKER_BASE}" \
        /bin/bash /lib-golden/docker-entrypoint.sh

    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        die "Docker phase '$PHASE' failed (exit code: $exit_code)"
    fi
}

# run_analyze_phase
# Runs ISO detection + package analysis in Docker
run_analyze_phase() {
    run_docker_phase "analyze"
}

# run_build_phase <approved_packages_file>
# Runs the full build with approved package list
run_build_phase() {
    local APPROVED_FILE="$1"

    run_docker_phase "build" \
        -v "${APPROVED_FILE}:/tmp/approved-packages.txt:ro"
}
