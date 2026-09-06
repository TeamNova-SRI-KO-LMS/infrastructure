---
name: Infrastructure change
about: A change to the pipeline, containers, deployment or scripts
title: '[DDP-#NN] ci(scope): summary'
labels: 'epic:ci-cd'
assignees: ''
---

## User Story

As a [role], I want to [action] so that [benefit].

<!-- Infrastructure tickets have users too, and naming them is what stops this
     becoming "improve the pipeline" with no finish line. Usually a developer
     waiting on CI, or whoever is on call. -->

## Background / Context

- SRS Reference: NFR-<number>
- SDS Reference: Section 8 (Deployment design)
- ADR Reference: ADR-<number> (if applicable)

## Acceptance Criteria

### AC1: Happy Path

**Given** [precondition]
**When** [action]
**Then** [expected outcome]

### AC2: Failure Handling

**Given** [the step fails]
**When** [it runs]
**Then** [what happens — the build fails, the deployment rolls back, an issue
is opened]

## Blast radius

- [ ] CI only
- [ ] Staging
- [ ] Production
- [ ] The published action or images

## Verification

<!-- How this will be shown to work. "CI is green" is not verification for a
     change to CI itself. -->

- [ ] `npm run validate` passes
- [ ] The stack boots and the smoke test passes
- [ ] Verified against staging

## Rollback

<!-- How to undo this. Required for anything that touches a deployed
     environment. -->

## Estimate

Estimated: X hours
