# Runbooks

Operational playbooks for events that happen rarely but need a written
sequence when they do.

| Runbook | When to open it |
|---|---|
| [app-store-rejection.md](app-store-rejection.md) | App Store Review email lands in Resolution Center. |
| [hotfix.md](hotfix.md) | Shipped build has a P0 bug; need to expedite a patch. |
| [data-deletion.md](data-deletion.md) | User emails asking to delete their data (GDPR / CCPA). |
| [incident-response.md](incident-response.md) | Provider outage, CloudKit failure, crash spike, encryption issue, privacy leak suspicion. |

Each runbook is self-contained — open it, follow it, file the
post-mortem at the end. Don't try to remember the steps from the last
incident; they were probably different.

If you encounter a category not covered here, write the runbook
immediately after resolving the incident — the muscle memory is
freshest then.
