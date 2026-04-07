# Security Standards

These standards define the minimum security bar for all projects. Based on OWASP Top 10 (2021), CWE Top 25 (2023), and NIST Secure Software Development Framework.

## Input Validation

### Rule: Never trust external input.
External input includes: HTTP request parameters, headers, cookies, file uploads, environment variables read at runtime, data from external APIs, database records that originated from user input.

- **SQL**: Parameterized queries only. No string interpolation, f-strings, or concatenation.
  ```python
  # WRONG
  db.execute(f"SELECT * FROM users WHERE id = {user_id}")
  # RIGHT
  db.execute("SELECT * FROM users WHERE id = ?", (user_id,))
  ```
- **OS commands**: Argument lists only. No `shell=True` with interpolated strings.
  ```python
  # WRONG
  subprocess.run(f"ffmpeg -i {filepath}", shell=True)
  # RIGHT
  subprocess.run(["ffmpeg", "-i", filepath])
  ```
- **HTML**: Framework auto-escaping must be active. No `dangerouslySetInnerHTML`, `v-html`, or `| safe` without explicit sanitization (DOMPurify or equivalent).
- **File paths**: Validate against traversal. Resolve to absolute path and verify it's within the expected directory.
  ```python
  resolved = Path(user_input).resolve()
  if not resolved.is_relative_to(ALLOWED_DIR):
      raise ValueError("Invalid path")
  ```
- **URLs**: Validate scheme (http/https only). Don't allow `file://`, `javascript:`, or other dangerous schemes.
- **Regular expressions**: Bound user-supplied regex with timeout or reject complex patterns to prevent ReDoS.

## Authentication and Authorization

### Secrets Management
- **Never hardcode secrets.** API keys, passwords, tokens, signing keys must come from environment variables or a secrets manager.
- **Never log secrets.** Ensure passwords, tokens, and keys are redacted from all log output.
- **Never commit secrets.** `.env`, credential files, private keys must be in `.gitignore`. If accidentally committed, rotate immediately — removing from git history is not enough.
- **Use strong randomness.** Session tokens, API keys, CSRF tokens must use `secrets` module (Python) or `crypto.randomBytes` (Node), never `Math.random()` or `random.random()`.

### Authentication
- **Passwords**: Hash with bcrypt (cost factor >= 12) or argon2id. Never MD5, SHA-1, or plain SHA-256.
- **Session tokens**: Minimum 128 bits of entropy, transmitted over HTTPS only, with `HttpOnly`, `Secure`, `SameSite` cookie flags.
- **JWT**: Validate algorithm (reject `none`), verify signature, check expiration, check issuer. Use a well-maintained library — don't parse JWTs manually.
- **Rate limiting**: Authentication endpoints must have rate limiting (e.g., 10 attempts per minute per IP). Account lockout or exponential backoff after repeated failures.

### Authorization
- **Default deny**: Endpoints are protected by default. Public endpoints must be explicitly marked.
- **Object-level authorization**: Verify the requester owns or has access to the specific resource, not just that they're authenticated.
  ```python
  # WRONG - only checks auth
  video = get_video(video_id)
  # RIGHT - checks ownership
  video = get_video(video_id)
  if video.owner_id != current_user.id:
      raise HTTPException(403)
  ```
- **No client-side authorization**: Hiding a button is not access control. The server must enforce permissions.
- **CORS**: Specific origin allowlist. Never `Access-Control-Allow-Origin: *` with credentials.

## Data Protection

### In Transit
- **HTTPS everywhere**: All external communication over TLS 1.2+.
- **No mixed content**: HTTPS pages must not load HTTP resources.
- **Certificate validation**: Never disable TLS verification (`verify=False`) in production.

### At Rest
- **Encrypt sensitive data**: PII, credentials, and health/financial data should be encrypted at rest if the storage backend doesn't provide encryption.
- **Minimize collection**: Don't store data you don't need. Don't log request bodies containing sensitive fields.
- **Retention**: Define and enforce retention periods. Old data should be purged automatically.

### In Responses
- **Don't leak internals**: API error responses must not include stack traces, SQL queries, file paths, or system information.
- **Minimize response data**: Only return fields the client needs. Don't return entire database rows with internal columns.
- **Security headers** (set at the web server / framework level):
  - `Content-Security-Policy`: Restrict script sources
  - `X-Content-Type-Options: nosniff`
  - `X-Frame-Options: DENY` (or `SAMEORIGIN` if framing is needed)
  - `Strict-Transport-Security: max-age=31536000` (HTTPS-only sites)
  - `Referrer-Policy: strict-origin-when-cross-origin`

## Dependency Management

- **Pin versions**: Use exact versions in lock files. Floating ranges (`^`, `~`) in manifest files are acceptable only with a lock file.
- **Audit regularly**: Run `npm audit` / `pip audit` / equivalent before merging PRs that add or update dependencies.
- **Minimal dependencies**: Don't add a package for something that's 10 lines of code. Every dependency is an attack surface.
- **Review new dependencies**: Before adding a dependency, check:
  - Is it actively maintained? (commits in last 6 months)
  - Does it have known vulnerabilities? (GitHub advisories, Snyk)
  - Is it widely used? (download count, stars are rough signals)
  - What permissions does it need? (filesystem, network, native code)

## File Handling

- **Upload validation**: Check file type (magic bytes, not just extension), enforce size limits, scan for malware if feasible.
- **Storage isolation**: Uploaded files must not be stored in a directory that's served statically without access control.
- **Filename sanitization**: Never use user-provided filenames directly. Generate UUIDs or sanitize aggressively (strip path separators, limit characters).
- **Temporary files**: Create in OS temp directory with restrictive permissions. Clean up on process exit.

## Error Handling and Logging

- **No stack traces in responses**: Catch exceptions at the framework level and return generic error messages. Log the full trace server-side.
- **Structured logging**: Use structured formats (JSON) with consistent fields. Include request ID for correlation.
- **Sensitive data in logs**: Never log passwords, tokens, credit card numbers, or PII. If you must log a request, redact sensitive fields.
- **Audit trail**: Authentication events (login, logout, failed attempts), authorization failures, and data modifications should be logged with timestamps and actor identity.

## Cryptography

- **Don't roll your own crypto.** Use established libraries (OpenSSL, libsodium, Web Crypto API).
- **Hashing**: SHA-256 or better for integrity. bcrypt/argon2id for passwords. Never MD5 or SHA-1 for security purposes.
- **Encryption**: AES-256-GCM for symmetric. RSA-2048+ or Ed25519 for asymmetric.
- **Random generation**: `secrets` (Python), `crypto.randomBytes` (Node), `crypto.getRandomValues` (browser). Never `Math.random()` for security.
- **Key management**: Rotate keys periodically. Don't share keys across environments (dev/staging/prod).
