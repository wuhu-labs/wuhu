#!/bin/bash
set -euo pipefail

# Check TestFlight Build Status
# Usage: ./scripts/check-testflight.sh [--watch] [--json]

# ASC API credentials
ASC_KEY_ID="3U39ZA4G2A"
ASC_ISSUER_ID="d782de6f-d166-4df4-8124-a96926af646b"
ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
BUNDLE_ID="ms.liu.wuhu.ios"

WATCH=false
JSON_OUTPUT=false
for arg in "$@"; do
    case $arg in
        --watch) WATCH=true ;;
        --json) JSON_OUTPUT=true ;;
    esac
done

# Generate JWT token for ASC API
generate_jwt() {
    local now=$(date +%s)
    local exp=$((now + 1200))  # 20 min expiry
    
    local header=$(echo -n '{"alg":"ES256","kid":"'"$ASC_KEY_ID"'","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    local payload=$(echo -n '{"iss":"'"$ASC_ISSUER_ID"'","iat":'"$now"',"exp":'"$exp"',"aud":"appstoreconnect-v1"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    
    local signature=$(echo -n "${header}.${payload}" | openssl dgst -sha256 -sign "$ASC_KEY_PATH" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    
    echo "${header}.${payload}.${signature}"
}

check_builds() {
    local token=$(generate_jwt)
    
    # Get app ID first
    local app_response=$(curl -s -H "Authorization: Bearer $token" \
        "https://api.appstoreconnect.apple.com/v1/apps?filter[bundleId]=$BUNDLE_ID")
    
    local app_id=$(echo "$app_response" | jq -r '.data[0].id // empty')
    
    if [ -z "$app_id" ]; then
        echo "❌ Could not find app with bundle ID: $BUNDLE_ID"
        exit 1
    fi
    
    # Get recent builds
    local builds_response=$(curl -s -H "Authorization: Bearer $token" \
        "https://api.appstoreconnect.apple.com/v1/builds?filter[app]=$app_id&limit=5&sort=-uploadedDate")
    
    if [ "$JSON_OUTPUT" = true ]; then
        echo "$builds_response" | jq '.data[] | {version: .attributes.version, build: .attributes.buildNumber, state: .attributes.processingState, uploaded: .attributes.uploadedDate}'
        return
    fi
    
    echo "📱 TestFlight Builds for Wuhu ($BUNDLE_ID)"
    echo "==========================================="
    echo ""
    
    echo "$builds_response" | jq -r '.data[] | "Version: \(.attributes.version) (\(.attributes.buildNumber))\n  State: \(.attributes.processingState)\n  Uploaded: \(.attributes.uploadedDate)\n"'
}

if [ "$WATCH" = true ]; then
    echo "👀 Watching TestFlight builds (Ctrl+C to stop)..."
    echo ""
    while true; do
        clear
        check_builds
        echo ""
        echo "Last checked: $(date)"
        sleep 30
    done
else
    check_builds
fi
