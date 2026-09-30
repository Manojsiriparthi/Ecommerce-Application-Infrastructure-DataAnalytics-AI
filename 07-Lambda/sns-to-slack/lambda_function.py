"""
SNS → Slack / PagerDuty Forwarder Lambda
Receives CloudWatch Alarm SNS notifications and posts to Slack and/or PagerDuty.

ENVIRONMENT VARIABLES:
  SLACK_WEBHOOK_URL      — https://hooks.slack.com/services/...
  SLACK_CHANNEL          — #alerts-prod
  PAGERDUTY_ROUTING_KEY  — 32-char PagerDuty integration key (optional)
  ENVIRONMENT            — prod
  PROJECT_NAME           — pip-project-ecommerce

SETUP:
  Slack:  api.slack.com/apps → Incoming Webhooks → copy URL → set env var
  PD:     PagerDuty → Services → Events API v2 integration → copy key
"""

import json
import logging
import os
import urllib.request
import urllib.parse
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

SLACK_WEBHOOK_URL     = os.environ.get("SLACK_WEBHOOK_URL", "")
SLACK_CHANNEL         = os.environ.get("SLACK_CHANNEL", "#alerts-prod")
PAGERDUTY_ROUTING_KEY = os.environ.get("PAGERDUTY_ROUTING_KEY", "")
ENVIRONMENT           = os.environ.get("ENVIRONMENT", "prod")
PROJECT               = os.environ.get("PROJECT_NAME", "pip-project-ecommerce")

COLORS   = {"ALARM": "#FF0000", "OK": "#36A64F", "INSUFFICIENT_DATA": "#FFA500"}
EMOJIS   = {"ALARM": "🚨",     "OK": "✅",       "INSUFFICIENT_DATA": "⚠️"}
PD_SEV   = {"ALARM": "critical","OK": "info",    "INSUFFICIENT_DATA": "warning"}
PD_ACT   = {"ALARM": "trigger", "OK": "resolve", "INSUFFICIENT_DATA": "trigger"}


def parse_alarm(sns_record: dict) -> dict:
    try:
        alarm = json.loads(sns_record.get("Message", "{}"))
    except Exception:
        alarm = {}
    return {
        "name":       alarm.get("AlarmName",        sns_record.get("Subject", "Unknown")),
        "desc":       alarm.get("AlarmDescription", "No description"),
        "state":      alarm.get("NewStateValue",    "UNKNOWN"),
        "old_state":  alarm.get("OldStateValue",    "UNKNOWN"),
        "reason":     alarm.get("NewStateReason",   "No reason"),
        "time":       alarm.get("StateChangeTime",  datetime.now(timezone.utc).isoformat()),
        "namespace":  alarm.get("Trigger", {}).get("Namespace", ""),
        "metric":     alarm.get("Trigger", {}).get("MetricName", ""),
        "dims":       alarm.get("Trigger", {}).get("Dimensions", []),
        "account":    alarm.get("AWSAccountId", ""),
        "raw":        alarm,
    }


def http_post(url: str, payload: dict) -> tuple:
    data = json.dumps(payload).encode("utf-8")
    req  = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except Exception as ex:
        return 0, str(ex)


def send_slack(alarm: dict) -> bool:
    if not SLACK_WEBHOOK_URL:
        logger.info("SLACK_WEBHOOK_URL not set — skipping")
        return False

    state  = alarm["state"]
    color  = COLORS.get(state, "#808080")
    emoji  = EMOJIS.get(state, "❓")
    dims   = ", ".join(f"{d.get('name')}={d.get('value')}" for d in alarm["dims"])
    cw_url = (
        f"https://console.aws.amazon.com/cloudwatch/home?region=us-east-1"
        f"#alarmsV2:alarm/{urllib.parse.quote(alarm['name'])}"
    )

    payload = {
        "channel":    SLACK_CHANNEL,
        "username":   f"CloudWatch | {PROJECT}",
        "icon_emoji": ":aws:",
        "attachments": [{
            "color":  color,
            "blocks": [
                {
                    "type": "header",
                    "text": {"type": "plain_text", "text": f"{emoji} {state} — {alarm['name']}"},
                },
                {
                    "type": "section",
                    "fields": [
                        {"type": "mrkdwn", "text": f"*Environment:*\n{ENVIRONMENT}"},
                        {"type": "mrkdwn", "text": f"*Previous State:*\n{alarm['old_state']}"},
                        {"type": "mrkdwn", "text": f"*Metric:*\n{alarm['namespace']} / {alarm['metric']}"},
                        {"type": "mrkdwn", "text": f"*Dimensions:*\n{dims or 'N/A'}"},
                    ],
                },
                {
                    "type": "section",
                    "text": {"type": "mrkdwn", "text": f"*Reason:*\n{alarm['reason']}"},
                },
                {
                    "type": "section",
                    "text": {"type": "mrkdwn", "text": f"*Description:*\n{alarm['desc']}"},
                },
                {
                    "type": "actions",
                    "elements": [{
                        "type":  "button",
                        "text":  {"type": "plain_text", "text": "View in CloudWatch"},
                        "url":   cw_url,
                        "style": "danger" if state == "ALARM" else "primary",
                    }],
                },
            ],
        }],
    }

    status, body = http_post(SLACK_WEBHOOK_URL, payload)
    if status == 200:
        logger.info("Slack notification sent successfully")
        return True
    else:
        logger.error(f"Slack notification failed: HTTP {status} — {body}")
        return False


def send_pagerduty(alarm: dict) -> bool:
    if not PAGERDUTY_ROUTING_KEY:
        logger.info("PAGERDUTY_ROUTING_KEY not set — skipping")
        return False

    state  = alarm["state"]
    dims   = {d.get("name"): d.get("value") for d in alarm["dims"]}

    payload = {
        "routing_key":  PAGERDUTY_ROUTING_KEY,
        "event_action": PD_ACT.get(state, "trigger"),
        "dedup_key":    f"{PROJECT}-{alarm['name']}",   # group same alarm
        "payload": {
            "summary":   f"[{ENVIRONMENT}] {alarm['name']} — {state}",
            "source":    f"aws-cloudwatch-{ENVIRONMENT}",
            "severity":  PD_SEV.get(state, "warning"),
            "timestamp": alarm["time"],
            "custom_details": {
                "alarm_description": alarm["desc"],
                "reason":            alarm["reason"],
                "namespace":         alarm["namespace"],
                "metric":            alarm["metric"],
                "dimensions":        dims,
                "environment":       ENVIRONMENT,
                "project":           PROJECT,
                "old_state":         alarm["old_state"],
            },
        },
    }

    status, body = http_post("https://events.pagerduty.com/v2/enqueue", payload)
    if status in (200, 202):
        logger.info(f"PagerDuty event sent (action={PD_ACT.get(state)})")
        return True
    else:
        logger.error(f"PagerDuty failed: HTTP {status} — {body}")
        return False


def lambda_handler(event: dict, context) -> dict:
    logger.info(f"Received event: {json.dumps(event)}")

    results = []

    for record in event.get("Records", []):
        if record.get("EventSource") != "aws:sns":
            logger.warning(f"Non-SNS record skipped: {record.get('EventSource')}")
            continue

        sns_msg = record["Sns"]
        alarm   = parse_alarm(sns_msg)

        logger.info(
            f"Processing alarm: {alarm['name']} | "
            f"State: {alarm['old_state']} → {alarm['state']} | "
            f"Reason: {alarm['reason'][:100]}"
        )

        slack_ok = send_slack(alarm)
        pd_ok    = send_pagerduty(alarm)

        results.append({
            "alarm":            alarm["name"],
            "state":            alarm["state"],
            "slack_sent":       slack_ok,
            "pagerduty_sent":   pd_ok,
        })

    logger.info(f"Processed {len(results)} alarm(s)")
    return {"statusCode": 200, "results": results}
