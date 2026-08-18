#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# src/identity.sh — the extension identity, declared ONCE (feature 013).
#
# The bridge used to carry its own identity as three separate literals: the
# registrar wrote `extension: <id>` (install.sh), the health check matched
# `<id>` inside its awk walk (hookcheck.sh), and the config loader pinned the
# install directory (config.sh). Feature 012's "detection and repair must
# agree" guarantee was therefore satisfied only by coincidence — two literals
# that happened to match. This module makes it structural: every consumer
# derives the id, the push-command name and the install directory from here,
# and `tests/unit/extension_identity.bats` pins the manifest to the same value.
#
# Identity (feature 013 — one name, everywhere): the framework id, the
# community-catalog key, the command namespace and the install directory are
# all `jira-sync`. The bare `jira` slot belongs to an unrelated extension; the
# legacy constants below exist only so the read-side fallbacks (the pre-0.6.0
# config path) can name the old location without re-introducing a literal.
#
# Contract: dependency-free, no I/O, NO side effects. Safe to source from any
# context (including a lazily-sourced install.sh) and safe to source twice.
# =============================================================================

# Idempotent include-guard — safe to source twice (hookcheck.sh sources this
# directly AND lazily sources install.sh, which sources it again on consent).
[[ -n "${_IDENTITY_SH_LOADED:-}" ]] && return 0
readonly _IDENTITY_SH_LOADED=1

# The extension id: the framework id, the community-catalog key, the command
# namespace root, and the directory name under `.specify/extensions/`.
readonly SPECKIT_EXT_ID="jira-sync"

# The single command every auto-sync hook fires. Reconcile is the one
# convergent operation, so all six `after_*` hooks point here.
# shellcheck disable=SC2034  # consumed by install.sh / hookcheck.sh / config.sh
readonly SPECKIT_EXT_PUSH_COMMAND="speckit.${SPECKIT_EXT_ID}.push"

# Where the CLI installs this extension in a consumer repo — and therefore
# where the gitignored per-repo binding (`jira-config.yml`) lives.
# shellcheck disable=SC2034  # consumed by install.sh / hookcheck.sh / config.sh
readonly SPECKIT_EXT_INSTALL_DIR=".specify/extensions/${SPECKIT_EXT_ID}"

# ---------------------------------------------------------------------------
# Legacy (pre-0.6.0) identity — READ-SIDE ONLY.
#
# Nothing is ever written under these names again. They exist so the config
# loader can still READ an operator's resolved binding from the old install
# directory (surfaced, never moved, never deleted — Principle I/VIII).
# ---------------------------------------------------------------------------
readonly SPECKIT_EXT_LEGACY_ID="jira"
# shellcheck disable=SC2034  # consumed by install.sh / hookcheck.sh / config.sh
readonly SPECKIT_EXT_LEGACY_INSTALL_DIR=".specify/extensions/${SPECKIT_EXT_LEGACY_ID}"
