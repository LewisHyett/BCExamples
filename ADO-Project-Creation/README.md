# Sanitised sample — Azure DevOps project bootstrap

This folder is a **public, genericised copy** of a working pipeline that
provisions a fully configured Azure DevOps project in one manual run. Every
organisation-, customer-, and team-specific value has been replaced with a
`<placeholder>` describing what it should contain.

It is a reference, not a drop-in. Replace every `<...>` placeholder, then test
locally (the script prompts before making changes) before wiring it into a
pipeline.

## Files

| File | Purpose |
| ---- | ------- |
| `azure-pipelines.yml` | Manual-trigger pipeline definition. Runs the script with parameters supplied at queue time. |
| `scripts/New-Project.ps1` | The automation. Walks the setup runbook top to bottom against the Azure DevOps REST API. |

## Placeholders you must replace

| Placeholder | What it should contain |
| ----------- | ---------------------- |
| `<your-organisation-name>` | Your Azure DevOps organisation name, i.e. the last segment of `https://dev.azure.com/<name>`. |
| `<variable-group-name>` | Name of a pipeline variable group that stores the PAT as a **secret** variable named `ADO_PAT`. |
| `<Your Process Template>` | The process template new projects should use (e.g. `Agile`, `Scrum`, `CMMI`, or a custom inherited process name). |
| `[<YourOrg>]\<Delivery Group>` | Fully-qualified name of the security group that should get elevated area / repo / query permissions. |
| `[<YourOrg>]\<Code Reviewer Group>` | Fully-qualified name of the group to auto-include as reviewers in branch policies. |
| `<Group Rule 1>`, `<Group Rule 2>` | Names of the organisation **group rules** (Organisation Settings → Users → Group rules) that should grant Project Contributors access to the new project. |
| `<Stream A>`, `<Stream B>` | Your two top-level area-path nodes. |
| `<Sub-Area 1..3>` | The child area-path nodes created under each stream. |
| `<Query Folder 1>`, `<Query Folder 2>` | Sub-folder names created under **Shared Queries**. |

## Values left as-is (and why)

The following are **public, tenant-independent Azure DevOps constants** taken
from Microsoft's documentation. They are identical for every organisation, so
masking them would only make the sample non-functional:

- Security namespace GUIDs (classification nodes / CSS, Git repositories, work
  item query folders) — retrievable from `GET _apis/securitynamespaces`.
- Branch-policy type IDs (minimum reviewers, work-item linking, comment
  resolution, merge strategy, required reviewers).
- REST route templates (`_apis/projects`, `_apis/policy/configurations`, etc.)
  and security token formats (`vstfs:///Classification/Node/...`,
  `repoV2/{projectId}`, `$/{projectId}/{folderId}`).
- Permission bit values.

## Required PAT scopes

The PAT stored as `ADO_PAT` needs:

| Scope | Level |
| ----- | ----- |
| Project and Team | Read, Write & Manage |
| Code | Full |
| Graph | Read & Manage |
| Identity | Read & Manage |
| Member Entitlement Management | Read & Write |
| Security | Manage |

Prefer a short-lived PAT on a service account, or migrate to a service
connection / workload identity once you have the flow working.
