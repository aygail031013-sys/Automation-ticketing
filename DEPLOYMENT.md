# OneDesk Automation

SQL Server implementation of the data-driven automation flow described in
`.Agent/AUTOMATION_FLOW_AND_COMPONENT_GUIDE (1).md`.

## Implemented flow

```text
TicketActivityLogs / Time Scanner
  -> AutomationTriggerQueueSummary + AutomationTriggerQueueDelta
  -> AutomationEvaluations / AutomationEvaluationBlocks / AutomationEvaluationRules
  -> AutomationTriggerQueueTrigger
  -> AutomationExecutions
  -> AutomationTriggerQueueAction
       -> AUTOMATION: set-based DB field processor
       -> APPLICATION: leased application-worker API
  -> AutomationActionHistories
```

The collector, evaluator, scanner, and DB action executor claim bounded batches. `FIRST_MATCH` is
ordered by trigger `Priority` and then trigger `Id`; `ALL_MATCH` dispatches every match. Queue rows
are processing state, while evaluation, execution, action history, and ticket activity are durable
audit state.

## Deployment order

Run against SQL Server in this order:

1. `01-DDL.sql`
2. `11-SP-BusinessCalendar.sql`
3. `02-TicketActivityIntegration.sql`
4. `03-SP-Collector.sql`
5. `04-SP-Evaluator.sql`
6. `05-SP-ApplicationWorker.sql`
7. `09-SP-AutomationActionProcessor.sql`
8. `10-SP-TimeTrigger.sql`
9. `07-SeedData.sql` (optional sample configuration)
10. `06-Jobs.sql` (requires SQL Server Agent permissions)
11. `12-SP-RetentionCleanup.sql`
12. `08-VerificationQueries.sql` (transactional; all smoke-test writes roll back)

All scripts target the existing `OneDeskDb` SQL Server schema and expect the current `Tickets`,
`TicketActivityLogs`, `TicketFields`, and `TicketFieldValues` tables.

## Application worker contract

Application workers call `dbo.ganymede_automationExecutionActionClaimBatch` with a stable worker id.
The claim is atomic and returns only `APPLICATION` actions owned by that worker, including a lease
expiry and an `IdempotencyKey` equal to the action id. After performing the side effect, workers call
`dbo.ganymede_automationExecutionActionComplete` with the same worker id.

Atomic claiming prevents concurrent ownership but cannot make email/webhook delivery exactly once.
The application must use `IdempotencyKey` in an outbox or provider-level deduplication mechanism.
`ActionValue` is the immutable configuration snapshot; placeholder output belongs in
`RenderedValue` via the completion procedure.

## Ticket creation visibility

Ticket creation sets `Tickets.CreateAutomationStatus` to `PENDING` when active create automations
exist. User-facing ticket reads must include `CreateAutomationStatus = 'READY'`. The evaluator and
action finalizers release the ticket after every directly selected `TICKET_CREATED` execution is
terminal; descendant update cascades do not delay visibility.

## Operations

- Run `dbo.ganymede_automationRetentionCleanupBatch` repeatedly in a low-frequency job. Each call is
  bounded; queue retention and audit retention are independently configured in `AutomationSettings`.
- Expired `PROCESSING` leases are reclaimable by both evaluator and action workers.
- Existing installations that created the superseded `AutomationExecutionActions` draft table may
  leave it in place during rollout. The implemented procedures no longer read or write it.
