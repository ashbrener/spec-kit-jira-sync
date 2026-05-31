# Implementation Plan: Sample Spec

**Branch**: `001-sample`

## Technical Context

Placeholder plan for fixture-driven tests. Pure on-disk input; no network,
no real Jira coordinates.

## Approach

1. Parse the spec dir into `workstate`.
2. Mirror the spec Story and its phase Subtasks into the tracker (mocked).

## Phases

- Phase 1 (Setup): scaffold directories and tooling.
- Phase 2 (Core): implement the parser and sink seam.
