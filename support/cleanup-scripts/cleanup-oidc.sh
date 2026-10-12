#!/bin/bash
# Cleanup script for Module 08 - OIDC Authentication
# Restores OAuth to htpasswd only, removes Keycloak and OIDC resources

echo "Cleaning up OIDC resources..."

# Restore OAuth to htpasswd only
cat <<'EOF' | oc apply -f -
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
EOF

# Remove Lightspeed access grants, then delete the client secret and OIDC users/groups
oc adm policy remove-cluster-role-from-group lightspeed-operator-query-access ocp-developers 2>/dev/null || true
oc adm policy remove-cluster-role-from-user lightspeed-operator-query-access developer1 2>/dev/null || true
oc delete secret rhbk-client-secret -n openshift-config --ignore-not-found
oc delete user developer1 admin1 viewer1 --ignore-not-found
oc delete identity keycloak:developer1 keycloak:admin1 keycloak:viewer1 --ignore-not-found
oc delete group ocp-admins ocp-developers ocp-viewers --ignore-not-found

# Wait for the OAuth rollout to finish *before* tearing down Keycloak, so the
# old oauth-openshift pods configured with the rhbk OpenID provider are gone
# before its issuer (Keycloak, in the rhbk namespace) disappears. Deleting
# rhbk first (the old order) left a window where still-running old pods try
# to reach Keycloak's OIDC endpoints after it's already gone — looks like a
# frozen console during that window, same failure mode as cleanup-ldap.sh.
(
  oc rollout status deployment/oauth-openshift -n openshift-authentication --timeout=120s
  oc delete namespace rhbk --ignore-not-found
  oc delete project app-development app-production --ignore-not-found
) &>/dev/null &

echo "Cleanup running in background — you can continue to the next module"
