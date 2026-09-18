# OneDesk Automation – Initial Implementation Plan (v1.0)

## 1. Context & Objective
**Objective:** Build a robust, DB-driven Automation engine for OneDesk from the ground up. This v1.0 engine must immediately support event-driven triggers, time-based triggers, business hours context, cascade lineage/protection, placeholder rendering, and strict application-worker isolation.
**Baseline:** Existing OneDesk core ticketing system (`Tickets`, `TicketActivityLogs` tables, and Go backend repository/services).

You (the AI Agent) will write and integrate code across SQL (DDL, Stored Procedures, Jobs) and Go (Repository, Service, Worker) to establish this entirely new automation domain.

## 2. Hard Constraints (DO NOT VIOLATE)
Before writing any code, strictly adhere to these system boundaries:
1. **DB / App Boundary:** The Database evaluates rules and creates executable work items (`AutomationExecutionActions`). The Database MUST NOT execute business side-effects (e.g., sending emails, calling external APIs). The Go Application MUST NOT evaluate automation logical rules (e.g., `CONTAINS`, `CHANGED_TO`).
2. **Immutability:** `TicketActivityLogs` is append-only. Automation configuration snapshots captured in `ActionValue` MUST NEVER be overwritten.
3. **Loop Protection:** Rule chaining (cascade) must occur via new ticket events inserted into `TicketActivityLogs`, NOT by mutating the in-memory evaluator snapshot.
4. **Time Trigger Purity:** Time Triggers MUST NOT insert fake rows into `TicketActivityLogs`. They must route directly into `AutomationTriggerQueueSummary`.

---

## 3. Core Architecture & Responsibility
                       EVENT SOURCES
                            │
          ┌─────────────────┴──────────────────┐
          │                                    │
Ticket Create/Update/Reply              Time Trigger Scanner
          │                                    │
          ▼                                    │
 TicketActivityLogs                           │
          │                                    │
          ▼                                    │
 History Collector                            │
          │                                    │
          └─────────────────┬──────────────────┘
                            ▼
              AutomationTriggerQueueSummary
                            │
                            ▼
               Automation Rule Evaluator
                            │
              FIRST_MATCH / ALL_MATCH Selection
                            │
                            ▼
                AutomationExecutions (Execution Lineage)
                            │
                            ▼
            AutomationExecutionActions (Immutable Action)
                            │
================ DATABASE / APP BOUNDARY ================
                            │
                            ▼
                Go Automation Worker (Stateless)
                            │
                  Resolve Placeholders
                            │
                    Execute Action (Rate Limited)
                            │
                 Ticket/Email/etc.
                            │
                            ▼
                 TicketActivityLogs (Next Cycle)

---

## 4. Step-by-Step Execution Phases

### Phase 1: Database Schema Setup (Create `01-DDL.sql`)
Build the foundation tables for the Automation domain:
1. **Configuration Tables:**
   - `AutomationEventSettings` (EventType, ExecutionMode)
   - `AutomationTriggers` & `AutomationTriggerBlocks` & `AutomationTriggerRules` & `AutomationTriggerActions`
   - `AutomationSettings` (MaxExecutionDepth default to 10)
   - `BusinessCalendars`, `BusinessCalendarSchedules`, `BusinessCalendarHolidays`
2. **Queue & Evaluation Tables:**
   - `AutomationTriggerQueueSummary` (Include fields: `QueueSourceType`, `CandidateTriggerId`, `EvaluationBucket`, `SourceAutomationExecutionId`, `RootExecutionId`, `ExecutionDepth`, `OccurredAt`, `BusinessCalendarId`, `IsBusinessHour`, `IsHoliday`)
   - `AutomationTriggerQueueSource` (Mapping to `TicketActivityLogs`)
   - `AutomationTriggerQueueDelta` & `AutomationTriggerQueueRule`
3. **Execution Tables:**
   - `AutomationExecutions` (Include lineage fields: `ParentExecutionId`, `RootExecutionId`, `ExecutionDepth`, `SkipReason`)
   - `AutomationExecutionActions` (Include fields: `RenderedValue`, `RenderedAt`)
4. **Integration Schema:**
   - Alter existing `TicketActivityLogs` to add `AutomationExecutionId UNIQUEIDENTIFIER NULL`.

### Phase 2: Event Sourcing & Collector (Create `02` and `03` SQL files)
1. **`02-TicketActivityIntegration.sql`:** 
   - Create SPs (`ganymede_ticketActivityLogCreateForCreatedTicket`, `ForPublicReply`, `ForUpdatedTicket`).
   - Accept `@AutomationExecutionId UNIQUEIDENTIFIER = NULL` in all SPs.
2. **`03-SP-Collector.sql`:**
   - Implement `ganymede_automationTriggerQueueCollectBatch`.
   - Read `AutomationExecutionId` from `TicketActivityLogs`. Calculate parent, root execution, and `NextExecutionDepth` for the new queue row.
   - Populate `QueueSourceType = 'ACTIVITY_LOG'`.
   - Materialize `OccurredAt` and resolve `DEFAULT`, `CUSTOM`, and `EVENT` field sources.

### Phase 3: The Evaluator Engine (Create `04-SP-Evaluator.sql`)
1. Implement `ganymede_automationEvaluateBatch`.
2. Support dynamic evaluation of rules (`EQUALS`, `CONTAINS`, `CHANGED_FROM`, etc.).
3. **Cascade Protection:** Add enforcement: `IF NextExecutionDepth > MaxExecutionDepth` -> skip execution creation, set `SkipReason = 'SKIPPED_MAX_DEPTH'`, but mark queue as completed.
4. Support `CandidateTriggerId` (if NOT NULL, limit evaluation scope for Time Triggers).
5. Apply `FIRST_MATCH` or `ALL_MATCH` logic from `AutomationEventSettings`.
6. Insert selected triggers into `AutomationExecutions` and snapshot actions into `AutomationExecutionActions`.

### Phase 4: Time Triggers & Business Hours (Create `10` and `11` SQL files)
1. **`11-SP-BusinessCalendar.sql`:**
   - Implement `dbo.ganymede_businessCalendarResolve`. Handle UTC conversion, detect day of week, check working hours, and check holiday overrides. Return `IsBusinessHour` and `IsHoliday`.
2. **`10-SP-TimeTrigger.sql`:**
   - Implement `dbo.ganymede_automationTimeTriggerScanBatch`.
   - Read triggers with `EventType = 'TIME_TRIGGER'`.
   - Implement "cheap pre-filtering" to avoid full table scans.
   - Insert into `AutomationTriggerQueueSummary` with `QueueSourceType = 'TIME_TRIGGER'`.
   - Enforce idempotency uniquely identifying `TicketId + CandidateTriggerId + EvaluationBucket`.

### Phase 5: Application Worker (Create `05-SP-ApplicationWorker.sql` & Go implementation)
1. **SQL Worker API:** 
   - Implement `ganymede_automationExecutionActionClaimBatch` ensuring atomic claims using `UPDLOCK, READPAST`. Output all required execution lineage and action values.
   - Implement `ganymede_automationExecutionActionComplete`.
2. **Go Repository & Services:**
   - Update models in `tickettypes` to handle `AutomationExecutionId`.
   - Ensure all Ticket mutations (Create, Update, Reply, Note) are executed synchronously to guarantee ActivityLog capture.
3. **Go Worker Core Loop:**
   - Call `ClaimBatch`.
   - For each action -> Run `PlaceholderResolver` mapping variables like `{{ticket.status}}` -> Store result in `RenderedValue`.
   - Switch-case based on `ActionType` (`SET_STATUS`, `SEND_EMAIL`, etc.).
   - Execute domain logic using existing services (e.g., `ticketService.UpdateStatus`).
   - IMPORTANT: Pass `ActionExecutionId` as the `AutomationExecutionId` back down to the ticket service so the resulting activity log carries the lineage.
4. **Rate Limiting (Hook):** Add a Redis-based hook/middleware for outbound actions (`SEND_EMAIL`, `ADD_REPLY`) using key format `automation:outbound:{ticketId}:{actionType}:{target}`.

### Phase 6: Jobs Setup & Verification (Create `06`, `07`, `08` SQL files)
1. Set up SQL Agent jobs: `History Collector` (every 10s), `Rule Evaluator` (every 10s), and `Time Trigger Scanner` (every 1 hour).
2. Prepare Seed Data (`07`) to validate `FIRST_MATCH` vs `ALL_MATCH`, Cascade loops, and Time Trigger boundaries.
3. Write Verification Queries (`08`) to audit Queue to Execution lineage.

---

## 5. Acceptance Criteria
Implementation is complete when:
- Automation creates new traceable events with valid `RootExecutionId`, `ParentExecutionId`, and `ExecutionDepth`.
- Infinite loops (A triggers B, B triggers A) halt gracefully at `MaxExecutionDepth`.
- Time Scanner correctly generates action items without polluting `TicketActivityLogs` with fake events.
- Placeholder template outputs (`RenderedValue`) are persisted accurately without altering the source configuration (`ActionValue`).
- DB purely manages state/logic; Go exclusively handles API boundaries, placeholder rendering, and side-effects.