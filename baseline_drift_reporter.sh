#!/usr/bin/env bash
#
# ---------------------------------------------------------------------
# Path:         baseline_drift_reporter.sh
# Filename:     baseline_drift_reporter.sh
# Project:      baseline_drift_reporter
# Description:  Snapshot system state, diff it against an accepted
#               baseline, and report drift. Observes only; never
#               reverts, never remediates.
# Status:       production
# Revision:     2
# Updated:      2026-08-05
# Requires:     Bash 4.2 or newer, GNU coreutils, diff, sha256sum,
#               findmnt, systemctl, ss, and one of dpkg-query or rpm
# Included by:  standalone command line tool; sourceable for testing
# Provides:     capture_packages, capture_services, capture_sockets,
#               capture_mounts, capture_config_hashes, capture_snapshot,
#               compare_snapshots, detect_package_manager,
#               require_commands
# ---------------------------------------------------------------------
#
# Portability
#   Target shells:  bash 4.2+ (arrays).
#   Tested on:      bash 5.2 on Ubuntu 24.04, with the rpm path
#                   exercised against a stub.
#   Package capture supports dpkg-query (Debian family) and rpm
#   (RHEL/SUSE family). Neither present is a hard failure, not an
#   empty section.
#
# Usage:
#   baseline_drift_reporter.sh                    compare mode
#   baseline_drift_reporter.sh --accept-baseline  bless current state
#   baseline_drift_reporter.sh --show-baseline    print baseline metadata
#
# Exit codes:
#   0  no drift (or baseline accepted)
#   1  drift detected and reported
#   2  configuration, dependency, or capture error
#
# Environment (all optional; defaults shown):
#   DRIFT_STATE_ROOT     /var/lib/baseline_drift_reporter
#   DRIFT_LOG_FILE       /var/log/baseline_drift_reporter.log
#   DRIFT_RECIPIENTS     alerts@example.net
#   DRIFT_WATCHED_FILES  colon-separated list of config files to hash
#   DRIFT_MAIL_COMMAND   mail
#   DRIFT_LIB_ONLY       set to 1 to source functions without running
#

set -u

drift_state_root="${DRIFT_STATE_ROOT:-/var/lib/baseline_drift_reporter}"
drift_baseline_directory="${drift_state_root}/baseline"
drift_snapshot_directory="${drift_state_root}/current"
drift_archive_directory="${drift_state_root}/baseline_archive"
drift_log_file="${DRIFT_LOG_FILE:-/var/log/baseline_drift_reporter.log}"
drift_recipients="${DRIFT_RECIPIENTS:-alerts@example.net}"
drift_mail_command="${DRIFT_MAIL_COMMAND:-mail}"

drift_watched_files_default="/etc/fstab:/etc/exports:/etc/samba/smb.conf:/etc/chrony.conf"
IFS=':' read -r -a drift_watched_files \
    <<< "${DRIFT_WATCHED_FILES:-${drift_watched_files_default}}"

drift_section_names=(packages services listening_sockets mounts config_hashes)

# ---------------------------------------------------------------------
# Infrastructure
# ---------------------------------------------------------------------

log_message() {
    local log_directory
    log_directory="$(dirname "${drift_log_file}")"
    [ -d "${log_directory}" ] || mkdir -p "${log_directory}" 2>/dev/null || return 0
    printf '%s %s\n' "$(date --iso-8601=seconds)" "${1}" >> "${drift_log_file}" 2>/dev/null || true
}

fail_run() {
    log_message "ERROR: ${1}"
    printf 'baseline_drift_reporter: %s\n' "${1}" >&2
    return "${2:-2}"
}

host_identity() {
    hostname --fqdn 2>/dev/null || hostname 2>/dev/null || printf 'unknown-host'
}

# detect_package_manager
# Prints dpkg or rpm, or returns 1 when neither is available. The old
# implementation piped dpkg-query through sort with stderr discarded, so
# on any RHEL or SUSE host the packages section captured an empty file,
# matched an equally empty baseline, and reported "no drift" forever.
detect_package_manager() {
    if command -v dpkg-query > /dev/null 2>&1; then
        printf 'dpkg'
        return 0
    fi
    if command -v rpm > /dev/null 2>&1; then
        printf 'rpm'
        return 0
    fi
    return 1
}

# require_commands <command...>
# Reports every missing dependency at once rather than one per run.
require_commands() {
    local missing_commands=()
    local candidate
    for candidate in "$@"; do
        command -v "${candidate}" > /dev/null 2>&1 || missing_commands+=("${candidate}")
    done
    if [ "${#missing_commands[@]}" -gt 0 ]; then
        fail_run "missing required command(s): ${missing_commands[*]}" 2
        return 2
    fi
    return 0
}

# ---------------------------------------------------------------------
# Capture. Every section fails loudly rather than writing an empty file.
# A section that cannot be captured is unknown, and unknown reported as
# "no drift" is the failure mode this whole tool exists to prevent.
# ---------------------------------------------------------------------

capture_packages() {
    local output_file="${1}"
    local package_manager
    if ! package_manager="$(detect_package_manager)"; then
        fail_run "no supported package manager found (dpkg-query, rpm)" 2
        return 2
    fi
    case "${package_manager}" in
        dpkg)
            dpkg-query --show --showformat='${Package} ${Version}\n' \
                > "${output_file}.raw" 2>/dev/null || {
                fail_run "dpkg-query failed while capturing packages" 2; return 2; }
            ;;
        rpm)
            rpm --query --all --queryformat='%{NAME} %{VERSION}-%{RELEASE}\n' \
                > "${output_file}.raw" 2>/dev/null || {
                fail_run "rpm query failed while capturing packages" 2; return 2; }
            ;;
    esac
    if [ ! -s "${output_file}.raw" ]; then
        rm -f "${output_file}.raw"
        fail_run "package capture produced no output; refusing to record an empty section" 2
        return 2
    fi
    sort "${output_file}.raw" > "${output_file}"
    rm -f "${output_file}.raw"
    return 0
}

capture_services() {
    local output_file="${1}"
    {
        systemctl list-unit-files --type=service --state=enabled --no-legend
        systemctl list-units --type=service --state=running --no-legend
    } > "${output_file}.raw" 2>/dev/null || {
        fail_run "systemctl failed while capturing services" 2; return 2; }
    if [ ! -s "${output_file}.raw" ]; then
        rm -f "${output_file}.raw"
        fail_run "service capture produced no output; refusing to record an empty section" 2
        return 2
    fi
    awk '{print $1, $2}' "${output_file}.raw" | sort > "${output_file}"
    rm -f "${output_file}.raw"
    return 0
}

capture_sockets() {
    local output_file="${1}"
    ss -tulpnH > "${output_file}.raw" 2>/dev/null || {
        fail_run "ss failed while capturing listening sockets" 2; return 2; }
    # An empty socket table is implausible on a real host but not
    # impossible in a container, so this section records emptiness
    # explicitly rather than treating it as a capture failure.
    awk '{print $1, $5, $7}' "${output_file}.raw" | sort > "${output_file}"
    [ -s "${output_file}" ] || printf 'NONE no listening sockets observed\n' > "${output_file}"
    rm -f "${output_file}.raw"
    return 0
}

capture_mounts() {
    local output_file="${1}"
    findmnt --list --noheadings --output TARGET,SOURCE,FSTYPE,OPTIONS \
        > "${output_file}.raw" 2>/dev/null || {
        fail_run "findmnt failed while capturing mounts" 2; return 2; }
    if [ ! -s "${output_file}.raw" ]; then
        rm -f "${output_file}.raw"
        fail_run "mount capture produced no output; refusing to record an empty section" 2
        return 2
    fi
    sort "${output_file}.raw" > "${output_file}"
    rm -f "${output_file}.raw"
    return 0
}

capture_config_hashes() {
    local output_file="${1}"
    local watched_file
    : > "${output_file}"
    for watched_file in "${drift_watched_files[@]}"; do
        [ -n "${watched_file}" ] || continue
        if [ -f "${watched_file}" ]; then
            sha256sum "${watched_file}" >> "${output_file}"
        else
            # A watched file that is absent is a fact worth recording.
            # Silence would convert the snapshot from evidence into a
            # partial story.
            printf 'MISSING %s\n' "${watched_file}" >> "${output_file}"
        fi
    done
    sort -o "${output_file}" "${output_file}"
    return 0
}

# capture_snapshot <output_directory>
# Captures into a staging directory first and promotes only on complete
# success, so a partial capture can never become a baseline.
capture_snapshot() {
    local output_directory="${1}"
    local staging_directory="${output_directory}.staging"

    rm -rf "${staging_directory}"
    mkdir -p "${staging_directory}" || {
        fail_run "cannot create staging directory ${staging_directory}" 2; return 2; }

    capture_packages      "${staging_directory}/packages.txt"          || return 2
    capture_services      "${staging_directory}/services.txt"          || return 2
    capture_sockets       "${staging_directory}/listening_sockets.txt" || return 2
    capture_mounts        "${staging_directory}/mounts.txt"            || return 2
    capture_config_hashes "${staging_directory}/config_hashes.txt"     || return 2

    printf 'captured_at %s\ncaptured_on %s\n' \
        "$(date --iso-8601=seconds)" "$(host_identity)" \
        > "${staging_directory}/metadata.txt"

    rm -rf "${output_directory}"
    mv "${staging_directory}" "${output_directory}" || {
        fail_run "cannot promote snapshot into ${output_directory}" 2; return 2; }
    return 0
}

# compare_snapshots <baseline_directory> <snapshot_directory>
# Prints a drift report to stdout. Returns 0 clean, 1 drift, 2 error.
compare_snapshots() {
    local baseline_directory="${1}"
    local snapshot_directory="${2}"
    local section_name
    local section_diff
    local drift_found=1

    for section_name in "${drift_section_names[@]}"; do
        local baseline_file="${baseline_directory}/${section_name}.txt"
        local snapshot_file="${snapshot_directory}/${section_name}.txt"
        if [ ! -f "${baseline_file}" ] || [ ! -f "${snapshot_file}" ]; then
            # A missing section file is an error, never drift. Conflating
            # the two would let a broken capture masquerade as a finding.
            fail_run "section ${section_name} missing from baseline or snapshot" 2
            return 2
        fi
        section_diff="$(diff -u "${baseline_file}" "${snapshot_file}")" || drift_found=0
        if [ -n "${section_diff}" ]; then
            printf '==== Drift in %s ====\n%s\n\n' "${section_name}" "${section_diff}"
        fi
    done

    [ "${drift_found}" -eq 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------

command_accept_baseline() {
    # Archive the outgoing baseline before replacing it. The accept step
    # is the one place where drift can be laundered into the record, so
    # the previous baseline is kept and the move is journalled.
    if [ -d "${drift_baseline_directory}" ]; then
        mkdir -p "${drift_archive_directory}" || {
            fail_run "cannot create baseline archive directory" 2; return 2; }
        local archive_stamp
        archive_stamp="$(date +%Y%m%dT%H%M%S)"
        cp -a "${drift_baseline_directory}" \
            "${drift_archive_directory}/baseline_${archive_stamp}" || {
            fail_run "cannot archive the outgoing baseline" 2; return 2; }
        log_message "Previous baseline archived as baseline_${archive_stamp}."
    fi

    capture_snapshot "${drift_baseline_directory}" || return 2
    log_message "Baseline accepted by $(logname 2>/dev/null || printf 'unknown')."
    printf 'Baseline accepted.\n'
    return 0
}

command_show_baseline() {
    if [ ! -f "${drift_baseline_directory}/metadata.txt" ]; then
        fail_run "no baseline exists; run with --accept-baseline first" 2
        return 2
    fi
    cat "${drift_baseline_directory}/metadata.txt"
    return 0
}

command_compare() {
    if [ ! -d "${drift_baseline_directory}" ]; then
        fail_run "no baseline exists; run with --accept-baseline first" 2
        return 2
    fi

    capture_snapshot "${drift_snapshot_directory}" || return 2

    local drift_report
    local comparison_status
    drift_report="$(compare_snapshots "${drift_baseline_directory}" "${drift_snapshot_directory}")"
    comparison_status=$?

    if [ "${comparison_status}" -eq 2 ]; then
        return 2
    fi
    if [ "${comparison_status}" -eq 0 ]; then
        log_message "No drift detected."
        return 0
    fi

    log_message "Drift detected, sending report."
    local host_name
    host_name="$(host_identity)"
    {
        printf 'Baseline drift on %s at %s.\n' "${host_name}" "$(date --iso-8601=seconds)"
        printf 'If intentional, re-bless with: baseline_drift_reporter.sh --accept-baseline\n\n'
        printf '%s\n' "${drift_report}"
    } | "${drift_mail_command}" -s "DRIFT: configuration change on ${host_name}" \
            "${drift_recipients}" || {
        # A report that could not be delivered has not been reported. The
        # drift is still real, so it goes to stdout and the log rather
        # than being lost to a failed alert path.
        log_message "ALERT PATH FAILED: could not send drift report via ${drift_mail_command}."
        printf 'ALERT PATH FAILED: drift detected but the report could not be mailed.\n' >&2
        printf '%s\n' "${drift_report}" >&2
    }
    return 1
}

main() {
    require_commands diff sha256sum sort awk date findmnt systemctl ss || return 2
    command -v "${drift_mail_command}" > /dev/null 2>&1 \
        || log_message "WARN: mail command '${drift_mail_command}' not found; drift reports will fall back to stderr."

    mkdir -p "${drift_state_root}" || {
        fail_run "cannot create state directory ${drift_state_root}" 2; return 2; }

    case "${1:-}" in
        --accept-baseline) command_accept_baseline ;;
        --show-baseline)   command_show_baseline ;;
        "")                command_compare ;;
        *)
            fail_run "unknown argument: ${1}" 2
            return 2
            ;;
    esac
}

if [ "${DRIFT_LIB_ONLY:-0}" != "1" ]; then
    main "$@"
    exit $?
fi
