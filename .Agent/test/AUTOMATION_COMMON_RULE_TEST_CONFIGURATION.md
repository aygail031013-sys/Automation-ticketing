# OneDesk Automation — Common Rule Test Configuration

**Date:** 2026-09-20  
**Status:** Draft configuration contract for review  
**Purpose:** Provide common Automation Rules and complete event-trigger coverage without depending on the superseded 16 Sep queue schema.

## 1. Configuration Principles

1. All rule names use prefix `[TEST]`.
2. Stable symbolic keys are used until final DDL/SP identifiers are approved.
3. Ticket Creation uses `FIRST_MATCH` in the primary trial set.
4. Ticket Update and Schedule use `ALL_MATCH`.
5. Field-only actions use `ExecutionTarget = AUTOMATION`.
6. Email, notification, and webhook actions use `ExecutionTarget = APPLICATION`.
7. Rules use `SortOrder` 9000+ so test rules do not collide with normal business rules.
8. State-changing and external-side-effect rules are disabled by default outside an isolated test environment.
9. The configuration is idempotent by logical `RuleKey`; rerunning setup updates/replaces test configuration rather than duplicating it.

## 2. Initial Field Catalog — Three Per Object

The first trial intentionally exposes only three fields from each object/source.

| Object/source | Field code | Type | Condition | Action target | Resolution source |
|---|---|---:|:---:|:---:|---|
| `TICKET` | `DEFAULT_STATUS` | enum | Yes | Yes | `Tickets.Status` |
| `TICKET` | `DEFAULT_PRIORITY` | enum | Yes | Yes | `Tickets.Priority` |
| `TICKET` | `DEFAULT_SOURCE` | enum | Yes | No | `Tickets.Source` |
| `REQUESTER` | `STATUS` | boolean | Yes | No | `Contacts.Status` |
| `REQUESTER` | `PRIMARY_COMPANY_ID` | reference | Yes | No | `Contacts.PrimaryCompanyId` |
| `REQUESTER` | `PRIMARY_EMAIL` | string | Yes | No | `Contacts.PrimaryEmail` |
| `COMPANY` | `ID` | reference | Yes | No | `Companies.Id` through `Tickets.RequesterCompanyId` |
| `COMPANY` | `NAME` | string | Yes | No | `Companies.Name` |
| `COMPANY` | `DOMAIN` | string/list | Yes | No | `CompanyDomains.Domain` |
| `ASSIGNED_AGENT` | `STATUS` | boolean | Yes | No | `Agents.Status` |
| `ASSIGNED_AGENT` | `TICKET_AVAILABILITY` | boolean | Yes | No | `Agents.TicketAvailability` |
| `ASSIGNED_AGENT` | `GROUP_ID` | reference/list | Yes | No | `GroupAgents.GroupId` |
| `CUSTOM_FIELD` | `CUSTOM_DEPARTMENT` | enum | Yes | Yes | `TicketFieldValues` + `TicketFields.FieldCode` |
| `CUSTOM_FIELD` | `CUSTOM_DIVISION` | enum | Yes | Yes | same |
| `CUSTOM_FIELD` | `CUSTOM_CATEGORY` | enum | Yes | Yes | same |
| `TIME` | `HOURS_SINCE_CREATED` | number | Yes | No | `now UTC - Tickets.CreatedAt` |
| `TIME` | `HOURS_SINCE_UPDATED` | number | Yes | No | `now UTC - Tickets.UpdatedAt` |
| `TIME` | `HOURS_SINCE_STATUS_CHANGED` | number | Yes | No | `now UTC - Tickets.StatusChangedAt` |
| `EVENT_CONTEXT` | `EVENT_TYPE` | enum | event selector | No | normalized event |
| `EVENT_CONTEXT` | `ACTOR_TYPE` | enum | event filter | No | `TicketActivityLogs.ActorType` |
| `EVENT_CONTEXT` | `CHANGED_FIELD_CODE` | string | event filter | No | normalized delta |

Notes:

- Reference conditions store stable IDs; names are display metadata only.
- `PRIMARY_EMAIL` must be masked in UI/audit views according to access policy. A future safer operator may derive email domain without persisting the full value again.
- `GROUP_ID` for assigned agent means membership lookup, not the Ticket's assigned `GroupId`.
- Custom field evaluation uses field code, never database row ID as the configuration identity.
- Time values are calculated from UTC timestamps and are virtual condition fields.

## 3. Supported Event Configuration

| Event | Producer | Required event data |
|---|---|---|
| `TICKET_CREATED` | Ticket create activity collector | Ticket ID, actor, operation, created state |
| `STATUS_CHANGED` | Ticket activity collector | `DEFAULT_STATUS`, old value, new value |
| `PRIORITY_CHANGED` | Ticket activity collector | `DEFAULT_PRIORITY`, old value, new value |
| `GROUP_CHANGED` | Ticket activity collector | `DEFAULT_GROUP`, old ID, new ID |
| `ASSIGNEE_CHANGED` | Ticket activity collector | `DEFAULT_AGENT`, old ID, new ID |
| `REQUESTER_REPLIED` | Ticket message/activity collector | requester actor and message/activity identity |
| `AGENT_REPLIED` | Ticket message/activity collector | agent actor and message/activity identity |
| `SCHEDULE_DUE` | Schedule Scanner | schedule occurrence key, reference time, evaluated-at time |

`SCHEDULE_DUE` is not a separate evaluator. It enters the normal Delta stage.

## 4. Common Rule Catalog

Replace symbolic values such as `${GROUP_ESCALATION_ID}` with IDs from isolated test fixtures.

### Creation rules — `FIRST_MATCH`

| Rule key | Order | Conditions | Actions | Default |
|---|---:|---|---|---|
| `CRT_URGENT_VIP` | 9010 | Ticket priority = `URGENT`; custom department = `CUSTOMER_SERVICE`; requester status = 1 | Assign `${GROUP_VIP_ID}`; set priority `HIGH` | Enabled in isolated test only |
| `CRT_URGENT_ESCALATION` | 9020 | Ticket priority = `URGENT`; requester status = 1 | Assign `${GROUP_ESCALATION_ID}` | Enabled in isolated test only |
| `CRT_DEFAULT_ROUTE` | 9090 | Ticket source in (`PORTAL_AGENT`, `PORTAL_ONECHAT`) | Assign `${GROUP_DEFAULT_ID}` | Enabled in isolated test only |

Purpose: all three may match, but only the lowest matching `SortOrder` is selected.

### Update rules — `ALL_MATCH`

| Rule key | Event/filter | Current conditions | Actions | Target |
|---|---|---|---|---|
| `UPD_STATUS_RESOLVED_HIGH` | `STATUS_CHANGED`, `* -> RESOLVED` | Priority in (`HIGH`, `URGENT`) | Assign `${GROUP_ESCALATION_ID}` | AUTOMATION |
| `UPD_PRIORITY_URGENT_ROUTE` | `PRIORITY_CHANGED`, `* -> URGENT` | Status not `CLOSED`; requester status = 1 | Assign `${GROUP_ESCALATION_ID}` | AUTOMATION |
| `UPD_PRIORITY_URGENT_NOTIFY` | `PRIORITY_CHANGED`, `* -> URGENT` | Company domain = `${VIP_DOMAIN}` | Send notification `URGENT_VIP_TICKET` | APPLICATION |
| `UPD_GROUP_VIP_ASSIGN` | `GROUP_CHANGED`, `* -> ${GROUP_VIP_ID}` | Assigned agent is empty or unavailable | Assign `${AGENT_AVAILABLE_ID}` | AUTOMATION |
| `UPD_ASSIGNEE_AVAILABLE_OPEN` | `ASSIGNEE_CHANGED`, `* -> ${AGENT_AVAILABLE_ID}` | Agent status = 1; ticket availability = 1; status = `PENDING` | Set status `OPEN` | AUTOMATION |
| `UPD_REQUESTER_REPLY_REOPEN` | `REQUESTER_REPLIED` | Status in (`PENDING`, `RESOLVED`); requester status = 1 | Set status `OPEN` | AUTOMATION |
| `UPD_AGENT_REPLY_WAIT` | `AGENT_REPLIED` | Status = `OPEN`; priority not `URGENT` | Set status `PENDING` | AUTOMATION |

The two `PRIORITY_CHANGED` rules intentionally overlap to validate `ALL_MATCH` and the AUTOMATION/APPLICATION boundary in one event.

### Schedule rules — `ALL_MATCH`

| Rule key | Time conditions | Other conditions | Actions | Target |
|---|---|---|---|---|
| `SCH_RESOLVED_CLOSE_48H` | Hours since updated >= 48 | Status = `RESOLVED` | Set status `CLOSED` | AUTOMATION |
| `SCH_OPEN_ESCALATE_24H` | Hours since created >= 24 | Status = `OPEN`; priority in (`HIGH`, `URGENT`) | Assign `${GROUP_ESCALATION_ID}` | AUTOMATION |
| `SCH_PENDING_REMINDER_12H` | Hours since status changed >= 12 | Status = `PENDING` | Send notification `PENDING_TICKET_REMINDER` | APPLICATION |

## 5. Canonical Rule Definitions

### `CRT_URGENT_VIP`

```yaml
ruleKey: CRT_URGENT_VIP
name: "[TEST] Creation - Route urgent VIP ticket"
automationType: TICKET_CREATION
eventType: TICKET_CREATED
executionMode: FIRST_MATCH
sortOrder: 9010
matchType: ALL
conditions:
  - object: TICKET
    fieldCode: DEFAULT_PRIORITY
    operator: EQUALS
    value: URGENT
  - object: CUSTOM_FIELD
    fieldCode: CUSTOM_DEPARTMENT
    operator: EQUALS
    value: CUSTOMER_SERVICE
  - object: REQUESTER
    fieldCode: STATUS
    operator: EQUALS
    value: true
actions:
  - sequence: 10
    actionType: ASSIGN_GROUP
    executionTarget: AUTOMATION
    value: ${GROUP_VIP_ID}
  - sequence: 20
    actionType: SET_PRIORITY
    executionTarget: AUTOMATION
    value: HIGH
```

### `UPD_PRIORITY_URGENT_ROUTE`

```yaml
ruleKey: UPD_PRIORITY_URGENT_ROUTE
name: "[TEST] Update - Route urgent ticket"
automationType: TICKET_UPDATE
eventType: PRIORITY_CHANGED
executionMode: ALL_MATCH
sortOrder: 9110
eventFilter:
  fieldCode: DEFAULT_PRIORITY
  fromValue: null
  toValue: URGENT
matchType: ALL
conditions:
  - object: TICKET
    fieldCode: DEFAULT_STATUS
    operator: NOT_EQUALS
    value: CLOSED
  - object: REQUESTER
    fieldCode: STATUS
    operator: EQUALS
    value: true
actions:
  - sequence: 10
    actionType: ASSIGN_GROUP
    executionTarget: AUTOMATION
    value: ${GROUP_ESCALATION_ID}
```

### `UPD_REQUESTER_REPLY_REOPEN`

```yaml
ruleKey: UPD_REQUESTER_REPLY_REOPEN
name: "[TEST] Update - Reopen after requester reply"
automationType: TICKET_UPDATE
eventType: REQUESTER_REPLIED
executionMode: ALL_MATCH
sortOrder: 9150
matchType: ALL
conditions:
  - object: TICKET
    fieldCode: DEFAULT_STATUS
    operator: IN
    values: [PENDING, RESOLVED]
  - object: REQUESTER
    fieldCode: STATUS
    operator: EQUALS
    value: true
actions:
  - sequence: 10
    actionType: SET_STATUS
    executionTarget: AUTOMATION
    value: OPEN
```

### `SCH_RESOLVED_CLOSE_48H`

```yaml
ruleKey: SCH_RESOLVED_CLOSE_48H
name: "[TEST] Schedule - Close resolved ticket after 48 hours"
automationType: SCHEDULE_TRIGGER
eventType: SCHEDULE_DUE
executionMode: ALL_MATCH
sortOrder: 9210
matchType: ALL
conditions:
  - object: TIME
    fieldCode: HOURS_SINCE_UPDATED
    operator: GTE
    value: 48
  - object: TICKET
    fieldCode: DEFAULT_STATUS
    operator: EQUALS
    value: RESOLVED
actions:
  - sequence: 10
    actionType: SET_STATUS
    executionTarget: AUTOMATION
    value: CLOSED
```

## 6. Use Cases for Every Event

### UC-01 — Ticket created

Given an active requester creates an urgent Ticket with `CUSTOM_DEPARTMENT = CUSTOMER_SERVICE`, when `TICKET_CREATED` is processed, `CRT_URGENT_VIP` is selected before the fallback creation rules. Its actions are generated in sequence 10 then 20. The two later matching rules remain auditable as matched but not selected.

### UC-02 — Status changed

Given a high-priority Ticket changes from `OPEN` to `RESOLVED`, `UPD_STATUS_RESOLVED_HIGH` assigns the escalation group. A transition to `PENDING` must not match this rule.

### UC-03 — Priority changed

Given an active requester's Ticket changes to `URGENT`, the routing rule matches. If its company domain is `${VIP_DOMAIN}`, the notification rule also matches. Both executions are selected under `ALL_MATCH`; the field action is processed by DB and the notification is claimed by the application.

### UC-04 — Group changed

Given a Ticket moves to the VIP group and the current assignee is empty/unavailable, the engine assigns `${AGENT_AVAILABLE_ID}`. If the assignee is already available, evaluation is retained as not matched and no action is generated.

### UC-05 — Assignee changed

Given a pending Ticket is assigned to an active, ticket-available agent belonging to the relevant group, the rule sets status to `OPEN`. Assignment to an inactive or unavailable agent does not match.

### UC-06 — Requester replied

Given an active requester replies to a `PENDING` or `RESOLVED` Ticket, status becomes `OPEN`. The field action creates a new `STATUS_CHANGED` event with execution lineage.

### UC-07 — Agent replied

Given an agent replies to a non-urgent open Ticket, status becomes `PENDING`. An urgent Ticket remains open because the condition does not match.

### UC-08 — Schedule due

Given a resolved Ticket has not changed for 48 hours, the Schedule Scanner emits one idempotent `SCHEDULE_DUE` occurrence and the normal pipeline closes it. A scan at 47:59 does not match; a repeated scan for the same occurrence does not create a second execution.

## 7. Required Negative Configuration Cases

The configuration-validation test suite must reject:

- `STATUS_CHANGED` under `TICKET_CREATION`;
- `HOURS_SINCE_UPDATED` as an action target;
- `CONTAINS` on boolean `REQUESTER.STATUS`;
- unknown custom field code;
- inactive Group/Agent action reference;
- APPLICATION action declared with `ExecutionTarget = AUTOMATION`;
- duplicate `RuleKey` in one active version;
- missing `SortOrder` or duplicate action sequence where deterministic order cannot be established.

## 8. Enablement Policy

Recommended switches for seed/fixture implementation:

```text
EnableSafeFieldRules       = 1 in isolated integration DB only
EnableApplicationActions   = 0 by default; use delivery fakes when enabled
EnableScheduleRules        = 1 only with a controllable test clock
ResetTestRuntime           = explicit opt-in
ResetTestConfiguration     = explicit opt-in
```

Runtime reset must delete only rows connected to `[TEST]`/test `RuleKey` configuration and must respect child-to-parent dependency order. Never use a broad table truncate in a shared environment.

## 9. Conversion to Executable Seed

This document is the configuration contract. Convert it to SQL only after the revised Tridens-style configuration/audit DDL is approved.

The old `09-Automation-Test-Configuration.sql` must not be reused unchanged because it targets the superseded runtime model:

```text
AutomationEventQueue
AutomationActionQueue
AutomationTimerQueue
```

The new executable seed must target the final configuration tables while allowing runtime work to flow through:

```text
AutomationTriggerQueueDelta
AutomationTriggerQueueSummary
AutomationTriggerQueueRule
AutomationTriggerQueueTrigger
AutomationTriggerQueueAction
```

