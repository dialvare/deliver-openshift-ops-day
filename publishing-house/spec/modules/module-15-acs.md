# Module 15 — Advanced Cluster Security

## Brief Overview

This module covers security posture management using Red Hat Advanced Cluster Security (RHACS). Participants deploy intentionally vulnerable demo applications to populate RHACS dashboards, configure an allowed-registries policy to pass an ocp4-e8 compliance control, create a scheduled scan covering CIS, E8, NERC-CIP, PCI-DSS, and STIG profiles, review scan results for a passing control, and then implement Policy-as-Code by applying a SecurityPolicy that kills any pod executing the Alpine package manager (`apk`) at runtime.

## Audience and Time

- **Personas:** Cluster administrators, security engineers, compliance officers
- **Prerequisites:** Cluster-admin access; RHACS pre-installed with sensor deployed; basic understanding of compliance frameworks and Policy-as-Code concepts
- **Duration:** 15–20 minutes

## Learning Objectives

1. Deploy intentionally vulnerable demo applications to demonstrate RHACS security insights and vulnerability management capabilities
2. Configure an allowed-registries ImageConfig to pass the `ocp4-e8-ocp-allowed-registries` compliance control
3. Create a scheduled compliance scan covering CIS, E8, NERC-CIP, PCI-DSS, and STIG profiles
4. Review compliance scan results and verify a passing ocp4-e8 control in the OpenShift Coverage view
5. Apply a SecurityPolicy using Policy-as-Code to enforce runtime protection against Alpine package manager execution
6. Trigger the policy by running `apk update` in a container and observe RHACS kill the pod
7. Review violation forensic details in the RHACS Violations console

## Lab Structure

| Section | Title | Duration |
|---------|-------|----------|
| 1 | Deploy insecure demo applications | 3 min |
| 2 | Configure allowed registries for compliance | 2 min |
| 3 | Create scheduled compliance scan | 4 min |
| 4 | Review scan results and passing controls | 3 min |
| 5 | Apply apk-kill SecurityPolicy | 3 min |
| 6 | Trigger policy and observe pod termination | 3 min |
| 7 | Review violations in RHACS console | 2 min |

## Key Takeaways

- RHACS vulnerability management covers platform, workloads, nodes, and virtual machines — deploying known-vulnerable apps surfaces real findings immediately
- Compliance scans run against live cluster state; configuring a cluster control before scanning demonstrates the feedback loop between remediation and audit results
- Multi-profile scheduled scans (CIS, E8, PCI-DSS, STIG) let a single RHACS schedule satisfy multiple compliance frameworks simultaneously
- Policy-as-Code moves security enforcement from audit to prevention — the apk-kill policy terminates pods at the process-execution level, before any damage occurs
- RHACS captures forensic event records (timestamp, process arguments, ancestors, enforcement action) for every violation, supporting SIEM integration and audit trails

## Infrastructure Notes

- RHACS Central and SecuredCluster (sensor) are pre-installed
- The RHACS UI is accessible via the embedded browser tab (Route in the `stackrox` namespace)
- Demo applications are pulled from `github.com/mfosterrox/demo-applications` at runtime
