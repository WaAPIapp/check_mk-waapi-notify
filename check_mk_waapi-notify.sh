#!/bin/bash
# Push Notification (using WhatsApp with waapi.app)
#
# Script Name   : check_mk_waapi-notify.sh
# Description   : Send Checkmk notifications as WhatsApp messages via the WaAPI REST API
# Author        : WaAPI <info@waapi.app>
# Homepage      : https://github.com/WaAPIapp/check_mk-waapi-notify
# License       : BSD 3-Clause "New" or "Revised" License
#
# Based on the Checkmk Telegram notification script by Benedikt Filip
# (https://github.com/filipnet/checkmk-telegram-notify) and on earlier work by
# Welligton (Analista Linux4Life). Not affiliated with, endorsed or sponsored
# by WhatsApp LLC or Meta.
#
# Notification parameters (Checkmk rule, "Call with the following parameters"):
#   1  WaAPI instance ID              e.g. 123
#   2  Destination chat ID            e.g. 4915112345678@c.us or 12036...@g.us
#   3  WaAPI API token                e.g. abc123mytokenxyz789   (optional if
#                                          WAAPI_API_TOKEN is set in the
#                                          environment)
#   4  API base URL                   optional, defaults to https://waapi.app/api/v1
#
# Manual test (outside Checkmk):
#   ./check_mk_waapi-notify.sh --test <instance> <chatId> <token>
# ======================================================================================

set -uo pipefail

readonly DEFAULT_API_BASE="https://waapi.app/api/v1"
readonly CURL_MAX_TIME=25
readonly CURL_RETRIES=2

die() {
    echo "check_mk_waapi-notify: $*" >&2
    exit 2
}

# --------------------------------------------------------------------------------------
# JSON string escaping.
#
# Service output routinely contains double quotes, backslashes and newlines. Pasting it
# into a JSON body unescaped produced malformed requests and silently lost notifications,
# so every value that reaches the payload goes through here first.
# --------------------------------------------------------------------------------------
json_escape() {
    local s=${1-}
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    # Drop the remaining C0 control characters; they are illegal inside a JSON string.
    printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177'
}

# --------------------------------------------------------------------------------------
# Parameters
# --------------------------------------------------------------------------------------
TEST_MODE=0
if [ "${1-}" = "--test" ] || [ "${1-}" = "-t" ]; then
    TEST_MODE=1
    NOTIFY_PARAMETER_1="${2-}"
    NOTIFY_PARAMETER_2="${3-}"
    NOTIFY_PARAMETER_3="${4-}"
fi

instance="${NOTIFY_PARAMETER_1-}"
destination="${NOTIFY_PARAMETER_2-}"
token="${NOTIFY_PARAMETER_3-${WAAPI_API_TOKEN-}}"
api_base="${NOTIFY_PARAMETER_4-${WAAPI_API_BASE_URL-$DEFAULT_API_BASE}}"

[ -n "$instance" ]    || die "no WaAPI instance ID given (parameter 1). Exiting"
[ -n "$destination" ] || die "no destination chat ID given (parameter 2). Exiting"
[ -n "$token" ]       || die "no WaAPI API token given (parameter 3 or \$WAAPI_API_TOKEN). Exiting"

case "$destination" in
    *@c.us|*@g.us|*@newsletter) ;;
    *) die "destination '$destination' is not a valid chat ID (expected <id>@c.us, <id>@g.us or <id>@newsletter). Exiting" ;;
esac

api_base="${api_base%/}"

# --------------------------------------------------------------------------------------
# Message
# --------------------------------------------------------------------------------------
if [ "$TEST_MODE" -eq 1 ]; then
    MESSAGE=$'✅ Checkmk test notification\n\nIf you can read this, check_mk_waapi-notify is configured correctly.'
else
    if [ "${NOTIFY_WHAT-}" = "SERVICE" ]; then
        STATE="${NOTIFY_SERVICESHORTSTATE-}"
    else
        STATE="${NOTIFY_HOSTSHORTSTATE-}"
    fi

    case "$STATE" in
        OK|UP)     EMOJI=$'✅' ;;   # white heavy check mark
        WARN)      EMOJI=$'⚠️' ;;   # warning sign
        CRIT|DOWN) EMOJI=$'❌' ;;   # cross mark
        UNREACH)   EMOJI=$'⁉️' ;;   # exclamation question mark
        *)         EMOJI=$'❓' ;;   # question mark — covers UNKN and anything new
    esac

    MESSAGE="${NOTIFY_HOSTNAME-} (${NOTIFY_HOSTALIAS-})"$'\n\n'
    MESSAGE+="${EMOJI} ${NOTIFY_WHAT-} ${NOTIFY_NOTIFICATIONTYPE-}"$'\n\n'

    if [ "${NOTIFY_WHAT-}" = "SERVICE" ]; then
        MESSAGE+="${NOTIFY_SERVICEDESC-}"$'\n'
        MESSAGE+="State changed from ${NOTIFY_PREVIOUSSERVICEHARDSHORTSTATE-} to ${NOTIFY_SERVICESHORTSTATE-}"$'\n'
        MESSAGE+="${NOTIFY_SERVICEOUTPUT-}"$'\n'
    else
        MESSAGE+="State changed from ${NOTIFY_PREVIOUSHOSTHARDSHORTSTATE-} to ${NOTIFY_HOSTSHORTSTATE-}"$'\n'
        MESSAGE+="${NOTIFY_HOSTOUTPUT-}"$'\n'
    fi

    # Acknowledgements and custom notifications carry the operator's comment.
    if [ -n "${NOTIFY_NOTIFICATIONCOMMENT-}" ]; then
        MESSAGE+=$'\n'"Comment: ${NOTIFY_NOTIFICATIONCOMMENT-}"$'\n'
    fi

    [ -n "${NOTIFY_HOST_ADDRESS_4-}" ] && MESSAGE+=$'\n'"IPv4: ${NOTIFY_HOST_ADDRESS_4}"
    [ -n "${NOTIFY_HOST_ADDRESS_6-}" ] && MESSAGE+=$'\n'"IPv6: ${NOTIFY_HOST_ADDRESS_6}"

    MESSAGE+=$'\n\n'"${NOTIFY_SHORTDATETIME-} | ${OMD_SITE-}"
fi

payload="{\"chatId\":\"$(json_escape "$destination")\",\"message\":\"$(json_escape "$MESSAGE")\"}"

# --------------------------------------------------------------------------------------
# Delivery
#
# A non-zero curl exit status alone is not a sufficient success check: the API answers
# HTTP 200 for application-level failures, and it does so in two places.
#
#   "status"        did the request reach the instance
#   "data.status"   did the instance carry the action out  <- the authoritative one
#
# A malformed chat ID comes back as {"status":"success","data":{"status":"error",
# "message":"incorrect chatId format."}} — nothing was sent. The check below searches
# the whole body rather than one field, so it sees either envelope. That is deliberate,
# not incidental: parsing JSON in bash to reach data.status would need jq, which is not
# on every Checkmk site, and erring towards "report a failure" is the right bias for a
# notification plugin.
# --------------------------------------------------------------------------------------
response=$(curl --silent --show-error \
                --request POST "${api_base}/instances/${instance}/client/action/send-message" \
                --header "accept: application/json" \
                --header "authorization: Bearer ${token}" \
                --header "content-type: application/json" \
                --data-binary "$payload" \
                --max-time "$CURL_MAX_TIME" \
                --retry "$CURL_RETRIES" --retry-delay 2 --retry-connrefused \
                --write-out $'\n%{http_code}' 2>&1)
curl_rc=$?

http_code="${response##*$'\n'}"
body="${response%$'\n'*}"

if [ "$curl_rc" -ne 0 ]; then
    die "curl failed with exit code ${curl_rc}: ${body}"
fi

case "$http_code" in
    2*) ;;
    401|403) die "WaAPI rejected the API token (HTTP ${http_code}): ${body}" ;;
    404)     die "WaAPI instance ${instance} not found (HTTP 404): ${body}" ;;
    *)       die "WaAPI returned HTTP ${http_code}: ${body}" ;;
esac

case "$body" in
    *'"status":"error"'*|*'"status": "error"'*)
        die "WaAPI accepted the request but did not send the message: ${body}"
        ;;
esac

if [ "$TEST_MODE" -eq 1 ]; then
    echo "Test notification sent to ${destination} via instance ${instance}."
fi

exit 0
