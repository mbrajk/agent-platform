# Agent Platform

AI-driven development pipeline. Defines agent behaviors, quality standards, and reusable workflows that can be applied to any project.

## Structure

```
agents/         Agent system prompts and behavioral definitions
rules/          Quality standards enforced by review agents
workflows/      Reusable GitHub Actions workflows
templates/      Scaffolding for new projects
```

## Agents

| Agent | Trigger | Role |
|-------|---------|------|
| **Planner** | Issue labeled `ready` | Reads issue + codebase, writes implementation plan |
| **Implementer** | Plan approved | Writes code on a branch, creates draft PR |
| **Code Structure** | PR created | Reviews for maintainability, modularity, typing |
| **UX Reviewer** | PR created (UI changes) | Accessibility, responsiveness, design consistency |
| **Security Analyst** | PR created | Dependency audit, injection vectors, auth/authz |
| **Build/Test** | PR created | Compilation, lint, smoke tests |

## Pipeline

```
Issue created -> ready -> planned -> approved -> implemented -> gates -> review -> done
```

Quality gates (Code Structure, UX, Security, Build) run in parallel on the PR.
All must pass before the PR is marked ready for human review.

## Per-Project Setup

Each project repo needs:
- `.agents/config.yml` — project-specific settings
- `CLAUDE.md` — codebase context for agents
- `.github/workflows/agent-pipeline.yml` — references this repo's reusable workflows
