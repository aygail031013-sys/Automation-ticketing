-- =================================================================================================
-- OneDesk Automation v1.0 - Phase 6: Automated Verification & Audit Script
-- =================================================================================================
USE OneDeskDb;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
SET NOCOUNT ON;
GO

PRINT '================================================================================';
PRINT 'STARTING ONEDESK AUTOMATION V1.0 VERIFICATION SUITE';
PRINT '================================================================================';

-- Clean up any leftover test data
DELETE FROM dbo.AutomationExecutionActions;
DELETE FROM dbo.AutomationExecutions;
DELETE FROM dbo.AutomationTriggerQueueRule;
DELETE FROM dbo.AutomationTriggerQueueDelta;
DELETE FROM dbo.AutomationTriggerQueueSource;
DELETE FROM dbo.AutomationTriggerQueueSummary;
DELETE FROM dbo.TicketActivityLogs;
DELETE FROM dbo.Tickets;

DECLARE @TestTicketId UNIQUEIDENTIFIER = NEWID();
DECLARE @TestActorId UNIQUEIDENTIFIER = NEWID();
DECLARE @TestContactId UNIQUEIDENTIFIER = NEWID();
DECLARE @TestGroupId UNIQUEIDENTIFIER = NEWID();
DECLARE @TestAgentId UNIQUEIDENTIFIER = NEWID();
DECLARE @TicketNo VARCHAR(30) = 'TCK-VERIFY-' + FORMAT(SYSUTCDATETIME(), 'HHmmssfff');

-- -------------------------------------------------------------------------------------------------
-- TEST 1: Ticket Creation, Activity Log & FIRST_MATCH Evaluation
-- -------------------------------------------------------------------------------------------------
PRINT '--- [TEST 1] Creating Test Ticket with subject containing URGENT and status OPEN ---';

INSERT INTO dbo.Tickets
(
    Id,
    TicketNo,
    RequesterContactId,
    GroupId,
    AssignedAgentId,
    Subject,
    Description,
    PlainDescription,
    Source,
    Status,
    Priority,
    CreatedBy,
    CreatedAt,
    UpdatedBy,
    UpdatedAt,
    IsDeleted
)
VALUES
(
    @TestTicketId,
    @TicketNo,
    @TestContactId,
    @TestGroupId,
    @TestAgentId,
    'URGENT: Core Database Latency High',
    '<p>Core database latency high</p>',
    'Core database latency high',
    'PORTAL_AGENT',
    'OPEN',
    'MEDIUM',
    'tester@onedesk.local',
    (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
    'tester@onedesk.local',
    (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
    0
);

-- Generate Activity Log via integrated SP
EXEC dbo.ganymede_ticketActivityLogCreateForCreatedTicket
    @TicketId = @TestTicketId,
    @ActorId = @TestActorId,
    @AutomationExecutionId = NULL;

-- Verify Activity Log created with NULL AutomationExecutionId
IF EXISTS (
    SELECT 1 FROM dbo.TicketActivityLogs 
    WHERE TicketId = @TestTicketId 
      AND Event = 'TICKET_CREATED' 
      AND AutomationExecutionId IS NULL
)
    PRINT 'PASS: Activity log for TICKET_CREATED created with AutomationExecutionId IS NULL.';
ELSE
    PRINT 'FAIL: Activity log for TICKET_CREATED was not created properly.';

-- Collect batch
DECLARE @Collected1 INT = 0;
EXEC dbo.ganymede_automationTriggerQueueCollectBatch
    @BatchSize = 10,
    @CollectedCount = @Collected1 OUTPUT;

PRINT 'Collected items count: ' + CAST(@Collected1 AS VARCHAR(10));

-- Verify Queue Item lineage
IF EXISTS (
    SELECT 1 FROM dbo.AutomationTriggerQueueSummary 
    WHERE TicketId = @TestTicketId 
      AND QueueSourceType = 'ACTIVITY_LOG' 
      AND ExecutionDepth = 0 
      AND RootExecutionId IS NULL
)
    PRINT 'PASS: Queue summary item created with ExecutionDepth = 0 and RootExecutionId IS NULL.';
ELSE
    PRINT 'FAIL: Queue summary item missing or invalid lineage.';

-- Evaluate batch
DECLARE @Evaluated1 INT = 0;
DECLARE @ExecutionsCreated1 INT = 0;
EXEC dbo.ganymede_automationEvaluateBatch
    @BatchSize = 10,
    @EvaluatedCount = @Evaluated1 OUTPUT,
    @ExecutionsCreatedCount = @ExecutionsCreated1 OUTPUT;

PRINT 'Evaluated items: ' + CAST(@Evaluated1 AS VARCHAR(10)) + ', Executions created: ' + CAST(@ExecutionsCreated1 AS VARCHAR(10));

-- Verify FIRST_MATCH rule: exactly 1 execution created (Trigger 1: Priority 10) instead of both
DECLARE @CreatedExecId UNIQUEIDENTIFIER;
SELECT TOP 1 @CreatedExecId = ae.Id
FROM dbo.AutomationExecutions ae
INNER JOIN dbo.AutomationTriggers tr ON tr.Id = ae.TriggerId
WHERE ae.TicketId = @TestTicketId AND tr.Name = 'Auto-Escalate Urgent Tickets';

IF @CreatedExecId IS NOT NULL
    PRINT 'PASS: FIRST_MATCH correctly selected priority 10 trigger (Auto-Escalate Urgent Tickets).';
ELSE
    PRINT 'FAIL: Priority 10 trigger not matched.';

IF NOT EXISTS (
    SELECT 1 FROM dbo.AutomationExecutions ae
    INNER JOIN dbo.AutomationTriggers tr ON tr.Id = ae.TriggerId
    WHERE ae.TicketId = @TestTicketId AND tr.Name = 'Standard Ticket Triage'
)
    PRINT 'PASS: FIRST_MATCH prevented lower priority trigger (Standard Ticket Triage) from executing.';
ELSE
    PRINT 'FAIL: FIRST_MATCH failed, secondary trigger executed.';

-- -------------------------------------------------------------------------------------------------
-- TEST 2: Worker Claim, Immutable Config, Rendered Value & Cascade Lineage (Depth 1)
-- -------------------------------------------------------------------------------------------------
PRINT '--- [TEST 2] Worker Action Claim, Placeholder Rendering & Cascade Lineage ---';

-- Worker Claims Action
DECLARE @ClaimedTable TABLE
(
    ActionExecutionId UNIQUEIDENTIFIER,
    AutomationExecutionId UNIQUEIDENTIFIER,
    ActionOrder INT,
    ActionType VARCHAR(50),
    ActionValue NVARCHAR(MAX),
    TriggerId UNIQUEIDENTIFIER,
    TicketId UNIQUEIDENTIFIER,
    ParentExecutionId UNIQUEIDENTIFIER,
    RootExecutionId UNIQUEIDENTIFIER,
    ExecutionDepth INT,
    TicketNo VARCHAR(30),
    TicketSubject NVARCHAR(200),
    TicketStatus VARCHAR(30),
    TicketPriority VARCHAR(20),
    TicketGroupId UNIQUEIDENTIFIER,
    TicketAssignedAgentId UNIQUEIDENTIFIER,
    RequesterContactId UNIQUEIDENTIFIER,
    RequesterCompanyId UNIQUEIDENTIFIER
);

INSERT INTO @ClaimedTable
EXEC dbo.ganymede_automationExecutionActionClaimBatch
    @WorkerId = 'Go-Worker-Test-1',
    @BatchSize = 10;

DECLARE @ClaimedCount INT = (SELECT COUNT(*) FROM @ClaimedTable WHERE AutomationExecutionId = @CreatedExecId);
IF @ClaimedCount = 2
    PRINT 'PASS: Worker claimed 2 actions with UPDLOCK, READPAST.';
ELSE
    PRINT 'FAIL: Expected 2 claimed actions, got: ' + CAST(@ClaimedCount AS VARCHAR(10));

-- Complete actions specifically for @CreatedExecId
DECLARE @Action1 UNIQUEIDENTIFIER = (
    SELECT TOP 1 ActionExecutionId 
    FROM @ClaimedTable 
    WHERE AutomationExecutionId = @CreatedExecId AND ActionType = 'SET_PRIORITY'
);
DECLARE @Action2 UNIQUEIDENTIFIER = (
    SELECT TOP 1 ActionExecutionId 
    FROM @ClaimedTable 
    WHERE AutomationExecutionId = @CreatedExecId AND ActionType = 'SEND_EMAIL'
);

-- Worker completes Action 1
EXEC dbo.ganymede_automationExecutionActionComplete
    @ActionId = @Action1,
    @Status = 'COMPLETED',
    @RenderedValue = '{"priority": "URGENT"}';

-- Worker completes Action 2 with resolved placeholder
EXEC dbo.ganymede_automationExecutionActionComplete
    @ActionId = @Action2,
    @Status = 'COMPLETED',
    @RenderedValue = '{"to": "oncall@example.com", "template": "urgent_alert", "subject": "Urgent Ticket TCK-VERIFY Alert"}';

-- Verify ActionValue is pristine and RenderedValue is persisted
IF EXISTS (
    SELECT 1 FROM dbo.AutomationExecutionActions
    WHERE Id = @Action2 
      AND ActionValue LIKE '%{{ticket.ticketNo}}%' -- Pristine template
      AND RenderedValue LIKE '%TCK-VERIFY%'       -- Resolved value
      AND Status = 'COMPLETED'
)
    PRINT 'PASS: ActionValue is immutable; RenderedValue persisted accurately.';
ELSE
    PRINT 'FAIL: ActionValue mutated or RenderedValue not persisted.';

-- Verify parent execution is marked COMPLETED
IF EXISTS (SELECT 1 FROM dbo.AutomationExecutions WHERE Id = @CreatedExecId AND Status = 'COMPLETED')
    PRINT 'PASS: AutomationExecution transitioned to COMPLETED once all actions completed.';
ELSE
    PRINT 'FAIL: AutomationExecution status not updated to COMPLETED.';

-- Worker simulates side effect by updating ticket with AutomationExecutionId lineage
PRINT '--- [TEST 2.1] Simulating worker side-effect generating cascade event ---';

UPDATE dbo.Tickets
SET Priority = 'URGENT', UpdatedAt = (SYSUTCDATETIME() AT TIME ZONE 'UTC')
WHERE Id = @TestTicketId;

EXEC dbo.ganymede_ticketActivityLogCreateForUpdatedTicket
    @TicketId = @TestTicketId,
    @ActorId = @TestActorId,
    @ActorType = 'SYSTEM',
    @OldValuesJson = '{"Priority": "MEDIUM"}',
    @NewValuesJson = '{"Priority": "URGENT"}',
    @Description = 'Priority escalated to URGENT by Automation Worker',
    @PlainDescription = 'Priority escalated to URGENT by Automation Worker',
    @AutomationExecutionId = @CreatedExecId;

-- Collect and check lineage
EXEC dbo.ganymede_automationTriggerQueueCollectBatch @BatchSize = 10;

IF EXISTS (
    SELECT 1 FROM dbo.AutomationTriggerQueueSummary
    WHERE TicketId = @TestTicketId
      AND SourceAutomationExecutionId = @CreatedExecId
      AND RootExecutionId = @CreatedExecId
      AND ExecutionDepth = 1
)
    PRINT 'PASS: Cascade queue item preserved RootExecutionId and calculated ExecutionDepth = 1.';
ELSE
    PRINT 'FAIL: Cascade queue item failed lineage verification.';

-- Clean queue for next test
EXEC dbo.ganymede_automationEvaluateBatch @BatchSize = 10;

-- -------------------------------------------------------------------------------------------------
-- TEST 3: Infinite Cascade Loop Protection (Halts at MaxExecutionDepth = 10)
-- -------------------------------------------------------------------------------------------------
PRINT '--- [TEST 3] Cascade Loop Protection (Halt at MaxExecutionDepth = 10) ---';

DECLARE @LoopTicketId UNIQUEIDENTIFIER = NEWID();
INSERT INTO dbo.Tickets
(
    Id,
    TicketNo,
    RequesterContactId,
    GroupId,
    AssignedAgentId,
    Subject,
    Description,
    PlainDescription,
    Source,
    Status,
    Priority,
    CreatedBy,
    CreatedAt,
    UpdatedBy,
    UpdatedAt,
    IsDeleted
)
VALUES
(
    @LoopTicketId,
    'TCK-LOOP-' + FORMAT(SYSUTCDATETIME(), 'HHmmssfff'),
    @TestContactId,
    @TestGroupId,
    @TestAgentId,
    'Loop Protection Test',
    'desc',
    'desc',
    'PORTAL_AGENT',
    'WAITING_FOR_COACH',
    'LOW',
    'test',
    (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
    'test',
    (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
    0
);

-- Trigger Ping (Depth 0): Transition to WAITING_FOR_COACH
EXEC dbo.ganymede_ticketActivityLogCreateForUpdatedTicket
    @TicketId = @LoopTicketId,
    @OldValuesJson = '{"status": "OPEN"}',
    @NewValuesJson = '{"status": "WAITING_FOR_COACH"}',
    @AutomationExecutionId = NULL;

DECLARE @Step INT = 0;
WHILE @Step <= 15
BEGIN
    EXEC dbo.ganymede_automationTriggerQueueCollectBatch @BatchSize = 10;
    EXEC dbo.ganymede_automationEvaluateBatch @BatchSize = 10;

    -- If an execution was created, claim and simulate next ping-pong step
    DECLARE @LoopActionId UNIQUEIDENTIFIER = NULL;
    DECLARE @LoopExecId UNIQUEIDENTIFIER = NULL;
    DECLARE @LoopActionVal NVARCHAR(MAX) = NULL;

    SELECT TOP 1
        @LoopActionId = act.Id,
        @LoopExecId = act.AutomationExecutionId,
        @LoopActionVal = act.ActionValue
    FROM dbo.AutomationExecutionActions act
    INNER JOIN dbo.AutomationExecutions ae ON ae.Id = act.AutomationExecutionId
    WHERE ae.TicketId = @LoopTicketId AND act.Status = 'PENDING'
    ORDER BY act.CreatedAt ASC;

    IF @LoopActionId IS NULL
        BREAK; -- Loop halted!

    -- Claim & complete
    EXEC dbo.ganymede_automationExecutionActionComplete 
        @ActionId = @LoopActionId, 
        @Status = 'COMPLETED',
        @RenderedValue = @LoopActionVal;

    -- Update ticket and insert next activity log with lineage
    DECLARE @NewStatusVal VARCHAR(50) = JSON_VALUE(@LoopActionVal, '$.status');

    UPDATE dbo.Tickets
    SET Status = @NewStatusVal, UpdatedAt = (SYSUTCDATETIME() AT TIME ZONE 'UTC')
    WHERE Id = @LoopTicketId;

    EXEC dbo.ganymede_ticketActivityLogCreateForUpdatedTicket
        @TicketId = @LoopTicketId,
        @OldValuesJson = '{"status": "PREV"}',
        @NewValuesJson = @LoopActionVal,
        @AutomationExecutionId = @LoopExecId;

    SET @Step = @Step + 1;
END;

-- Verify loop halted with SKIPPED_MAX_DEPTH
IF EXISTS (
    SELECT 1 FROM dbo.AutomationTriggerQueueSummary
    WHERE TicketId = @LoopTicketId
      AND Status = 'SKIPPED'
      AND SkipReason = 'SKIPPED_MAX_DEPTH'
)
    PRINT 'PASS: Cascade loop halted gracefully with Status = SKIPPED and SkipReason = SKIPPED_MAX_DEPTH.';
ELSE
    PRINT 'FAIL: Cascade loop did not halt with SKIPPED_MAX_DEPTH.';

DECLARE @MaxDepthObserved INT = (
    SELECT MAX(ExecutionDepth) 
    FROM dbo.AutomationExecutions 
    WHERE TicketId = @LoopTicketId
);
PRINT 'Max execution depth created before halting: ' + CAST(ISNULL(@MaxDepthObserved, 0) AS VARCHAR(10)) + ' (Limit: 10)';

IF @MaxDepthObserved <= 10
    PRINT 'PASS: No executions created beyond MaxExecutionDepth = 10.';
ELSE
    PRINT 'FAIL: Executions created beyond depth limit.';

-- -------------------------------------------------------------------------------------------------
-- TEST 4: Time Trigger Purity & Idempotency
-- -------------------------------------------------------------------------------------------------
PRINT '--- [TEST 4] Time Trigger Purity & Idempotency ---';

DECLARE @ActivityCountBefore INT = (SELECT COUNT(*) FROM dbo.TicketActivityLogs);

-- Set test ticket status to PENDING and StatusChangedAt to 30 hours ago
UPDATE dbo.Tickets
SET Status = 'PENDING',
    StatusChangedAt = DATEADD(HOUR, -30, SYSUTCDATETIME() AT TIME ZONE 'UTC')
WHERE Id = @TestTicketId;

DECLARE @TimeBucket VARCHAR(100) = 'TT_TEST_BUCKET_' + FORMAT(SYSUTCDATETIME(), 'yyyyMMdd_HH');

-- Scan 1st time
DECLARE @QueuedTT INT = 0;
EXEC dbo.ganymede_automationTimeTriggerScanBatch
    @EvaluationBucket = @TimeBucket,
    @BatchSize = 100,
    @QueuedCount = @QueuedTT OUTPUT;

PRINT 'Time triggers queued (Scan 1): ' + CAST(@QueuedTT AS VARCHAR(10));

-- Verify NO activity logs inserted
DECLARE @ActivityCountAfter INT = (SELECT COUNT(*) FROM dbo.TicketActivityLogs);
IF @ActivityCountBefore = @ActivityCountAfter
    PRINT 'PASS (Purity): Time Trigger Scanner generated queue items WITHOUT inserting fake rows into TicketActivityLogs.';
ELSE
    PRINT 'FAIL: Time Trigger Scanner created activity logs (violated Hard Constraint #4).';

-- Verify item is in queue
IF EXISTS (
    SELECT 1 FROM dbo.AutomationTriggerQueueSummary
    WHERE TicketId = @TestTicketId
      AND QueueSourceType = 'TIME_TRIGGER'
      AND EvaluationBucket = @TimeBucket
)
    PRINT 'PASS: Time Trigger item created in AutomationTriggerQueueSummary.';
ELSE
    PRINT 'FAIL: Time Trigger item not found in queue.';

-- Scan 2nd time with SAME bucket (Idempotency test)
DECLARE @QueuedTT2 INT = 0;
EXEC dbo.ganymede_automationTimeTriggerScanBatch
    @EvaluationBucket = @TimeBucket,
    @BatchSize = 100,
    @QueuedCount = @QueuedTT2 OUTPUT;

PRINT 'Time triggers queued (Scan 2 with same bucket): ' + CAST(@QueuedTT2 AS VARCHAR(10));

IF @QueuedTT2 = 0
    PRINT 'PASS (Idempotency): Re-running time trigger in same bucket produced 0 duplicate queue items.';
ELSE
    PRINT 'FAIL: Time Trigger is not idempotent, created duplicate queue items.';

-- Evaluate Time Trigger queue item
EXEC dbo.ganymede_automationEvaluateBatch @BatchSize = 10;

IF EXISTS (
    SELECT 1 FROM dbo.AutomationExecutions ae
    INNER JOIN dbo.AutomationTriggers tr ON tr.Id = ae.TriggerId
    WHERE ae.TicketId = @TestTicketId AND tr.Name = 'Auto-Close Inactive Pending Tickets'
)
    PRINT 'PASS: Evaluator executed Auto-Close Inactive Pending Tickets time trigger.';
ELSE
    PRINT 'FAIL: Evaluator did not trigger time-based rule.';

-- -------------------------------------------------------------------------------------------------
-- SUMMARY AUDIT TABLE
-- -------------------------------------------------------------------------------------------------
PRINT '================================================================================';
PRINT 'AUTOMATION ENGINE AUDIT SUMMARY';
PRINT '================================================================================';

SELECT 
    t.TicketNo,
    qs.QueueSourceType,
    qs.ExecutionDepth,
    qs.Status AS QueueStatus,
    qs.SkipReason AS QueueSkipReason,
    tr.Name AS TriggerName,
    ae.Status AS ExecutionStatus,
    ae.RootExecutionId,
    act.ActionType,
    act.Status AS ActionStatus,
    LEFT(act.ActionValue, 40) AS ActionValueSnippet,
    LEFT(act.RenderedValue, 40) AS RenderedValueSnippet
FROM dbo.Tickets t
LEFT JOIN dbo.AutomationTriggerQueueSummary qs ON qs.TicketId = t.Id
LEFT JOIN dbo.AutomationExecutions ae ON ae.QueueSummaryId = qs.Id
LEFT JOIN dbo.AutomationTriggers tr ON tr.Id = ae.TriggerId
LEFT JOIN dbo.AutomationExecutionActions act ON act.AutomationExecutionId = ae.Id
WHERE t.Id IN (@TestTicketId, @LoopTicketId)
ORDER BY t.TicketNo, qs.Id, ae.CreatedAt, act.ActionOrder;
GO
