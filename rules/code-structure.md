# Code Structure Standards

These standards ensure codebases remain maintainable, navigable, and agent-friendly. They apply to all projects unless overridden in `.agents/config.yml`.

## File Organization

### Size Limits
| Metric | Target | Hard Max | Rationale |
|--------|--------|----------|-----------|
| File length | 300 lines | 400 | AI tools degrade past ~300 lines (Cursor fast-apply breaks, attention drops). Split at 300, never exceed 400. |
| Function/method length | 30 lines | 50 | Google recommends 40, Linux kernel 48. 30 keeps functions reviewable in one screen. |
| Component render body | 60 lines JSX | 80 | Complex render trees should be split into sub-components |
| Parameters per function | 4 | 6 | More than 4 signals the function does too much, or needs an options object |
| PR diff size | 300 lines | 500 | AI review quality drops sharply beyond 400 lines of diff |
| Files per task | 10 | 20 | Most AI tools cap effective working sets at 10-20 files |

When a file approaches 250 lines, plan a split. Don't wait until it hits 300 and every change triggers a refactor.

### File Responsibilities
- **One module = one concept.** A file should be describable in one sentence without "and."
  - Good: "Handles video streaming with HTTP range requests"
  - Bad: "Handles video streaming and manages share links and tracks analytics"
- **Index files are for re-exports only.** No logic in `index.ts` / `__init__.py`.
- **Keep related code close.** A component's styles, types, and hooks can live next to it. Don't force everything into global directories.

### Naming
- Files: `kebab-case` for components/modules, `camelCase` for utilities/hooks.
- Functions: verb-first (`fetchUser`, `validateInput`, `renderHeader`). A reader should know what it does from the name alone.
- Boolean variables: `is`/`has`/`should` prefix (`isLoading`, `hasPermission`).
- Constants: `UPPER_SNAKE_CASE` for true constants, `camelCase` for derived values.
- No abbreviations unless universally understood (`id`, `url`, `api` are fine; `usr`, `mgr`, `svc` are not).

## Type Safety

### TypeScript
- `strict: true` in tsconfig. No exceptions.
- No `any`. Use `unknown` and narrow, or define a proper type.
- No type assertions (`as`) unless interfacing with untyped external APIs — and add a comment explaining why.
- Prefer `interface` for object shapes, `type` for unions/intersections/aliases.
- API response types should be defined once and shared — not duplicated across call sites.

### Python
- Type hints on all function signatures (parameters and return types).
- Use `from __future__ import annotations` for forward references.
- Pydantic models for API request/response shapes.
- No bare `except:` — always catch specific exceptions.

## Code Patterns

### Don't Repeat Yourself (Carefully)
- Extract shared logic into a utility when the same pattern appears **three or more times**.
- Two similar blocks are fine — premature abstraction is worse than a little duplication.
- When extracting, the shared utility should be genuinely reusable, not a leaky abstraction with special cases.

### Error Handling
- Validate at system boundaries (user input, API responses, file I/O). Trust internal code.
- Errors should be actionable — include what went wrong, what the input was, and what to do.
- Don't swallow errors silently. At minimum, log them.
- Use typed error responses from APIs, not generic 500s with stack traces.

### State Management (Frontend)
- Component state for UI-only concerns (open/closed, input values).
- Shared stores for data that multiple components need.
- URL state for anything that should be deep-linkable or survive refresh.
- No prop drilling beyond 2 levels — use context or a store.

### Database
- New queries with WHERE or JOIN on non-indexed columns must add an index.
- Migrations must be additive (no DROP COLUMN without a deprecation cycle).
- Schema changes must be reflected in both the migration file and the base schema.
- Use parameterized queries exclusively — no string interpolation of user input.

## Import Organization
Group imports in this order, separated by blank lines:
1. Standard library / language built-ins
2. Third-party packages
3. Local/project imports

Within each group, sort alphabetically.

## Comments
- **Do not add comments that restate the code.** `// increment counter` above `counter++` is noise.
- **Do comment the WHY** when it's not obvious from the code. Business rules, workarounds, non-obvious constraints.
- **TODO comments must reference an issue number.** `// TODO: fix this` is banned. `// TODO(#123): handle pagination` is acceptable.
- **Do not leave commented-out code.** It's in git history if you need it.

## Testing
- Tests should be independent — no shared mutable state between test cases.
- Test names describe the behavior: `it('returns 404 when video not found')`, not `it('test1')`.
- Test the behavior, not the implementation. Don't assert on internal state.
- One assertion per test is ideal, but multiple related assertions in one test are fine.
