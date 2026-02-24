# Security Considerations — Ask the Alert

This document outlines security measures implemented in this **hackathon project** and known limitations that must be addressed before production deployment.

## ✅ Implemented Security Measures

### 1. PII Redaction (Server-Side)
- Regex-based redaction of phone numbers, emails, SINs, addresses, names
- Applied to all `shortText` fields before storage
- See `backend/src/services/piiRedaction.ts`

### 2. Consent-Based Telemetry
- **Default: `consentGiven = false`** — requires explicit user opt-in
- Only events with `consentGiven: true` are stored
- Consent policy available at `GET /consent/policy`

### 3. CORS Restrictions
- Environment-specific origin allowlist
- Development: `localhost:3000`, `localhost:5173`
- Production: requires configuration of actual console domain
- No blanket `origin: true` in production

### 4. Rate Limiting
- Public endpoints (`/devices`, `/telemetry`, `/consent`) rate-limited
- **Development**: 1000 requests per 15 minutes per IP
- **Production**: 100 requests per 15 minutes per IP
- Uses `express-rate-limit` middleware

### 5. Console Authentication
- Protected endpoints require `Authorization: Bearer <secret>`
- Console auth secret stored in `.env` (not committed)
- SSE stream uses query token due to EventSource limitation

### 6. Helmet Security Headers
- XSS protection, content type sniffing prevention
- Referrer policy, frame options
- Standard Express.js hardening via `helmet` middleware

---

## ⚠️ Known Limitations (HACKATHON BUILD)

### 🔴 CRITICAL — Must Fix Before Production

#### 1. SSE Authentication via Query String
**Issue**: The `/stream/:incidentCode` endpoint authenticates via `?token=...` query parameter.

**Why this is dangerous**:
- Tokens leak in server logs, proxy logs, browser history
- Visible in screenshots, analytics, referrer headers
- No token rotation or expiration

**Fix for production**:
- Implement short-lived signed tokens (JWT with 5-minute expiry)
- Or use cookie-based auth with `SameSite=Strict`
- Or put SSE behind a reverse proxy that injects authentication

---

#### 2. Shared Secret Authentication
**Issue**: Console endpoints use a single shared secret (`CONSOLE_AUTH_SECRET`).

**Why this is dangerous**:
- No per-user accounts or audit trail
- Secret rotation requires coordinating all console instances
- No granular permissions (admin vs. read-only)

**Fix for production**:
- Implement proper user accounts with bcrypt password hashing
- Issue per-session JWTs after login
- Add role-based access control (RBAC)
- Enable audit logging for all admin actions

---

#### 3. PII Redaction is Regex-Based (Limited Coverage)
**Issue**: Regex patterns will miss edge cases.

**Examples of missed PII**:
- Names without prefixes: "John called 911"
- Landmarks: "near King and University intersection"
- Non-standard addresses: "behind the Walmart on Victoria"
- Embedded personal info in natural speech

**Fix for production**:
- Add text length caps (max 200 chars per event)
- Use allowlist strategy: store only `intent_label` + short summary
- Consider ML-based Named Entity Recognition (NER) for better coverage
- Enforce mandatory client-side PII stripping before transmission
- Audit stored text periodically for PII leakage

---

#### 4. No Device Authentication
**Issue**: Public endpoints (`/devices`, `/telemetry`) have no device-level auth.

**Why this is dangerous**:
- Anyone can POST fake telemetry events
- No protection against telemetry injection attacks
- Device token registration is unauthenticated

**Fix for production**:
- Implement device-level API keys or signed requests
- Use APNs device token as proof of authenticity
- Add request signing (HMAC) based on device ID + timestamp
- Validate incident codes exist before accepting telemetry

---

#### 5. Supabase Service Role Key Exposure Risk
**Issue**: Backend uses Supabase service-role key (bypasses RLS).

**Why this is dangerous**:
- If `.env` leaks, full database access is compromised
- No defense-in-depth if backend server is breached

**Fix for production**:
- Minimize service-role key usage
- Use Supabase JWT auth for user-level operations where possible
- Rotate service keys regularly
- Implement IP allowlisting on Supabase project
- Enable Supabase audit logs

---

#### 6. No Input Validation on Telemetry Text Length
**Issue**: `shortText` has no enforced maximum length.

**Why this is dangerous**:
- Attackers can send extremely long strings
- Database storage bloat, query performance degradation
- Easier to embed PII in long-form text

**Fix for production**:
- Enforce max length: 200 characters on `shortText`
- Reject requests exceeding limit (don't truncate silently)
- Add database constraint: `CHECK (length(short_text) <= 200)`

---

## 🟡 MODERATE — Recommended Improvements

### 7. No HTTPS Enforcement
**Current**: Backend runs HTTP in development.

**Fix**: Enforce HTTPS in production, redirect HTTP → HTTPS.

### 8. No SQL Injection Protection Beyond Supabase
**Current**: Supabase client handles parameterization.

**Recommendation**: Never construct raw SQL from user input. Always use Supabase client methods.

### 9. No Logging or Monitoring
**Current**: Errors logged to console, no structured logging.

**Fix for production**:
- Implement structured logging (Winston, Pino)
- Send logs to external service (Datadog, Sentry)
- Monitor rate limit hits, auth failures, PII redaction triggers

### 10. APNs Certificate Security
**Current**: APNs private key stored in `backend/certs/` directory.

**Fix**:
- Store APNs key in secrets manager (AWS Secrets Manager, HashiCorp Vault)
- Never commit `.p8` files to git (already in `.gitignore`)
- Rotate APNs keys annually

---

## 📋 Security Checklist for Production Fork

Before deploying `askthealert-private`:

- [ ] Replace `CONSOLE_AUTH_SECRET` with 32+ char random secret
- [ ] Implement user accounts and JWT-based session auth
- [ ] Add device-level API keys or request signing for telemetry
- [ ] Enforce `shortText` max length (200 chars)
- [ ] Implement short-lived SSE tokens or cookie-based SSE auth
- [ ] Enable HTTPS and HSTS headers
- [ ] Add structured logging and monitoring
- [ ] Rotate all secrets (Supabase, APNs, auth secrets)
- [ ] Set up Supabase IP allowlisting
- [ ] Implement database constraints for data validation
- [ ] Audit stored telemetry for PII leakage
- [ ] Enable Supabase Row Level Security (RLS) policies
- [ ] Document incident response plan
- [ ] Perform security audit (OWASP Top 10 checklist)

---

## 📞 Responsible Disclosure

This is a **public hackathon repository**. Known security limitations are documented here for transparency.

**If you find additional vulnerabilities**, please do NOT exploit them. Instead:
1. Open a GitHub Security Advisory (private disclosure)
2. Email the maintainer with details
3. Allow 90 days for patching before public disclosure

---

## License Note

This project is provided AS-IS for educational/hackathon purposes. The maintainers make no warranty about security or fitness for production use.
