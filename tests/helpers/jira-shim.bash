# shellcheck shell=bash
# =============================================================================
# tests/helpers/jira-shim.bash
#
# A bats helper that shadows `curl` with a shell function so the Jira sink can
# be exercised offline against canned fixture JSON (decision D10 in
# specs/001-core-bridge/research.md). It mirrors the sibling spec-kit-linear's
# curl-shim, adapted to Jira's REST surface where calls are keyed by request
# METHOD + URL rather than a GraphQL operation name.
#
# Contract honoured (specs/001-core-bridge/contracts/jira-rest.md):
#   * The sink invokes curl roughly as
#       curl -sS -X <METHOD> -u "$EMAIL:$TOKEN" \
#            -H 'Content-Type: application/json' \
#            -w '\n%{http_code}\n' \
#            [-d @<file> | -d <inline>] \
#            "<BASE_URL><path>"
#   * The shim parses METHOD (-X / --request, default GET), the request URL
#     (the first non-flag argument that looks like a URL), and the body
#     (-d/--data/--data-raw/--data-binary, inline or @file).
#   * It writes the matched fixture body to stdout followed by a trailing
#     `\n<http_code>\n` so callers that use `-w '%{http_code}'` can split the
#     status off the tail. If `-o <file>` is present the body is written there
#     and only the status reaches stdout (the common sink pattern).
#   * Every request (method, url, body) is appended to a recorded-requests file
#     for later assertion via `jira_shim::requests`.
#
# Public API:
#   jira_shim::install
#       Shadow `curl` with the shim function and initialise the request log.
#   jira_shim::set_response <method> <url-glob> <fixture-path> [http_code]
#       Register a canned response. The first registered rule whose method
#       matches and whose url-glob (a shell glob) matches the request URL wins.
#       http_code defaults to 200.
#   jira_shim::requests
#       Dump the recorded requests (one record per request) to stdout. Each
#       record is three lines — `METHOD <m>`, `URL <u>`, `BODY <b>` — followed
#       by a `---` separator, so tests can grep for a method/url/body fragment.
#   jira_shim::reset
#       Clear registered rules and the request log (keeps the shim installed).
#   jira_shim::uninstall
#       Remove the `curl` shadow and tear down shim state.
# =============================================================================

# Resolve the fixtures directory relative to this helper so callers need not.
JIRA_SHIM_FIXTURE_DIR="${JIRA_SHIM_FIXTURE_DIR:-$(
  cd "$(dirname "${BASH_SOURCE[0]}")/../fixtures/jira_responses" 2>/dev/null && pwd
)}"

# -----------------------------------------------------------------------------
# jira_shim::install
# -----------------------------------------------------------------------------
jira_shim::install() {
  JIRA_SHIM_STATE="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/jira-shim.XXXXXX")"
  JIRA_SHIM_RULES="${JIRA_SHIM_STATE}/rules"
  JIRA_SHIM_REQUESTS="${JIRA_SHIM_STATE}/requests"
  : >"$JIRA_SHIM_RULES"
  : >"$JIRA_SHIM_REQUESTS"
  export JIRA_SHIM_STATE JIRA_SHIM_RULES JIRA_SHIM_REQUESTS

  # Shadow curl. A function takes precedence over the real binary on PATH for
  # the duration of the shell, which is exactly the lifetime of a bats test.
  # Invoked indirectly when code under test calls `curl`, hence SC2329.
  # shellcheck disable=SC2329
  curl() { jira_shim::_curl "$@"; }
}

# -----------------------------------------------------------------------------
# jira_shim::set_response <method> <url-glob> <fixture-path> [http_code]
#
# Register a rule. <fixture-path> may be absolute or relative to
# JIRA_SHIM_FIXTURE_DIR. Records are stored TAB-separated; URL globs and
# fixture paths used in tests do not contain tabs.
# -----------------------------------------------------------------------------
jira_shim::set_response() {
  local method="$1" url_glob="$2" fixture="$3" code="${4:-200}"
  local resolved="$fixture"
  if [[ "$fixture" != /* ]]; then
    resolved="${JIRA_SHIM_FIXTURE_DIR}/${fixture}"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(jira_shim::_upper "$method")" "$url_glob" "$resolved" "$code" "0" \
    >>"$JIRA_SHIM_RULES"
}

# -----------------------------------------------------------------------------
# jira_shim::push_response <method> <url-glob> <fixture-path> [http_code]
#
# Register a ONE-SHOT rule, consumed on the next matching request and then
# removed — so two requests to the SAME method+URL (e.g. a Story create POST
# /issue followed by a Subtask create POST /issue) can return DIFFERENT canned
# answers in order. One-shot rules are matched in registration order and take
# precedence over a standing set_response rule, so push the per-call answers
# first, then optionally set a standing fallback. Used by the US5 failed-Subtask
# test to make the FIRST POST /issue (Story) succeed and the SECOND (Subtask)
# fail.
# -----------------------------------------------------------------------------
jira_shim::push_response() {
  local method="$1" url_glob="$2" fixture="$3" code="${4:-200}"
  local resolved="$fixture"
  if [[ "$fixture" != /* ]]; then
    resolved="${JIRA_SHIM_FIXTURE_DIR}/${fixture}"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(jira_shim::_upper "$method")" "$url_glob" "$resolved" "$code" "1" \
    >>"$JIRA_SHIM_RULES"
}

# -----------------------------------------------------------------------------
# jira_shim::requests — dump recorded requests
# -----------------------------------------------------------------------------
jira_shim::requests() {
  [[ -f "$JIRA_SHIM_REQUESTS" ]] && cat "$JIRA_SHIM_REQUESTS"
}

# -----------------------------------------------------------------------------
# jira_shim::reset — clear rules + recorded requests, keep shim installed
# -----------------------------------------------------------------------------
jira_shim::reset() {
  : >"$JIRA_SHIM_RULES"
  : >"$JIRA_SHIM_REQUESTS"
}

# -----------------------------------------------------------------------------
# jira_shim::uninstall — remove the curl shadow and state
# -----------------------------------------------------------------------------
jira_shim::uninstall() {
  unset -f curl 2>/dev/null || true
  [[ -n "${JIRA_SHIM_STATE:-}" && -d "$JIRA_SHIM_STATE" ]] && rm -rf "$JIRA_SHIM_STATE"
  unset JIRA_SHIM_STATE JIRA_SHIM_RULES JIRA_SHIM_REQUESTS
}

# -----------------------------------------------------------------------------
# Internals
# -----------------------------------------------------------------------------

# Uppercase without relying on bash 4 ${var^^} so the helper is portable.
jira_shim::_upper() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

# The curl replacement. Parses argv, records the request, resolves a rule, and
# emits the fixture body + status code the way the sink expects.
jira_shim::_curl() {
  local method="GET" url="" body="" out_file="" header_dump=""
  local prev="" arg

  for arg in "$@"; do
    case "$prev" in
      -X|--request)
        method="$arg"
        prev=""
        continue
        ;;
      -d|--data|--data-raw|--data-binary|--data-ascii)
        if [[ "$arg" == @* ]]; then
          local path="${arg#@}"
          [[ -f "$path" ]] && body="$(cat "$path")"
        else
          body="$arg"
        fi
        prev=""
        continue
        ;;
      -o|--output)
        out_file="$arg"
        prev=""
        continue
        ;;
      -D|--dump-header)
        header_dump="$arg"
        prev=""
        continue
        ;;
    esac

    case "$arg" in
      http://*|https://*)
        url="$arg"
        ;;
      -*)
        prev="$arg"
        continue
        ;;
    esac
    prev=""
  done

  method="$(jira_shim::_upper "$method")"

  # Record the request (method, url, body) for assertions.
  {
    printf 'METHOD %s\n' "$method"
    printf 'URL %s\n' "$url"
    printf 'BODY %s\n' "$body"
    printf -- '---\n'
  } >>"$JIRA_SHIM_REQUESTS"

  # An empty header-dump file so a caller's -D flag is honoured.
  [[ -n "$header_dump" ]] && : >"$header_dump"

  # Resolve a matching rule (method + url glob). ONE-SHOT rules (5th field "1",
  # registered via jira_shim::push_response) take precedence and are CONSUMED on
  # match so a later request to the same method+URL gets the next queued answer;
  # standing rules (set_response) are first-match-wins and never consumed.
  local rule_method rule_glob rule_fixture rule_code rule_once
  local matched_fixture="" matched_code="200"
  local matched_once_line=0 line_no=0 found=0

  # Pass 1 — one-shot rules, in registration order.
  while IFS=$'\t' read -r rule_method rule_glob rule_fixture rule_code rule_once; do
    line_no=$(( line_no + 1 ))
    [[ -n "$rule_method" ]] || continue
    [[ "$rule_once" == "1" ]] || continue
    [[ "$method" == "$rule_method" ]] || continue
    # shellcheck disable=SC2053  # intentional glob match of url against the rule.
    if [[ "$url" == $rule_glob ]]; then
      matched_fixture="$rule_fixture"
      matched_code="$rule_code"
      matched_once_line=$line_no
      found=1
      break
    fi
  done <"$JIRA_SHIM_RULES"

  # Consume the matched one-shot rule by rewriting the rules file without it.
  if (( matched_once_line > 0 )); then
    local tmp_rules="${JIRA_SHIM_RULES}.tmp"
    awk -v drop="$matched_once_line" 'NR != drop' "$JIRA_SHIM_RULES" >"$tmp_rules"
    mv "$tmp_rules" "$JIRA_SHIM_RULES"
  fi

  # Pass 2 — standing rules (only if no one-shot matched).
  if (( found == 0 )); then
    while IFS=$'\t' read -r rule_method rule_glob rule_fixture rule_code rule_once; do
      [[ -n "$rule_method" ]] || continue
      [[ "$rule_once" == "1" ]] && continue
      [[ "$method" == "$rule_method" ]] || continue
      # shellcheck disable=SC2053  # intentional glob match of url against the rule.
      if [[ "$url" == $rule_glob ]]; then
        matched_fixture="$rule_fixture"
        matched_code="$rule_code"
        break
      fi
    done <"$JIRA_SHIM_RULES"
  fi

  local payload=""
  if [[ -n "$matched_fixture" && -f "$matched_fixture" ]]; then
    payload="$(cat "$matched_fixture")"
  elif [[ -n "$matched_fixture" ]]; then
    printf 'jira-shim: fixture not found: %s\n' "$matched_fixture" >&2
    matched_code="000"
  else
    # No rule matched — emulate curl reaching an endpoint with no canned answer.
    printf 'jira-shim: no rule for %s %s\n' "$method" "$url" >&2
    matched_code="000"
  fi

  if [[ -n "$out_file" ]]; then
    # Body to the -o target; status code to stdout (the sink's read pattern).
    printf '%s' "$payload" >"$out_file"
    printf '%s\n' "$matched_code"
  else
    # Body then a trailing newline + status, matching `-w '\n%{http_code}\n'`.
    printf '%s' "$payload"
    printf '\n%s\n' "$matched_code"
  fi
}
