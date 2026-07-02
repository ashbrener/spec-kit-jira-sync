#!/usr/bin/env bash
# =============================================================================
# src/jira_rest.sh
#
# Thin Jira-Cloud REST client (curl + jq) the sink sources. It is the ONLY
# place that talks HTTP to Jira; everything above it speaks in paths + JSON.
#
# Contract: specs/001-core-bridge/contracts/jira-rest.md
# Decisions: research.md D7 (rate-limit / 429 backoff), D8 (Basic auth).
# Governance: constitution.md — VI (credentials at the edges, never logged),
#   VIII (surface, don't enforce — loud failure), IX (no real coordinates;
#   always $JIRA_BASE_URL, never a hardcoded site).
#
# Failure model (fail-closed reads):
#   - A READ that hits 401 / 403 / 404 / network failure returns rc 3 — the
#     engine's "unreadable" signal, which makes it fail closed for that spec.
#   - 429 and transient 5xx are retried with bounded backoff (Retry-After if
#     present, else jittered exponential); on exhaustion a distinct rc is
#     returned and a clear message is written to stderr. Never unbounded.
#
# Privacy: $JIRA_BASE_URL is the only site reference; the API token is passed
# to curl via -u and NEVER echoed, logged, or placed in a tracked file.
#
# Safe under `set -euo pipefail`. shellcheck-clean (--severity=style).
# =============================================================================

# Idempotent include-guard (012) — safe to source twice (the consented
# self-heal sources install.sh, which re-sources this lib).
[[ -n "${_JIRA_REST_SH_LOADED:-}" ]] && return 0
readonly _JIRA_REST_SH_LOADED=1

# ----------------------------------------------------------------------------
# Return codes (callers branch on these).
# ----------------------------------------------------------------------------
readonly JIRA_REST_RC_OK=0            # 2xx
readonly JIRA_REST_RC_UNREADABLE=3    # 401/403/404/network on a READ -> engine fail-closed
readonly JIRA_REST_RC_RETRY_EXHAUSTED=4  # bounded 429/5xx retries gave up
readonly JIRA_REST_RC_HTTP_ERROR=5    # other non-2xx (e.g. 400/409 on a write)
readonly JIRA_REST_RC_CONFIG=6        # missing required env (base url / creds)

# ----------------------------------------------------------------------------
# Tunables — all env-overridable, all with safe defaults.
# ----------------------------------------------------------------------------
: "${JIRA_MAX_RETRIES:=5}"      # bound on 429/5xx retry attempts (FR-022)
: "${JIRA_BACKOFF_BASE:=1}"     # seconds: first backoff before doubling
: "${JIRA_BACKOFF_CAP:=60}"     # seconds: ceiling for a single backoff sleep
: "${JIRA_HTTP_TIMEOUT:=30}"    # seconds: per-request curl max-time
: "${DRY_RUN:=0}"               # 1 => writes log intent to stderr, no curl

# ----------------------------------------------------------------------------
# jira_rest::_log <message...>
#   stderr only. NEVER pass a credential or token here.
# ----------------------------------------------------------------------------
jira_rest::_log() {
  printf 'jira_rest: %s\n' "$*" >&2
}

# ----------------------------------------------------------------------------
# jira_rest::_require_env
#   Fail loudly (Principle VIII) if the edge credentials/base are absent.
#   Reports WHICH var is missing, never its value.
# ----------------------------------------------------------------------------
jira_rest::_require_env() {
  local missing=()
  [[ -n "${JIRA_BASE_URL:-}" ]]  || missing+=("JIRA_BASE_URL")
  [[ -n "${JIRA_EMAIL:-}" ]]     || missing+=("JIRA_EMAIL")
  [[ -n "${JIRA_API_TOKEN:-}" ]] || missing+=("JIRA_API_TOKEN")
  if (( ${#missing[@]} > 0 )); then
    jira_rest::_log "missing required env: ${missing[*]} (set them in the gitignored .env)"
    return "${JIRA_REST_RC_CONFIG}"
  fi
  return 0
}

# ----------------------------------------------------------------------------
# jira_rest::auth_args
#   Emit the curl Basic-auth args, one per line, for word-splitting via
#   `mapfile`/`read` at the call site. The token is emitted ONLY as the
#   argument to curl's -u and is never logged. Callers MUST capture this with
#   a NUL/line-safe reader and pass straight to curl.
#
#   Usage:
#     local auth=(); mapfile -t auth < <(jira_rest::auth_args) || return $?
#     curl "${auth[@]}" ...
# ----------------------------------------------------------------------------
jira_rest::auth_args() {
  jira_rest::_require_env || return $?
  # -u <email>:<token> — curl base64-encodes it into the Authorization header.
  # Emitting on separate lines keeps the colon-joined secret as a single arg.
  printf '%s\n' "-u" "${JIRA_EMAIL}:${JIRA_API_TOKEN}"
}

# ----------------------------------------------------------------------------
# jira_rest::_backoff_sleep <attempt> <retry_after>
#   Sleep before a retry. Honors a numeric Retry-After when given; otherwise
#   jittered exponential backoff: base * 2^(attempt-1), capped, +/- jitter.
#   <attempt> is 1-based (first retry = 1).
# ----------------------------------------------------------------------------
jira_rest::_backoff_sleep() {
  local attempt="$1" retry_after="${2:-}"
  local delay

  if [[ "${retry_after}" =~ ^[0-9]+$ ]] && (( retry_after > 0 )); then
    # Server told us exactly how long to wait — honor it, but still cap.
    delay="${retry_after}"
    (( delay > JIRA_BACKOFF_CAP )) && delay="${JIRA_BACKOFF_CAP}"
  else
    # Exponential: base * 2^(attempt-1).
    delay="${JIRA_BACKOFF_BASE}"
    local i=1
    while (( i < attempt )); do
      delay=$(( delay * 2 ))
      (( delay >= JIRA_BACKOFF_CAP )) && { delay="${JIRA_BACKOFF_CAP}"; break; }
      i=$(( i + 1 ))
    done
    (( delay > JIRA_BACKOFF_CAP )) && delay="${JIRA_BACKOFF_CAP}"
    # Jitter: add 0..delay deciseconds so concurrent callers desynchronise.
    local jitter=$(( RANDOM % (delay * 10 + 1) ))
    delay=$(( delay * 10 + jitter ))   # work in deciseconds
    sleep "$(( delay / 10 )).$(( delay % 10 ))"
    return 0
  fi
  sleep "${delay}"
}

# ----------------------------------------------------------------------------
# jira_rest::_request <op_class> <method> <path> [json_body]
#   Core HTTP engine. <op_class> is "read" or "write" — it selects the
#   fail-closed policy: a non-retryable error on a "read" returns rc 3.
#
#   <path> is a Jira REST path relative to /rest/api/3 (with or without a
#   leading slash), e.g. "issue/ABC-1" or "/search/jql?jql=...".
#
#   Body (success) goes to stdout. Diagnostics go to stderr. The token never
#   appears on either stream.
# ----------------------------------------------------------------------------
jira_rest::_request() {
  local op_class="$1" method="$2" path="$3" body="${4:-}"

  # Reset the last-error capture each request. On a non-2xx response this is
  # populated with the Jira response BODY (errorMessages/errors), so the caller
  # (e.g. mutate_issue_update) can surface a field-level error like
  # INVALID_INPUT in its failure line without re-deriving it.
  JIRA_REST_LAST_ERROR_BODY=""

  jira_rest::_require_env || return $?

  # Normalise to a single well-formed URL. Only $JIRA_BASE_URL — never a
  # hardcoded site (Principle IX).
  local base="${JIRA_BASE_URL%/}"
  local rel="${path#/}"
  local url="${base}/rest/api/3/${rel}"

  # DRY-RUN: writes announce intent and short-circuit before any curl.
  if [[ "${op_class}" == "write" && "${DRY_RUN}" == "1" ]]; then
    jira_rest::_log "DRY_RUN: would ${method} ${url}"
    if [[ -n "${body}" ]]; then
      jira_rest::_log "DRY_RUN: body=${body}"
    fi
    return "${JIRA_REST_RC_OK}"
  fi

  local auth=()
  mapfile -t auth < <(jira_rest::auth_args) || return $?

  local hdr_file body_file
  hdr_file="$(mktemp)"
  body_file="$(mktemp)"
  # shellcheck disable=SC2064  # expand paths now so the trap cleans these exact files.
  trap "rm -f -- '${hdr_file}' '${body_file}'" RETURN

  local attempt=0
  local max=$(( JIRA_MAX_RETRIES + 1 ))   # initial try + JIRA_MAX_RETRIES retries

  # Idempotency gate (codex review P1): only idempotent methods may be retried on
  # an AMBIGUOUS failure (network timeout / 5xx), where the server may already
  # have committed the write. A non-idempotent POST that fails ambiguously is NOT
  # retried — retrying could duplicate an issue/comment/link (FR-008). HTTP 429 is
  # exempt: it is rejected before processing, so it is safe to retry for any
  # method; the reconcile's query-before-write idempotency recovers the rest.
  local idempotent=0
  case "${method}" in
    GET|HEAD|PUT|DELETE) idempotent=1 ;;
    *)                   idempotent=0 ;;   # POST (and anything else): ambiguous-unsafe
  esac

  while (( attempt < max )); do
    attempt=$(( attempt + 1 ))

    local curl_args=(
      --silent --show-error
      --request "${method}"
      --max-time "${JIRA_HTTP_TIMEOUT}"
      --dump-header "${hdr_file}"
      --output "${body_file}"
      --write-out '%{http_code}'
      --header 'Accept: application/json'
    )
    if [[ -n "${body}" ]]; then
      curl_args+=( --header 'Content-Type: application/json' --data "${body}" )
    fi
    curl_args+=( "${auth[@]}" "${url}" )

    local http_code curl_rc
    # Capture HTTP code; tolerate curl's own non-zero (network) without aborting
    # the loop under `set -e`.
    http_code="$(curl "${curl_args[@]}" 2>>"${hdr_file}")" && curl_rc=0 || curl_rc=$?

    if (( curl_rc != 0 )); then
      # Transport failure (DNS, TLS, timeout, connection refused). Treat as
      # transient and retry within the bound; if reads exhaust, fail closed.
      jira_rest::_log "network failure (curl rc ${curl_rc}) on ${method} ${url} [attempt ${attempt}/${max}]"
      if (( attempt < max )) && (( idempotent )); then
        jira_rest::_backoff_sleep "${attempt}" ""
        continue
      fi
      if (( ! idempotent )); then
        # Ambiguous non-idempotent failure: the write may have committed. Do NOT
        # retry (risks a duplicate); fail closed and let the next reconcile,
        # which queries before writing, converge.
        jira_rest::_log "ambiguous ${method} network failure -> not retrying (avoid duplicate write); fail closed (rc ${JIRA_REST_RC_HTTP_ERROR})"
        return "${JIRA_REST_RC_HTTP_ERROR}"
      fi
      if [[ "${op_class}" == "read" ]]; then
        jira_rest::_log "read unreadable after network failures -> fail closed (rc ${JIRA_REST_RC_UNREADABLE})"
        return "${JIRA_REST_RC_UNREADABLE}"
      fi
      return "${JIRA_REST_RC_RETRY_EXHAUSTED}"
    fi

    case "${http_code}" in
      2??)
        cat -- "${body_file}"
        return "${JIRA_REST_RC_OK}"
        ;;
      429)
        # Rate-limited: the request was REJECTED before processing, so retrying
        # is safe for ANY method (including POST). Bounded retry (FR-022).
        local retry_after
        retry_after="$(jira_rest::_retry_after "${hdr_file}")"
        jira_rest::_log "HTTP 429 on ${method} ${url} [attempt ${attempt}/${max}]${retry_after:+ Retry-After=${retry_after}s}"
        if (( attempt < max )); then
          jira_rest::_backoff_sleep "${attempt}" "${retry_after}"
          continue
        fi
        jira_rest::_log "retries exhausted after ${JIRA_MAX_RETRIES} attempts on ${method} ${url} -> fail closed (rc ${JIRA_REST_RC_RETRY_EXHAUSTED})"
        return "${JIRA_REST_RC_RETRY_EXHAUSTED}"
        ;;
      5??)
        # Transient server error: AMBIGUOUS for non-idempotent writes (the server
        # may have committed before erroring). Retry only idempotent methods; a
        # POST 5xx fails closed to avoid a duplicate write (codex review P1).
        local retry_after
        retry_after="$(jira_rest::_retry_after "${hdr_file}")"
        jira_rest::_log "HTTP ${http_code} on ${method} ${url} [attempt ${attempt}/${max}]${retry_after:+ Retry-After=${retry_after}s}"
        if (( attempt < max )) && (( idempotent )); then
          jira_rest::_backoff_sleep "${attempt}" "${retry_after}"
          continue
        fi
        if (( ! idempotent )); then
          jira_rest::_log "ambiguous ${method} 5xx -> not retrying (avoid duplicate write); fail closed (rc ${JIRA_REST_RC_HTTP_ERROR})"
          return "${JIRA_REST_RC_HTTP_ERROR}"
        fi
        jira_rest::_log "retries exhausted after ${JIRA_MAX_RETRIES} attempts on ${method} ${url} -> fail closed (rc ${JIRA_REST_RC_RETRY_EXHAUSTED})"
        return "${JIRA_REST_RC_RETRY_EXHAUSTED}"
        ;;
      401|403|404)
        # Auth / permission / not-found. For a READ this is the engine's
        # "unreadable" signal -> rc 3 (fail closed). Not retried.
        JIRA_REST_LAST_ERROR_BODY="$(cat -- "${body_file}")"
        jira_rest::_log "HTTP ${http_code} on ${method} ${url}"
        if [[ "${op_class}" == "read" ]]; then
          jira_rest::_log "read unreadable -> fail closed (rc ${JIRA_REST_RC_UNREADABLE})"
          return "${JIRA_REST_RC_UNREADABLE}"
        fi
        return "${JIRA_REST_RC_HTTP_ERROR}"
        ;;
      *)
        # Other 4xx (400/409/422 …): a definite, non-retryable error. Surface
        # the response body to stderr to aid the operator (Principle VIII), and
        # capture it so the caller can quote the field-level error (INVALID_INPUT).
        JIRA_REST_LAST_ERROR_BODY="$(cat -- "${body_file}")"
        jira_rest::_log "HTTP ${http_code} on ${method} ${url}"
        jira_rest::_log "response: ${JIRA_REST_LAST_ERROR_BODY}"
        return "${JIRA_REST_RC_HTTP_ERROR}"
        ;;
    esac
  done

  # Loop fell through (defensive; the bound above should have returned first).
  jira_rest::_log "retries exhausted on ${method} ${url} -> rc ${JIRA_REST_RC_RETRY_EXHAUSTED}"
  return "${JIRA_REST_RC_RETRY_EXHAUSTED}"
}

# ----------------------------------------------------------------------------
# jira_rest::_retry_after <header_file>
#   Extract a numeric Retry-After (seconds) from dumped response headers.
#   Echoes the value, or nothing if absent / non-numeric. Case-insensitive.
# ----------------------------------------------------------------------------
jira_rest::_retry_after() {
  local hdr_file="$1" line value
  # Last matching header wins (covers redirected/multi-response dumps).
  line="$(grep -i '^Retry-After:' "${hdr_file}" 2>/dev/null | tail -n 1)" || true
  [[ -n "${line}" ]] || return 0
  value="${line#*:}"
  value="${value//$'\r'/}"
  value="${value//[[:space:]]/}"
  [[ "${value}" =~ ^[0-9]+$ ]] && printf '%s' "${value}"
  return 0
}

# ----------------------------------------------------------------------------
# Public verbs. Reads use op_class "read" (fail-closed -> rc 3); writes "write".
# Body -> stdout; on success rc 0.
# ----------------------------------------------------------------------------

# jira_rest::get <path>
jira_rest::get() {
  jira_rest::_request "read" "GET" "$1"
}

# jira_rest::post <path> <json>
jira_rest::post() {
  jira_rest::_request "write" "POST" "$1" "$2"
}

# jira_rest::put <path> <json>
jira_rest::put() {
  jira_rest::_request "write" "PUT" "$1" "$2"
}

# jira_rest::delete <path>
#   A WRITE (idempotent — DELETE is in the retry-safe set). Used only by the
#   re-mode prune path (feature 004): hard-delete of a bridge-owned orphan issue.
jira_rest::delete() {
  jira_rest::_request "write" "DELETE" "$1"
}

# jira_rest::search_jql <jql>
#   Convenience over GET /search/jql?jql=<url-encoded>&fields=…&maxResults=100.
#   A READ (fail-closed).
#
#   REAL-JIRA CONTRACT (verified live): the MODERN /search/jql endpoint returns
#   each issue WITHOUT `.key` and WITHOUT `.fields` unless `fields` is requested
#   explicitly. The sink's idempotency lookups read `.key` (every caller) plus
#   `.fields.{summary,status,updated,labels,parent}` (the drift reshape +
#   query_spec_issue), so a fields-less search makes every issue look keyless +
#   fieldless → no existing match → RE-CREATE on every run (duplicate board).
#   We therefore ALWAYS request the field set the callers consume; `key` is
#   returned automatically once any `fields` value is supplied. maxResults=100
#   bounds the page (the lookups only need the freshest match, and JQL orders
#   newest-first). The jql value stays url-encoded; `fields` + `maxResults` are
#   fixed tokens needing no encoding.
jira_rest::search_jql() {
  local jql="$1" encoded
  encoded="$(jira_rest::_urlencode "${jql}")"
  jira_rest::_request "read" "GET" \
    "search/jql?jql=${encoded}&fields=summary,status,updated,labels,parent&maxResults=100"
}

# ----------------------------------------------------------------------------
# jira_rest::_urlencode <string>
#   Percent-encode a query value with jq (already a hard dependency). Keeps the
#   JQL intact regardless of spaces, quotes, '=' etc.
# ----------------------------------------------------------------------------
jira_rest::_urlencode() {
  printf '%s' "$1" | jq -sRr '@uri'
}
