#!/usr/bin/env bats
#
# ---------------------------------------------------------------------
# Path:         test/baseline_drift_reporter.bats
# Filename:     baseline_drift_reporter.bats
# Project:      baseline_drift_reporter
# Description:  Behavioural tests for capture, comparison, and the
#               baseline accept workflow, including the silent
#               empty-capture regression.
# Status:       production
# Revision:     1
# Updated:      2026-08-05
# Requires:     bats, bash 4.2 or newer
# Included by:  .github/workflows/ci.yml
# Provides:     test coverage for baseline_drift_reporter.sh
# ---------------------------------------------------------------------
#
# Run with:  bats test/
#
# System tools are stubbed so the suite runs identically in a container
# with no systemd, which is also where the original silent-capture bug
# would have gone unnoticed.
#

setup() {
  export DRIFT_LIB_ONLY=1
  WORK="$(mktemp -d)"
  export WORK

  mkdir -p "${WORK}/bin"
  printf '#!/usr/bin/env bash\nprintf "sshd.service enabled\\nchronyd.service running\\n"\n' \
    > "${WORK}/bin/systemctl"
  printf '#!/usr/bin/env bash\nprintf "tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:((sshd))\\n"\n' \
    > "${WORK}/bin/ss"
  printf '#!/usr/bin/env bash\nprintf "/ /dev/sda1 ext4 rw,relatime\\n"\n' \
    > "${WORK}/bin/findmnt"
  chmod +x "${WORK}/bin"/*
  export PATH="${WORK}/bin:${PATH}"

  export DRIFT_STATE_ROOT="${WORK}/state"
  export DRIFT_LOG_FILE="${WORK}/drift.log"

  source "${BATS_TEST_DIRNAME}/../baseline_drift_reporter.sh"

  drift_state_root="${WORK}/state"
  drift_baseline_directory="${drift_state_root}/baseline"
  drift_snapshot_directory="${drift_state_root}/current"
  drift_archive_directory="${drift_state_root}/baseline_archive"
  drift_log_file="${WORK}/drift.log"

  printf 'alpha\n' > "${WORK}/a.conf"
  printf 'beta\n'  > "${WORK}/b.conf"
  drift_watched_files=("${WORK}/a.conf" "${WORK}/b.conf")
}

teardown() {
  rm -rf "${WORK}"
}

# ---------------------------------------------------------------------
# Regression: a section that cannot be captured must not report clean
# ---------------------------------------------------------------------

@test "REGRESSION no package manager is a hard error, not an empty section" {
  detect_package_manager() { return 1; }
  run capture_packages "${WORK}/packages.txt"
  [ "${status}" -eq 2 ]
  [ ! -f "${WORK}/packages.txt" ]
}

@test "REGRESSION a package tool that returns nothing is refused" {
  detect_package_manager() { printf 'rpm'; }
  rpm() { return 0; }
  run capture_packages "${WORK}/packages.txt"
  [ "${status}" -eq 2 ]
}

@test "the rpm package path captures on RHEL-family hosts" {
  printf '#!/usr/bin/env bash\nprintf "bash 5.1.8-9.el9\\nkernel 5.14.0-427.el9\\n"\n' \
    > "${WORK}/bin/rpm"
  chmod +x "${WORK}/bin/rpm"
  detect_package_manager() { printf 'rpm'; }
  capture_packages "${WORK}/packages.txt"
  grep -q "kernel" "${WORK}/packages.txt"
}

@test "detect_package_manager finds dpkg-query when present" {
  run detect_package_manager
  [ "${status}" -eq 0 ]
  [[ "${output}" == "dpkg" || "${output}" == "rpm" ]]
}

@test "a failing capture tool is a hard error" {
  systemctl() { return 1; }
  run capture_services "${WORK}/services.txt"
  [ "${status}" -eq 2 ]
}

# ---------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------

@test "a full snapshot writes every section plus metadata" {
  capture_snapshot "${drift_baseline_directory}"
  for section in packages services listening_sockets mounts config_hashes metadata; do
    [ -f "${drift_baseline_directory}/${section}.txt" ]
  done
}

@test "an absent watched file is recorded as MISSING, not skipped" {
  drift_watched_files=("${WORK}/a.conf" "${WORK}/not_there.conf")
  capture_config_hashes "${WORK}/hashes.txt"
  grep -q "^MISSING ${WORK}/not_there.conf" "${WORK}/hashes.txt"
}

@test "a present watched file is recorded by hash" {
  capture_config_hashes "${WORK}/hashes.txt"
  grep -q "${WORK}/a.conf" "${WORK}/hashes.txt"
  grep -qE '^[0-9a-f]{64} ' "${WORK}/hashes.txt"
}

@test "no staging directory survives a successful capture" {
  capture_snapshot "${drift_baseline_directory}"
  [ ! -d "${drift_baseline_directory}.staging" ]
}

# ---------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------

@test "an unchanged system reports no drift" {
  capture_snapshot "${drift_baseline_directory}"
  capture_snapshot "${drift_snapshot_directory}"
  run compare_snapshots "${drift_baseline_directory}" "${drift_snapshot_directory}"
  [ "${status}" -eq 0 ]
}

@test "an edited watched file is detected as drift" {
  capture_snapshot "${drift_baseline_directory}"
  printf 'alpha changed\n' > "${WORK}/a.conf"
  capture_snapshot "${drift_snapshot_directory}"
  run compare_snapshots "${drift_baseline_directory}" "${drift_snapshot_directory}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Drift in config_hashes"* ]]
}

@test "a watched file that disappears is detected as drift" {
  capture_snapshot "${drift_baseline_directory}"
  rm -f "${WORK}/b.conf"
  capture_snapshot "${drift_snapshot_directory}"
  run compare_snapshots "${drift_baseline_directory}" "${drift_snapshot_directory}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"MISSING"* ]]
}

@test "REGRESSION a missing section file is an error, never drift" {
  capture_snapshot "${drift_baseline_directory}"
  capture_snapshot "${drift_snapshot_directory}"
  rm -f "${drift_snapshot_directory}/mounts.txt"
  run compare_snapshots "${drift_baseline_directory}" "${drift_snapshot_directory}"
  [ "${status}" -eq 2 ]
}

# ---------------------------------------------------------------------
# Baseline accept workflow
# ---------------------------------------------------------------------

@test "accept-baseline creates a baseline when none exists" {
  run command_accept_baseline
  [ "${status}" -eq 0 ]
  [ -f "${drift_baseline_directory}/metadata.txt" ]
}

@test "accept-baseline archives the outgoing baseline before replacing it" {
  command_accept_baseline
  printf 'alpha changed\n' > "${WORK}/a.conf"
  command_accept_baseline
  [ "$(ls -1 "${drift_archive_directory}" | wc -l)" -eq 1 ]
}

@test "the archived baseline retains the pre-accept content" {
  command_accept_baseline
  local original_hash
  original_hash="$(sha256sum "${WORK}/a.conf" | awk '{print $1}')"
  printf 'alpha changed\n' > "${WORK}/a.conf"
  command_accept_baseline
  grep -rq "${original_hash}" "${drift_archive_directory}"
}

@test "compare without a baseline is an error" {
  run command_compare
  [ "${status}" -eq 2 ]
}

@test "show-baseline without a baseline is an error" {
  run command_show_baseline
  [ "${status}" -eq 2 ]
}

@test "show-baseline prints capture metadata once a baseline exists" {
  command_accept_baseline
  run command_show_baseline
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"captured_at"* ]]
}

# ---------------------------------------------------------------------
# Dependency handling
# ---------------------------------------------------------------------

@test "require_commands reports every missing dependency at once" {
  run require_commands definitely_not_real_one definitely_not_real_two
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"definitely_not_real_one"* ]]
  [[ "${output}" == *"definitely_not_real_two"* ]]
}

@test "require_commands passes when every dependency is present" {
  run require_commands bash sort awk
  [ "${status}" -eq 0 ]
}

@test "sourcing with DRIFT_LIB_ONLY does not execute a run" {
  run bash -c "DRIFT_LIB_ONLY=1 source '${BATS_TEST_DIRNAME}/../baseline_drift_reporter.sh' && echo sourced_clean"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"sourced_clean"* ]]
}
