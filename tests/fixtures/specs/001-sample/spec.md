# Feature Specification: Sample Spec

**Branch**: `001-sample`
**Status**: Draft
**Owner**: dev-sample@example.com

## Summary

A small placeholder spec used to drive parser and workstate tests for the
spec-kit-jira-sync bridge. It carries no real coordinates and exists only as
on-disk fixture input.

## User Scenarios

- As a test, I parse this spec dir into the neutral `workstate` shape.
- As a test, I assert the spec Story is keyed by label `speckit-spec:001`.

## Requirements

- FR-001: The parser MUST read `spec.md`, `plan.md`, and `tasks.md`.
- FR-002: The parser MUST derive phases from the `## Phase N:` headings in
  `tasks.md` and their checkbox task state.
