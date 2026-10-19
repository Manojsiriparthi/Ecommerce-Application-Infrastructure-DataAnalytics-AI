"""
=============================================================================
Lambda: EBS Snapshot Backup
=============================================================================
PURPOSE:
  Takes daily EBS snapshots of all volumes attached to EKS worker nodes
  for pip-project-ecommerce. Retains snapshots for 7 days, then auto-deletes.

TRIGGER:
  EventBridge Scheduled Rule — every day at 12:00 PM UTC (5:30 PM IST)
  Cron: cron(0 12 * * ? *)

WHAT IT DOES:
  1. DISCOVER  — find all EC2 instances tagged with EKS cluster name
  2. COLLECT   — get all EBS volumes attached to those instances
  3. SNAPSHOT  — create a snapshot for each volume with descriptive tags
  4. CLEANUP   — delete snapshots older than RETENTION_DAYS (default: 7)
  5. NOTIFY    — publish summary to SNS (created count, deleted count, errors)

TAGS ON SNAPSHOTS:
  Name             — <project>-backup-<volume-id>-<date>
  Project          — pip-project-ecommerce
  Environment      — prod
  ManagedBy        — lambda-ebs-backup
  BackupDate       — 2026-09-30
  ExpiryDate       — 2026-10-07  (BackupDate + RETENTION_DAYS)
  SourceVolumeId   — vol-xxxxxxxxxxxxxxxxx
  SourceInstanceId — i-xxxxxxxxxxxxxxxxx
  ClusterName      — pip-project-ecommerce-cluster

SNAPSHOT DISCOVERY FOR CLEANUP:
  Uses tag filter ManagedBy=lambda-ebs-backup so it only deletes
  snapshots it created — never touches manually created snapshots.

ENVIRONMENT VARIABLES (set by deploy.sh):
  PROJECT_NAME    — pip-project-ecommerce
  ENVIRONMENT     — prod
  REGION          — us-east-1
  CLUSTER_NAME    — pip-project-ecommerce-cluster
  RETENTION_DAYS  — 7
  SNS_TOPIC_ARN   — arn:aws:sns:us-east-1:497149484677:pip-project-ecommerce-*
  KMS_KEY_ALIAS   — alias/pip-project-ecommerce-kms  (encrypt snapshots)

HOW TO INVOKE MANUALLY:
  aws lambda invoke \
    --function-name pip-project-ecommerce-ebs-backup \
    --payload '{}' \
    --region us-east-1 \
    response.json && cat response.json

COST ESTIMATE:
  t3.small root volume = 20GB
  3 nodes × 20GB × 7 snapshots = 420GB incremental storage
  EBS snapshot cost ≈ $0.05/GB-month → ~$21/month
  Lambda cost: < $0.01/month (daily run, <15 seconds)
=============================================================================
"""

import json
import logging
import os
from datetime import datetime, timezone, timedelta

import boto3
from botocore.exceptions import ClientError

# ── Logging ──────────────────────────────────────────────────────────────────
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ── Config ───────────────────────────────────────────────────────────────────
REGION          = os.environ.get("REGION",         "us-east-1")
PROJECT         = os.environ.get("PROJECT_NAME",   "pip-project-ecommerce")
ENVIRONMENT     = os.environ.get("ENVIRONMENT",    "prod")
CLUSTER_NAME    = os.environ.get("CLUSTER_NAME",   "pip-project-ecommerce-cluster")
RETENTION_DAYS  = int(os.environ.get("RETENTION_DAYS", "7"))
SNS_TOPIC_ARN   = os.environ.get("SNS_TOPIC_ARN",  "")
KMS_KEY_ALIAS   = os.environ.get("KMS_KEY_ALIAS",  f"alias/{PROJECT}-kms")
MANAGED_BY_TAG  = "lambda-ebs-backup"

# ── AWS Clients ───────────────────────────────────────────────────────────────
ec2 = boto3.client("ec2",  region_name=REGION)
sns = boto3.client("sns",  region_name=REGION)
kms = boto3.client("kms",  region_name=REGION)


# =============================================================================
# KMS helpers
# =============================================================================

def get_kms_key_id(alias: str) -> str:
    """Resolve KMS alias → key ID for snapshot encryption."""
    try:
        resp = kms.describe_key(KeyId=alias)
        key_id = resp["KeyMetadata"]["KeyId"]
        logger.info(f"KMS key ID: {key_id}")
        return key_id
    except ClientError as e:
        logger.warning(f"KMS describe_key failed ({alias}): {e} — using default EBS key")
        return None  # Falls back to AWS-managed EBS key


# =============================================================================
# Step 1: Discover EKS worker node instances
# =============================================================================

def get_eks_instances() -> list:
    """
    Find all EC2 instances that are EKS worker nodes for this cluster.
    Filters by the tag EKS automatically adds to all managed nodes.
    """
    logger.info(f"Discovering EKS instances for cluster: {CLUSTER_NAME}")

    paginator = ec2.get_paginator("describe_instances")
    instances = []

    # EKS node groups tag all instances with eks:cluster-name
    pages = paginator.paginate(
        Filters=[
            {"Name": "tag:eks:cluster-name",        "Values": [CLUSTER_NAME]},
            {"Name": "instance-state-name",          "Values": ["running", "stopped"]},
        ]
    )

    for page in pages:
        for reservation in page["Reservations"]:
            for instance in reservation["Instances"]:
                instances.append({
                    "instance_id":   instance["InstanceId"],
                    "instance_type": instance["InstanceType"],
                    "state":         instance["State"]["Name"],
                    "az":            instance["Placement"]["AvailabilityZone"],
                    "tags":          {t["Key"]: t["Value"] for t in instance.get("Tags", [])},
                })

    logger.info(f"Found {len(instances)} EKS instance(s)")
    for i in instances:
        name = i["tags"].get("Name", "unnamed")
        logger.info(f"  {i['instance_id']} ({i['instance_type']}) — {name} [{i['state']}]")

    return instances


# =============================================================================
# Step 2: Collect EBS volumes from instances
# =============================================================================

def get_volumes_for_instances(instances: list) -> list:
    """
    Get all EBS volumes attached to the given instances.
    Returns list of volume dicts with instance metadata.
    """
    if not instances:
        logger.warning("No instances provided — no volumes to snapshot")
        return []

    instance_ids = [i["instance_id"] for i in instances]
    instance_map = {i["instance_id"]: i for i in instances}

    logger.info(f"Collecting volumes for {len(instance_ids)} instance(s)...")

    volumes = []
    try:
        resp = ec2.describe_volumes(
            Filters=[
                {"Name": "attachment.instance-id", "Values": instance_ids},
                {"Name": "status",                  "Values": ["in-use"]},
            ]
        )
        for vol in resp["Volumes"]:
            for attachment in vol["Attachments"]:
                instance_id   = attachment["InstanceId"]
                instance_info = instance_map.get(instance_id, {})
                instance_name = instance_info.get("tags", {}).get("Name", "unnamed")

                volumes.append({
                    "volume_id":     vol["VolumeId"],
                    "volume_type":   vol["VolumeType"],
                    "size_gb":       vol["Size"],
                    "device":        attachment["Device"],
                    "instance_id":   instance_id,
                    "instance_name": instance_name,
                    "az":            vol["AvailabilityZone"],
                    "encrypted":     vol["Encrypted"],
                    "kms_key_id":    vol.get("KmsKeyId", ""),
                })
    except ClientError as e:
        logger.error(f"describe_volumes failed: {e}")
        raise

    logger.info(f"Found {len(volumes)} volume(s) to snapshot")
    for v in volumes:
        logger.info(
            f"  {v['volume_id']} ({v['size_gb']}GB {v['volume_type']}) "
            f"on {v['instance_id']} [{v['device']}]"
        )

    return volumes


# =============================================================================
# Step 3: Create snapshots
# =============================================================================

def create_snapshots(volumes: list, backup_date: str, expiry_date: str) -> tuple:
    """
    Create EBS snapshot for each volume.
    Returns (created_snapshots, errors).
    """
    kms_key_id = get_kms_key_id(KMS_KEY_ALIAS)
    created    = []
    errors     = []

    for vol in volumes:
        volume_id     = vol["volume_id"]
        instance_id   = vol["instance_id"]
        instance_name = vol["instance_name"]
        size_gb       = vol["size_gb"]

        description = (
            f"{PROJECT} daily backup | {volume_id} | "
            f"{instance_name} ({instance_id}) | {backup_date}"
        )

        tags = [
            {"Key": "Name",             "Value": f"{PROJECT}-backup-{volume_id}-{backup_date}"},
            {"Key": "Project",          "Value": PROJECT},
            {"Key": "Environment",      "Value": ENVIRONMENT},
            {"Key": "ManagedBy",        "Value": MANAGED_BY_TAG},
            {"Key": "BackupDate",       "Value": backup_date},
            {"Key": "ExpiryDate",       "Value": expiry_date},
            {"Key": "SourceVolumeId",   "Value": volume_id},
            {"Key": "SourceInstanceId", "Value": instance_id},
            {"Key": "SourceInstance",   "Value": instance_name},
            {"Key": "ClusterName",      "Value": CLUSTER_NAME},
            {"Key": "Device",           "Value": vol["device"]},
            {"Key": "SizeGB",           "Value": str(size_gb)},
        ]

        try:
            kwargs = {
                "VolumeId":   volume_id,
                "Description": description,
                "TagSpecifications": [{
                    "ResourceType": "snapshot",
                    "Tags": tags,
                }],
            }

            # Encrypt snapshot with project KMS key if available
            # (volumes that are already encrypted use their own key)
            if kms_key_id and not vol["encrypted"]:
                kwargs["Encrypted"] = True
                kwargs["KmsKeyId"]  = kms_key_id

            resp        = ec2.create_snapshot(**kwargs)
            snapshot_id = resp["SnapshotId"]
            logger.info(
                f"  Created snapshot: {snapshot_id} for {volume_id} "
                f"({size_gb}GB) on {instance_name}"
            )
            created.append({
                "snapshot_id": snapshot_id,
                "volume_id":   volume_id,
                "instance_id": instance_id,
                "size_gb":     size_gb,
                "expiry_date": expiry_date,
            })

        except ClientError as e:
            msg = f"Snapshot failed for {volume_id}: {e}"
            logger.error(msg)
            errors.append(msg)

    logger.info(f"Snapshots created: {len(created)}, errors: {len(errors)}")
    return created, errors


# =============================================================================
# Step 4: Cleanup expired snapshots
# =============================================================================

def cleanup_expired_snapshots(today: datetime) -> tuple:
    """
    Delete snapshots created by this Lambda that have passed their expiry date.
    Only deletes snapshots tagged ManagedBy=lambda-ebs-backup.
    Never touches manually created snapshots.

    Returns (deleted_snapshots, cleanup_errors).
    """
    logger.info(f"Cleaning up expired snapshots (retention={RETENTION_DAYS} days)...")

    deleted = []
    errors  = []
    today_str = today.strftime("%Y-%m-%d")

    try:
        paginator = ec2.get_paginator("describe_snapshots")
        pages = paginator.paginate(
            OwnerIds=["self"],
            Filters=[
                {"Name": "tag:ManagedBy",     "Values": [MANAGED_BY_TAG]},
                {"Name": "tag:Project",        "Values": [PROJECT]},
                {"Name": "tag:Environment",    "Values": [ENVIRONMENT]},
            ],
        )

        expired_snapshots = []
        for page in pages:
            for snap in page["Snapshots"]:
                tags       = {t["Key"]: t["Value"] for t in snap.get("Tags", [])}
                expiry_str = tags.get("ExpiryDate", "")

                if not expiry_str:
                    continue

                # Delete if expiry date has passed
                if expiry_str <= today_str:
                    expired_snapshots.append({
                        "snapshot_id": snap["SnapshotId"],
                        "expiry_date": expiry_str,
                        "volume_id":   tags.get("SourceVolumeId", "unknown"),
                        "backup_date": tags.get("BackupDate", "unknown"),
                        "size_gb":     snap.get("VolumeSize", 0),
                    })

        logger.info(f"Found {len(expired_snapshots)} expired snapshot(s) to delete")

        for snap in expired_snapshots:
            try:
                ec2.delete_snapshot(SnapshotId=snap["snapshot_id"])
                logger.info(
                    f"  Deleted: {snap['snapshot_id']} "
                    f"(backup={snap['backup_date']}, expiry={snap['expiry_date']}, "
                    f"volume={snap['volume_id']}, {snap['size_gb']}GB)"
                )
                deleted.append(snap)
            except ClientError as e:
                msg = f"Delete failed for {snap['snapshot_id']}: {e}"
                logger.error(msg)
                errors.append(msg)

    except ClientError as e:
        msg = f"describe_snapshots failed: {e}"
        logger.error(msg)
        errors.append(msg)

    logger.info(f"Cleanup: {len(deleted)} deleted, {len(errors)} errors")
    return deleted, errors


# =============================================================================
# Step 5: SNS Notification
# =============================================================================

def send_notification(
    backup_date:    str,
    instances:      list,
    volumes:        list,
    created:        list,
    create_errors:  list,
    deleted:        list,
    delete_errors:  list,
) -> None:
    """Publish backup summary to SNS."""
    if not SNS_TOPIC_ARN:
        logger.warning("SNS_TOPIC_ARN not set — skipping notification")
        return

    all_errors = create_errors + delete_errors
    status     = "SUCCESS" if not all_errors else ("PARTIAL_FAILURE" if created else "FAILURE")
    subject    = f"[{PROJECT}] EBS Backup {status} — {backup_date}"

    total_gb_created = sum(s["size_gb"] for s in created)
    total_gb_deleted = sum(s["size_gb"] for s in deleted)

    lines = [
        f"EBS Snapshot Backup Report — {PROJECT} ({ENVIRONMENT})",
        f"Date:   {backup_date}",
        f"Status: {status}",
        f"Region: {REGION}",
        "",
        "=== Instances Backed Up ===",
    ]
    for inst in instances:
        name = inst["tags"].get("Name", "unnamed")
        lines.append(f"  {inst['instance_id']} ({inst['instance_type']}) — {name}")

    lines += [
        "",
        f"=== Snapshots Created: {len(created)} ({total_gb_created}GB total) ===",
    ]
    for s in created:
        lines.append(
            f"  ✓ {s['snapshot_id']} | vol={s['volume_id']} "
            f"({s['size_gb']}GB) | expires {s['expiry_date']}"
        )

    lines += [
        "",
        f"=== Expired Snapshots Deleted: {len(deleted)} ({total_gb_deleted}GB freed) ===",
    ]
    for s in deleted:
        lines.append(
            f"  🗑 {s['snapshot_id']} | vol={s['volume_id']} "
            f"(backup={s['backup_date']})"
        )

    if all_errors:
        lines += ["", f"=== Errors: {len(all_errors)} ==="]
        for e in all_errors:
            lines.append(f"  ✗ {e}")

    lines += [
        "",
        f"Retention policy: {RETENTION_DAYS} days",
        f"Next backup: tomorrow at 12:00 UTC",
    ]

    try:
        sns.publish(
            TopicArn = SNS_TOPIC_ARN,
            Subject  = subject,
            Message  = "\n".join(lines),
        )
        logger.info(f"SNS notification sent: {subject}")
    except ClientError as e:
        logger.error(f"SNS publish failed: {e}")


# =============================================================================
# Lambda Handler
# =============================================================================

def lambda_handler(event: dict, context) -> dict:
    """
    Main entry point — triggered daily at 12:00 PM UTC by EventBridge.

    Event payload (optional overrides):
      {}                                  → normal daily backup
      {"retention_days": 14}             → override retention
      {"dry_run": true}                  → discover only, no snapshots
    """
    logger.info(f"EBS Backup Lambda started | Event: {json.dumps(event)}")
    logger.info(f"Project: {PROJECT}, Cluster: {CLUSTER_NAME}, Region: {REGION}")

    # Allow event-level overrides
    retention  = int(event.get("retention_days", RETENTION_DAYS))
    dry_run    = event.get("dry_run", False)

    now        = datetime.now(timezone.utc)
    today_str  = now.strftime("%Y-%m-%d")
    expiry_dt  = now + timedelta(days=retention)
    expiry_str = expiry_dt.strftime("%Y-%m-%d")

    logger.info(f"Backup date: {today_str}, Expiry date: {expiry_str}, Dry run: {dry_run}")

    # Step 1: Discover instances
    instances = get_eks_instances()
    if not instances:
        msg = f"No EKS instances found for cluster {CLUSTER_NAME}"
        logger.warning(msg)
        send_notification(today_str, [], [], [], [msg], [], [])
        return {"statusCode": 200, "message": msg, "snapshots_created": 0}

    # Step 2: Collect volumes
    volumes = get_volumes_for_instances(instances)
    if not volumes:
        msg = "No EBS volumes found on EKS instances"
        logger.warning(msg)
        send_notification(today_str, instances, [], [], [msg], [], [])
        return {"statusCode": 200, "message": msg, "snapshots_created": 0}

    # Step 3: Create snapshots
    created       = []
    create_errors = []
    if dry_run:
        logger.info("DRY RUN — skipping snapshot creation")
        for v in volumes:
            logger.info(f"  Would snapshot: {v['volume_id']} ({v['size_gb']}GB)")
    else:
        created, create_errors = create_snapshots(volumes, today_str, expiry_str)

    # Step 4: Cleanup expired snapshots
    deleted       = []
    delete_errors = []
    if dry_run:
        logger.info("DRY RUN — skipping cleanup")
    else:
        deleted, delete_errors = cleanup_expired_snapshots(now)

    # Step 5: Notify
    send_notification(
        today_str,
        instances,
        volumes,
        created,
        create_errors,
        deleted,
        delete_errors,
    )

    # Summary
    all_errors = create_errors + delete_errors
    response = {
        "statusCode":        200 if not all_errors else 207,
        "backup_date":       today_str,
        "expiry_date":       expiry_str,
        "instances_found":   len(instances),
        "volumes_found":     len(volumes),
        "snapshots_created": len(created),
        "snapshots_deleted": len(deleted),
        "errors":            all_errors,
        "dry_run":           dry_run,
    }

    logger.info(
        f"Backup complete: {len(created)} created, "
        f"{len(deleted)} cleaned up, {len(all_errors)} errors"
    )
    return response
