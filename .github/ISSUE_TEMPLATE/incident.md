---
name: Incident
about: Something broke in a deployed environment
title: '[INCIDENT] <one line: what was broken, where>'
labels: 'P0-Blocker, epic:ci-cd'
assignees: ''
---

> Fill this in **after** service is restored. Restoring first is correct; the
> write-up is what stops it happening again.

## Summary

<!-- One or two sentences: what was broken, for whom, for how long. -->

| Field                 | Value                          |
| --------------------- | ------------------------------ |
| Environment           | staging / production           |
| Detected at           |                                |
| Restored at           |                                |
| Duration              |                                |
| Detected by           | a monitor / a user / by chance |
| Image tag at the time |                                |

## Impact

<!-- Who could not do what. "The site was down" is less useful than "students
     could not log in for 40 minutes". -->

## Timeline

<!-- UTC. Include the wrong turns — they are the most useful part for whoever
     reads this next time. -->

| Time | Event |
| ---- | ----- |
|      |       |

## What actually fixed it

<!-- The specific action. Not "we restarted things". -->

## Root cause

<!-- The cause, not the symptom. "The disk filled" is a symptom; "container
     logs had no max-size limit on that service" is a cause. -->

## What would have caught this earlier

<!-- A smoke-test assertion, a healthcheck, a CI gate, an alert. This is the
     step that gets skipped, and the only one that stops a recurrence. -->

## Actions

| #   | Action | Owner | Due |
| --- | ------ | ----- | --- |
| 1   |        |       |     |

- [ ] Raised at the next retrospective
- [ ] The check that would have caught it is implemented and merged
