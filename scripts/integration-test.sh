#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Ask the Alert — Integration Test Script
# Tests the full demo flow: backend health → device reg →
# alert → telemetry → metrics → clusters → update → satisfaction
#
# Usage:
#   chmod +x scripts/integration-test.sh
#   ./scripts/integration-test.sh [BASE_URL] [AUTH_SECRET]
#
# Defaults:
#   BASE_URL:    http://localhost:3001
#   AUTH_SECRET: change-me-on-hackathon-day
# ─────────────────────────────────────────────────────────────

set -euo pipefail

BASE_URL="${1:-http://localhost:3001}"
AUTH_SECRET="${2:-change-me-on-hackathon-day}"
INCIDENT_CODE="INT-TEST-$(date +%s)"
DEVICE_TOKEN="integration_test_$(date +%s)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

PASS=0
FAIL=0
TOTAL=0

# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────

check() {
    local name="$1"
    local expected_status="$2"
    shift 2
    local response

    TOTAL=$((TOTAL + 1))

    # Execute curl and capture HTTP status code
    response=$(curl -s -o /tmp/integration_response.json -w "%{http_code}" "$@" 2>/dev/null || echo "000")

    if [ "$response" = "$expected_status" ]; then
        echo -e "  ${GREEN}✓${NC} ${name} (HTTP ${response})"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} ${name} — expected HTTP ${expected_status}, got ${response}"
        if [ -f /tmp/integration_response.json ]; then
            echo -e "    Response: $(cat /tmp/integration_response.json | head -c 200)"
        fi
        FAIL=$((FAIL + 1))
        return 1
    fi
}

check_json_field() {
    local name="$1"
    local field="$2"
    local expected="$3"

    TOTAL=$((TOTAL + 1))

    if [ -f /tmp/integration_response.json ]; then
        local actual
        actual=$(python3 -c "import json; d=json.load(open('/tmp/integration_response.json')); print(d.get('${field}',''))" 2>/dev/null || echo "")

        if [ "$actual" = "$expected" ]; then
            echo -e "  ${GREEN}✓${NC} ${name} (${field} = ${expected})"
            PASS=$((PASS + 1))
            return 0
        else
            echo -e "  ${RED}✗${NC} ${name} — expected ${field}=${expected}, got ${actual}"
            FAIL=$((FAIL + 1))
            return 1
        fi
    else
        echo -e "  ${RED}✗${NC} ${name} — no response file"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

header() {
    echo ""
    echo -e "${CYAN}━━━ $1 ━━━${NC}"
}

# ─────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────

echo -e "${YELLOW}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║   Ask the Alert — Integration Test Suite         ║${NC}"
echo -e "${YELLOW}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${YELLOW}║ Backend:  ${BASE_URL}${NC}"
echo -e "${YELLOW}║ Incident: ${INCIDENT_CODE}${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════════╝${NC}"

# ── 1. Health Check ──────────────────────────────────────────

header "1. Health Check"

check "GET /health returns 200" "200" \
    "${BASE_URL}/health"

check_json_field "Health status is ok" "status" "ok"

# ── 2. Device Registration ───────────────────────────────────

header "2. Device Registration"

check "POST /devices registers token" "200" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"deviceToken\":\"${DEVICE_TOKEN}\",\"environment\":\"development\",\"label\":\"Integration Test\"}" \
    "${BASE_URL}/devices"

# Duplicate registration should succeed or return 409
check "POST /devices (duplicate) tolerates re-registration" "200" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"deviceToken\":\"${DEVICE_TOKEN}\",\"environment\":\"development\",\"label\":\"Integration Test\"}" \
    "${BASE_URL}/devices"

# ── 3. Send Alert ────────────────────────────────────────────

header "3. Send Alert (creates incident)"

check "POST /alerts creates alert" "200" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AUTH_SECRET}" \
    -d "{
        \"incidentCode\": \"${INCIDENT_CODE}\",
        \"title\": \"Integration Test Alert\",
        \"severity\": \"warning\",
        \"body\": \"This is an automated integration test alert.\",
        \"region\": \"Test Region\",
        \"targeting\": { \"mode\": \"all\" }
    }" \
    "${BASE_URL}/alerts"

# ── 4. Telemetry Events ─────────────────────────────────────

header "4. Telemetry Events"

# Record received event
check "POST /telemetry (received event)" "200" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{
        \"events\": [{
            \"eventId\": \"$(uuidgen || echo test-recv-1)\",
            \"incidentCode\": \"${INCIDENT_CODE}\",
            \"eventType\": \"received\",
            \"deviceTimestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
            \"consentGiven\": true,
            \"payload\": {}
        }]
    }" \
    "${BASE_URL}/telemetry"

# Record opened event
check "POST /telemetry (opened event)" "200" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{
        \"events\": [{
            \"eventId\": \"$(uuidgen || echo test-open-1)\",
            \"incidentCode\": \"${INCIDENT_CODE}\",
            \"eventType\": \"opened\",
            \"deviceTimestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
            \"consentGiven\": true,
            \"payload\": {}
        }]
    }" \
    "${BASE_URL}/telemetry"

# Record spoke event
check "POST /telemetry (spoke event)" "200" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{
        \"events\": [{
            \"eventId\": \"$(uuidgen || echo test-spoke-1)\",
            \"incidentCode\": \"${INCIDENT_CODE}\",
            \"eventType\": \"spoke\",
            \"deviceTimestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
            \"consentGiven\": true,
            \"payload\": {}
        }]
    }" \
    "${BASE_URL}/telemetry"

# Record question events with different intents
check "POST /telemetry (question: shelter)" "200" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{
        \"events\": [{
            \"eventId\": \"$(uuidgen || echo test-q-1)\",
            \"incidentCode\": \"${INCIDENT_CODE}\",
            \"eventType\": \"question\",
            \"deviceTimestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
            \"consentGiven\": true,
            \"payload\": {
                \"shortText\": \"Where should I shelter during the tornado?\",
                \"intentLabel\": \"shelter_guidance\"
            }
        }]
    }" \
    "${BASE_URL}/telemetry"

check "POST /telemetry (question: driving)" "200" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{
        \"events\": [{
            \"eventId\": \"$(uuidgen || echo test-q-2)\",
            \"incidentCode\": \"${INCIDENT_CODE}\",
            \"eventType\": \"question\",
            \"deviceTimestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
            \"consentGiven\": true,
            \"payload\": {
                \"shortText\": \"I am driving on the highway. What should I do?\",
                \"intentLabel\": \"road_closures_travel\",
                \"actionBlocker\": \"driving\"
            }
        }]
    }" \
    "${BASE_URL}/telemetry"

check "POST /telemetry (question: condo)" "200" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{
        \"events\": [{
            \"eventId\": \"$(uuidgen || echo test-q-3)\",
            \"incidentCode\": \"${INCIDENT_CODE}\",
            \"eventType\": \"question\",
            \"deviceTimestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
            \"consentGiven\": true,
            \"payload\": {
                \"shortText\": \"I live in a condo on the 15th floor. Is that safe?\",
                \"intentLabel\": \"shelter_guidance\",
                \"actionBlocker\": \"condo\"
            }
        }]
    }" \
    "${BASE_URL}/telemetry"

# Record satisfaction event
check "POST /telemetry (satisfaction: yes)" "200" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{
        \"events\": [{
            \"eventId\": \"$(uuidgen || echo test-sat-1)\",
            \"incidentCode\": \"${INCIDENT_CODE}\",
            \"eventType\": \"satisfaction\",
            \"deviceTimestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
            \"consentGiven\": true,
            \"payload\": {
                \"satisfactionYesNo\": true
            }
        }]
    }" \
    "${BASE_URL}/telemetry"

# ── 5. Incidents ─────────────────────────────────────────────

header "5. Incident Retrieval"

check "GET /incidents lists incidents" "200" \
    -H "Authorization: Bearer ${AUTH_SECRET}" \
    "${BASE_URL}/incidents"

check "GET /incidents/:code returns incident detail" "200" \
    -H "Authorization: Bearer ${AUTH_SECRET}" \
    "${BASE_URL}/incidents/${INCIDENT_CODE}"

# ── 6. Metrics ───────────────────────────────────────────────

header "6. Metrics"

check "GET /metrics/:code returns metrics" "200" \
    -H "Authorization: Bearer ${AUTH_SECRET}" \
    "${BASE_URL}/metrics/${INCIDENT_CODE}"

check "GET /metrics/:code/timeline returns timeline" "200" \
    -H "Authorization: Bearer ${AUTH_SECRET}" \
    "${BASE_URL}/metrics/${INCIDENT_CODE}/timeline"

# ── 7. Clusters ──────────────────────────────────────────────

header "7. Question Clusters"

# Refresh clusters first
check "POST /clusters/:code/refresh generates clusters" "200" \
    -X POST \
    -H "Authorization: Bearer ${AUTH_SECRET}" \
    "${BASE_URL}/clusters/${INCIDENT_CODE}/refresh"

check "GET /clusters/:code returns clusters" "200" \
    -H "Authorization: Bearer ${AUTH_SECRET}" \
    "${BASE_URL}/clusters/${INCIDENT_CODE}"

# ── 8. Satisfaction ──────────────────────────────────────────

header "8. Satisfaction"

check "GET /satisfaction/:code returns satisfaction stats" "200" \
    -H "Authorization: Bearer ${AUTH_SECRET}" \
    "${BASE_URL}/satisfaction/${INCIDENT_CODE}"

check "GET /satisfaction/:code/blockers returns blockers" "200" \
    -H "Authorization: Bearer ${AUTH_SECRET}" \
    "${BASE_URL}/satisfaction/${INCIDENT_CODE}/blockers"

# ── 9. Publish Update ────────────────────────────────────────

header "9. Publish Update"

check "POST /updates publishes update" "200" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${AUTH_SECRET}" \
    -d "{
        \"incidentCode\": \"${INCIDENT_CODE}\",
        \"updateText\": \"Updated: The tornado warning has been downgraded to a watch. Continue to monitor local media.\",
        \"source\": \"authority_console\"
    }" \
    "${BASE_URL}/updates"

# ── 10. Consent ──────────────────────────────────────────────

header "10. Consent Policy"

check "GET /consent/policy returns consent policy" "200" \
    "${BASE_URL}/consent/policy"

# ── 11. Auth Rejection ───────────────────────────────────────

header "11. Auth Rejection (protected endpoints without auth)"

check "GET /incidents without auth returns 401" "401" \
    "${BASE_URL}/incidents"

check "POST /alerts without auth returns 401" "401" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"incidentCode\":\"test\"}" \
    "${BASE_URL}/alerts"

check "GET /metrics without auth returns 401" "401" \
    "${BASE_URL}/metrics/${INCIDENT_CODE}"

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}━━━ Summary ━━━${NC}"
echo ""
echo -e "  Total:  ${TOTAL}"
echo -e "  ${GREEN}Passed: ${PASS}${NC}"
if [ $FAIL -gt 0 ]; then
    echo -e "  ${RED}Failed: ${FAIL}${NC}"
else
    echo -e "  Failed: ${FAIL}"
fi
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ALL TESTS PASSED                                ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
    exit 0
else
    echo -e "${RED}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║   ${FAIL} TEST(S) FAILED                              ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════╝${NC}"
    exit 1
fi
