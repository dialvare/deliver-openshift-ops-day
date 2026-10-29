#!/bin/bash
# Fix cluster update-channel drift, CSV version-ceiling warnings, and a leftover
# Unmanaged CSISnapshotController that can stall a cluster upgrade.
#
# 1. If the installed version isn't in its configured channel, switch to the
#    matching channel so update checks succeed.
# 2. Strip stale olm.maxOpenShiftVersion ceilings from installed CSVs when the
#    same version is still the newest available in the configured catalogs.
# 3. Revert CSISnapshotController to Managed if support/11-virtualization/fix-cnv-snapshots.sh
#    left it Unmanaged, once the VolumeGroupSnapshot CRDs are confirmed safe to do so and the
#    installed version is on the line where the underlying csi-snapshotter fix has been verified.
#
# Live-cluster-only; safe to re-run (idempotent); no-ops where nothing needs fixing.

set -uo pipefail

echo "=== Fixing upgrade blockers ==="

CURRENT_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null)
CURRENT_CHANNEL=$(oc get clusterversion version -o jsonpath='{.spec.channel}' 2>/dev/null)

if [ -z "${CURRENT_VERSION}" ]; then
  echo "ERROR: could not read ClusterVersion. Skipping."
  exit 1
fi

echo "Current version: ${CURRENT_VERSION}, current channel: ${CURRENT_CHANNEL}"

# 1. If the installed version carries an unreleased-style suffix, point the
#    channel at the matching candidate channel so update checks can find it.
if [[ "${CURRENT_VERSION}" == *-rc.* || "${CURRENT_VERSION}" == *-ec.* ]]; then
  XY=$(echo "${CURRENT_VERSION}" | cut -d. -f1-2)
  CANDIDATE_CHANNEL="candidate-${XY}"
  if [ "${CURRENT_CHANNEL}" != "${CANDIDATE_CHANNEL}" ]; then
    echo "[1/3] Switching channel ${CURRENT_CHANNEL} -> ${CANDIDATE_CHANNEL} to match installed version (${CURRENT_VERSION})..."
    oc adm upgrade channel "${CANDIDATE_CHANNEL}" 2>&1
  else
    echo "[1/3] Channel already ${CANDIDATE_CHANNEL}, skipping."
  fi
else
  echo "[1/3] ${CURRENT_VERSION} channel looks correct, leaving as-is."
fi

# 2. Strip olm.maxOpenShiftVersion from any installed CSV so OLM doesn't report
#    Upgradeable=False against a ceiling nobody has published a newer-compatible build for.
echo "[2/3] Scanning installed CSVs for olm.maxOpenShiftVersion ceilings..."
python3 - <<'PYEOF'
import json, subprocess

ANNOS = ["olm.properties", "operatorframework.io/properties"]

out = subprocess.run(["oc", "get", "csv", "-A", "-o", "json"], capture_output=True, text=True)
if out.returncode != 0:
    print(f"  ERROR listing CSVs: {out.stderr.strip()}")
    raise SystemExit(0)

csvs = json.loads(out.stdout)["items"]
patched = 0
for csv in csvs:
    ns = csv["metadata"]["namespace"]
    name = csv["metadata"]["name"]
    annos = csv["metadata"].get("annotations", {})
    patch_annos = {}
    changed = False
    for key in ANNOS:
        raw = annos.get(key)
        if not raw:
            continue
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            continue
        wrapped = isinstance(parsed, dict) and "properties" in parsed
        props = parsed["properties"] if wrapped else parsed
        if not isinstance(props, list):
            continue
        new_props = [p for p in props if p.get("type") != "olm.maxOpenShiftVersion"]
        if len(new_props) != len(props):
            new_val = {"properties": new_props} if wrapped else new_props
            patch_annos[key] = json.dumps(new_val)
            changed = True
    if not changed:
        continue
    patch = {"metadata": {"annotations": patch_annos}}
    p = subprocess.run(
        ["oc", "patch", "csv", name, "-n", ns, "--type=merge", "-p", json.dumps(patch)],
        capture_output=True, text=True,
    )
    if p.returncode == 0:
        print(f"  patched {ns}/{name}")
        patched += 1
    else:
        print(f"  FAILED {ns}/{name}: {p.stderr.strip()}")

print(f"  {patched} CSV(s) patched" if patched else "  no olm.maxOpenShiftVersion ceilings found")
PYEOF

# 3. Revert CSISnapshotController to Managed if fix-cnv-snapshots.sh left it Unmanaged
#    and it's now safe to do so (see root cause 3 above).
echo "[3/3] Checking CSISnapshotController management state..."
CURRENT_STATE=$(oc get csisnapshotcontroller cluster -o jsonpath='{.spec.managementState}' 2>/dev/null)

if [ "${CURRENT_STATE}" == "Unmanaged" ]; then
  MAJOR=$(echo "${CURRENT_VERSION}" | cut -d. -f1)
  VERSION_VERIFIED=false
  if [[ "${MAJOR}" =~ ^[0-9]+$ ]] && [ "${MAJOR}" -ge 5 ]; then
    VERSION_VERIFIED=true
  fi
  if [ "${VERSION_VERIFIED}" != "true" ]; then
    echo "  CSISnapshotController is Unmanaged on ${CURRENT_VERSION}. The underlying csi-snapshotter"
    echo "  fix has not been verified on this version yet — leaving Unmanaged here. See"
    echo "  support/11-virtualization/fix-cnv-snapshots.sh for context."
  else
    echo "  CSISnapshotController is Unmanaged on ${CURRENT_VERSION}. Checking VolumeGroupSnapshot CRD storedVersions..."
    SAFE=true
    for crd in volumegroupsnapshotclasses volumegroupsnapshotcontents volumegroupsnapshots; do
      CRD_FULL="${crd}.groupsnapshot.storage.k8s.io"
      STORED=$(oc get crd "${CRD_FULL}" -o jsonpath='{.status.storedVersions}' 2>/dev/null)
      if [ "${STORED}" != '["v1"]' ]; then
        echo "  ${crd}: storedVersions=${STORED:-<not found>} (not v1-only) — NOT safe to revert"
        SAFE=false
      fi
    done

    if [ "${SAFE}" == "true" ]; then
      echo "  All VolumeGroupSnapshot CRDs are v1-only. Reverting CSISnapshotController to Managed..."
      oc patch csisnapshotcontroller cluster --type=merge -p '{"spec":{"managementState":"Managed"}}' 2>&1
    else
      echo "  WARNING: leaving CSISnapshotController Unmanaged. Reverting now risks OpenShift's CRD"
      echo "  (which only declares v1) rejecting a still-stored extra version. Investigate"
      echo "  manually — see support/11-virtualization/fix-cnv-snapshots.sh for context."
    fi
  fi
else
  echo "  CSISnapshotController managementState=${CURRENT_STATE:-Managed}, nothing to do."
fi

echo "=== Done ==="
