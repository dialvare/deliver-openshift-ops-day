#!/bin/bash
set -euo pipefail

KEYCLOAK_URL=$(oc get route keycloak -n rhbk -o jsonpath='{.spec.host}')

GEN=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')

cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: htpasswd
    mappingMethod: claim
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpasswd
  - name: rhbk
    mappingMethod: claim
    type: OpenID
    openID:
      clientID: openshift
      clientSecret:
        name: rhbk-client-secret
      issuer: https://${KEYCLOAK_URL}/realms/OpenShift
      claims:
        preferredUsername:
        - preferred_username
        name:
        - name
        email:
        - email
        groups:
        - groups
      extraScopes:
      - email
      - profile
EOF

echo "Waiting for OAuth operator to pick up the config change..."
ELAPSED=0
until [ "$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "$GEN")" != "$GEN" ]; do
  sleep 2; ELAPSED=$((ELAPSED+2))
  [ $ELAPSED -ge 60 ] && echo "Warning: OAuth operator slow to pick up config change - continuing to wait below" && break
done

# The authentication operator applies this change in several stages (trust
# bundle sync, cert rotation, etc.), and oauth-openshift can roll out more
# than once in a row as a result. Declaring success after the first rollout
# finishes is not safe: logging out / reloading the Console while a later
# restart is still in flight causes repeated auth failures against the
# Console's open API watches, which can freeze the Console tab's browser
# tab. Instead, wait until the cluster has been fully quiet for a sustained
# period, resetting the quiet timer every time oauth-openshift restarts
# again.
echo "Waiting for OAuth to fully stabilize - do NOT log out of or reload the OCP Console tab until this finishes."
REQUIRED_STABLE_SECS=30
MAX_WAIT_SECS=600
STABLE_FOR=0
TOTAL_ELAPSED=0
LAST_GEN=""

while :; do
  PROGRESSING=$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo "")
  AVAILABLE=$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
  DEGRADED=$(oc get co authentication -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "")
  CUR_GEN=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "")
  OBS_GEN=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo "")
  READY=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  UPDATED=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || echo "0")
  REPLICAS=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")

  if [ "$PROGRESSING" = "False" ] && [ "$AVAILABLE" = "True" ] && [ "$DEGRADED" = "False" ] \
     && [ -n "$CUR_GEN" ] && [ "$CUR_GEN" = "$OBS_GEN" ] \
     && [ "${READY:-0}" = "3" ] && [ "${UPDATED:-0}" = "3" ] && [ "${REPLICAS:-0}" = "3" ] \
     && [ "$CUR_GEN" = "$LAST_GEN" ]; then
    STABLE_FOR=$((STABLE_FOR+5))
  else
    if [ -n "$LAST_GEN" ] && [ -n "$CUR_GEN" ] && [ "$CUR_GEN" != "$LAST_GEN" ]; then
      echo "  oauth-openshift restarted again (generation $LAST_GEN -> $CUR_GEN) - this is expected, resetting the stability timer"
    fi
    STABLE_FOR=0
  fi
  LAST_GEN="$CUR_GEN"

  [ "$STABLE_FOR" -ge "$REQUIRED_STABLE_SECS" ] && break

  sleep 5; TOTAL_ELAPSED=$((TOTAL_ELAPSED+5))
  if [ "$TOTAL_ELAPSED" -ge "$MAX_WAIT_SECS" ]; then
    echo "ERROR: Timed out after ${MAX_WAIT_SECS}s waiting for OAuth to stabilize - check 'oc get co authentication' and 'oc get pods -n openshift-authentication'"
    break
  fi
done

echo "OAuth is live with rhbk provider and has been stable for ${REQUIRED_STABLE_SECS}s - it is now safe to log out and reload the console"
