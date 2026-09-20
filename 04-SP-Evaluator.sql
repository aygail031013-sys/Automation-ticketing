-- =================================================================================================
-- OneDesk Automation - set-based rule evaluation, deterministic selection, and action dispatch
-- =================================================================================================
USE OneDeskDb;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.ganymede_automationEvaluateBatch
    @BatchSize INT = 100,
    @EvaluatedCount INT = 0 OUTPUT,
    @ExecutionsCreatedCount INT = 0 OUTPUT,
    @WorkerId VARCHAR(100) = 'DB-Evaluator'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @BatchSize = CASE WHEN @BatchSize BETWEEN 1 AND 1000 THEN @BatchSize ELSE 100 END;
    SET @EvaluatedCount = 0;
    SET @ExecutionsCreatedCount = 0;

    DECLARE @Now DATETIMEOFFSET = SYSUTCDATETIME() AT TIME ZONE 'UTC';
    DECLARE @MaxDepth INT = COALESCE
    (
        (SELECT TRY_CONVERT(INT, SettingValue) FROM dbo.AutomationSettings WHERE SettingKey = 'MaxExecutionDepth'),
        10
    );

    CREATE TABLE #Claimed
    (
        QueueSummaryId BIGINT NOT NULL PRIMARY KEY,
        TicketId UNIQUEIDENTIFIER NOT NULL,
        EventType VARCHAR(50) NOT NULL,
        CandidateTriggerId UNIQUEIDENTIFIER NULL,
        SourceAutomationExecutionId UNIQUEIDENTIFIER NULL,
        RootExecutionId UNIQUEIDENTIFIER NULL,
        ExecutionDepth INT NOT NULL
    );

    CREATE TABLE #Evaluations
    (
        EvaluationId UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
        QueueSummaryId BIGINT NOT NULL,
        TicketId UNIQUEIDENTIFIER NOT NULL,
        EventType VARCHAR(50) NOT NULL,
        TriggerId UNIQUEIDENTIFIER NOT NULL,
        ExecutionMode VARCHAR(20) NOT NULL,
        SortOrder INT NOT NULL,
        IsMatch BIT NOT NULL DEFAULT (0),
        IsSelected BIT NOT NULL DEFAULT (0),
        UNIQUE (QueueSummaryId, TriggerId)
    );

    CREATE TABLE #RuleResults
    (
        EvaluationId UNIQUEIDENTIFIER NOT NULL,
        QueueSummaryId BIGINT NOT NULL,
        TriggerId UNIQUEIDENTIFIER NOT NULL,
        TriggerBlockId UNIQUEIDENTIFIER NOT NULL,
        RuleId UNIQUEIDENTIFIER NOT NULL,
        FieldSource VARCHAR(20) NOT NULL,
        FieldCode VARCHAR(100) NOT NULL,
        Operator VARCHAR(50) NOT NULL,
        FromValue NVARCHAR(MAX) NULL,
        ToValue NVARCHAR(MAX) NULL,
        ExpectedValue NVARCHAR(MAX) NULL,
        IsMatch BIT NOT NULL,
        PRIMARY KEY (EvaluationId, RuleId)
    );

    CREATE TABLE #BlockResults
    (
        EvaluationId UNIQUEIDENTIFIER NOT NULL,
        TriggerBlockId UNIQUEIDENTIFIER NOT NULL,
        LogicalOperator VARCHAR(10) NOT NULL,
        IsMatch BIT NOT NULL,
        PRIMARY KEY (EvaluationId, TriggerBlockId)
    );

    CREATE TABLE #Selected
    (
        EvaluationId UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
        ExecutionId UNIQUEIDENTIFIER NOT NULL UNIQUE,
        QueueSummaryId BIGINT NOT NULL,
        TicketId UNIQUEIDENTIFIER NOT NULL,
        TriggerId UNIQUEIDENTIFIER NOT NULL,
        SortOrder INT NOT NULL
    );

    BEGIN TRY
        BEGIN TRANSACTION;

        ;WITH Claimable AS
        (
            SELECT TOP (@BatchSize) summary.*
            FROM dbo.AutomationTriggerQueueSummary AS summary WITH (UPDLOCK, READPAST, ROWLOCK)
            WHERE summary.Status = 'PENDING'
               OR (summary.Status = 'PROCESSING' AND summary.LeaseExpiresAt < @Now)
            ORDER BY summary.OccurredAt, summary.Id
        )
        UPDATE Claimable
        SET Status = 'PROCESSING',
            ClaimedBy = @WorkerId,
            ClaimedAt = @Now,
            LeaseExpiresAt = DATEADD(MINUTE, 5, @Now),
            ErrorMessage = NULL
        OUTPUT
            inserted.Id, inserted.TicketId, inserted.EventType, inserted.CandidateTriggerId,
            inserted.SourceAutomationExecutionId, inserted.RootExecutionId, inserted.ExecutionDepth
        INTO #Claimed
        (
            QueueSummaryId, TicketId, EventType, CandidateTriggerId,
            SourceAutomationExecutionId, RootExecutionId, ExecutionDepth
        );

        SELECT @EvaluatedCount = COUNT(*) FROM #Claimed;

        UPDATE summary
        SET Status = 'SKIPPED',
            SkipReason = 'SKIPPED_MAX_DEPTH',
            ProcessedAt = @Now,
            LeaseExpiresAt = NULL
        FROM dbo.AutomationTriggerQueueSummary AS summary
        INNER JOIN #Claimed AS claimed ON claimed.QueueSummaryId = summary.Id
        WHERE claimed.ExecutionDepth > @MaxDepth;

        DELETE FROM #Claimed WHERE ExecutionDepth > @MaxDepth;

        INSERT #Evaluations
        (
            EvaluationId, QueueSummaryId, TicketId, EventType, TriggerId,
            ExecutionMode, SortOrder, IsMatch, IsSelected
        )
        SELECT
            NEWID(), claimed.QueueSummaryId, claimed.TicketId, trigger_definition.EventType, trigger_definition.Id,
            COALESCE(setting.ExecutionMode, 'FIRST_MATCH'), trigger_definition.Priority, 0, 0
        FROM #Claimed AS claimed
        INNER JOIN dbo.AutomationTriggers AS trigger_definition
            ON trigger_definition.IsActive = 1
           AND
           (
               (claimed.CandidateTriggerId IS NOT NULL AND trigger_definition.Id = claimed.CandidateTriggerId)
               OR
               (claimed.CandidateTriggerId IS NULL AND
                (
                    trigger_definition.EventType = claimed.EventType
                    OR
                    (
                        claimed.EventType = 'TICKET_UPDATED'
                        AND
                        (
                            (trigger_definition.EventType = 'STATUS_CHANGED' AND EXISTS
                                (SELECT 1 FROM dbo.AutomationTriggerQueueDelta d WHERE d.QueueSummaryId = claimed.QueueSummaryId AND d.FieldSource = 'DEFAULT' AND LOWER(d.FieldCode) = 'status' AND COALESCE(d.OldValue, '') <> COALESCE(d.NewValue, '')))
                            OR (trigger_definition.EventType = 'PRIORITY_CHANGED' AND EXISTS
                                (SELECT 1 FROM dbo.AutomationTriggerQueueDelta d WHERE d.QueueSummaryId = claimed.QueueSummaryId AND d.FieldSource = 'DEFAULT' AND LOWER(d.FieldCode) = 'priority' AND COALESCE(d.OldValue, '') <> COALESCE(d.NewValue, '')))
                            OR (trigger_definition.EventType = 'GROUP_CHANGED' AND EXISTS
                                (SELECT 1 FROM dbo.AutomationTriggerQueueDelta d WHERE d.QueueSummaryId = claimed.QueueSummaryId AND d.FieldSource = 'DEFAULT' AND LOWER(d.FieldCode) = 'groupid' AND COALESCE(d.OldValue, '') <> COALESCE(d.NewValue, '')))
                            OR (trigger_definition.EventType = 'ASSIGNEE_CHANGED' AND EXISTS
                                (SELECT 1 FROM dbo.AutomationTriggerQueueDelta d WHERE d.QueueSummaryId = claimed.QueueSummaryId AND d.FieldSource = 'DEFAULT' AND LOWER(d.FieldCode) = 'assignedagentid' AND COALESCE(d.OldValue, '') <> COALESCE(d.NewValue, '')))
                        )
                    )
                    OR
                    (
                        claimed.EventType = 'PUBLIC_REPLY_ADDED'
                        AND
                        (
                            (trigger_definition.EventType = 'REQUESTER_REPLIED' AND EXISTS
                                (SELECT 1 FROM dbo.AutomationTriggerQueueDelta d WHERE d.QueueSummaryId = claimed.QueueSummaryId AND d.FieldSource = 'EVENT' AND LOWER(d.FieldCode) = 'actortype' AND UPPER(d.NewValue) = 'CUSTOMER'))
                            OR (trigger_definition.EventType = 'AGENT_REPLIED' AND EXISTS
                                (SELECT 1 FROM dbo.AutomationTriggerQueueDelta d WHERE d.QueueSummaryId = claimed.QueueSummaryId AND d.FieldSource = 'EVENT' AND LOWER(d.FieldCode) = 'actortype' AND UPPER(d.NewValue) = 'AGENT'))
                        )
                    )
                    OR (claimed.EventType = 'TIME_TRIGGER' AND trigger_definition.EventType = 'SCHEDULE_DUE')
                ))
           )
        LEFT JOIN dbo.AutomationEventSettings AS setting
            ON setting.EventType = trigger_definition.EventType AND setting.IsActive = 1;

        INSERT dbo.AutomationEvaluations
        (
            Id, QueueSummaryId, TicketId, TriggerId, EventType, ExecutionMode,
            SortOrder, IsMatch, IsSelected, EvaluatedAt
        )
        SELECT
            EvaluationId, QueueSummaryId, TicketId, TriggerId, EventType, ExecutionMode,
            SortOrder, 0, 0, @Now
        FROM #Evaluations;

        INSERT #RuleResults
        (
            EvaluationId, QueueSummaryId, TriggerId, TriggerBlockId, RuleId,
            FieldSource, FieldCode, Operator, FromValue, ToValue, ExpectedValue, IsMatch
        )
        SELECT
            evaluation.EvaluationId,
            evaluation.QueueSummaryId,
            evaluation.TriggerId,
            block.Id,
            rule_definition.Id,
            rule_definition.FieldSource,
            rule_definition.FieldCode,
            UPPER(rule_definition.Operator),
            actual.OldValue,
            actual.NewValue,
            rule_definition.Value,
            CONVERT(BIT,
                CASE
                    WHEN UPPER(rule_definition.Operator) IN ('EQUALS', '=')
                        AND UPPER(COALESCE(actual.NewValue, '')) = UPPER(COALESCE(rule_definition.Value, '')) THEN 1
                    WHEN UPPER(rule_definition.Operator) IN ('NOT_EQUALS', '!=', '<>')
                        AND UPPER(COALESCE(actual.NewValue, '')) <> UPPER(COALESCE(rule_definition.Value, '')) THEN 1
                    WHEN UPPER(rule_definition.Operator) = 'CONTAINS'
                        AND CHARINDEX(UPPER(COALESCE(rule_definition.Value, '')), UPPER(COALESCE(actual.NewValue, ''))) > 0 THEN 1
                    WHEN UPPER(rule_definition.Operator) = 'NOT_CONTAINS'
                        AND CHARINDEX(UPPER(COALESCE(rule_definition.Value, '')), UPPER(COALESCE(actual.NewValue, ''))) = 0 THEN 1
                    WHEN UPPER(rule_definition.Operator) = 'STARTS_WITH'
                        AND LEFT(UPPER(COALESCE(actual.NewValue, '')), LEN(COALESCE(rule_definition.Value, '')))
                            = UPPER(COALESCE(rule_definition.Value, '')) THEN 1
                    WHEN UPPER(rule_definition.Operator) = 'ENDS_WITH'
                        AND RIGHT(UPPER(COALESCE(actual.NewValue, '')), LEN(COALESCE(rule_definition.Value, '')))
                            = UPPER(COALESCE(rule_definition.Value, '')) THEN 1
                    WHEN UPPER(rule_definition.Operator) = 'IN'
                        AND EXISTS
                        (
                            SELECT 1 FROM STRING_SPLIT(COALESCE(rule_definition.Value, ''), ',') AS item
                            WHERE UPPER(LTRIM(RTRIM(item.value))) = UPPER(COALESCE(actual.NewValue, ''))
                        ) THEN 1
                    WHEN UPPER(rule_definition.Operator) = 'CHANGED'
                        AND COALESCE(actual.OldValue, '') <> COALESCE(actual.NewValue, '') THEN 1
                    WHEN UPPER(rule_definition.Operator) = 'CHANGED_FROM'
                        AND UPPER(COALESCE(actual.OldValue, '')) = UPPER(COALESCE(rule_definition.Value, ''))
                        AND COALESCE(actual.OldValue, '') <> COALESCE(actual.NewValue, '') THEN 1
                    WHEN UPPER(rule_definition.Operator) = 'CHANGED_TO'
                        AND UPPER(COALESCE(actual.NewValue, '')) = UPPER(COALESCE(rule_definition.Value, ''))
                        AND COALESCE(actual.OldValue, '') <> COALESCE(actual.NewValue, '') THEN 1
                    WHEN UPPER(rule_definition.Operator) = 'IS_EMPTY'
                        AND NULLIF(LTRIM(RTRIM(actual.NewValue)), '') IS NULL THEN 1
                    WHEN UPPER(rule_definition.Operator) = 'IS_NOT_EMPTY'
                        AND NULLIF(LTRIM(RTRIM(actual.NewValue)), '') IS NOT NULL THEN 1
                    WHEN UPPER(rule_definition.Operator) IN ('GT', 'GREATER_THAN', '>')
                        AND TRY_CONVERT(DECIMAL(38, 10), actual.NewValue) > TRY_CONVERT(DECIMAL(38, 10), rule_definition.Value) THEN 1
                    WHEN UPPER(rule_definition.Operator) IN ('GTE', 'GREATER_THAN_OR_EQUAL', '>=')
                        AND TRY_CONVERT(DECIMAL(38, 10), actual.NewValue) >= TRY_CONVERT(DECIMAL(38, 10), rule_definition.Value) THEN 1
                    WHEN UPPER(rule_definition.Operator) IN ('LT', 'LESS_THAN', '<')
                        AND TRY_CONVERT(DECIMAL(38, 10), actual.NewValue) < TRY_CONVERT(DECIMAL(38, 10), rule_definition.Value) THEN 1
                    WHEN UPPER(rule_definition.Operator) IN ('LTE', 'LESS_THAN_OR_EQUAL', '<=')
                        AND TRY_CONVERT(DECIMAL(38, 10), actual.NewValue) <= TRY_CONVERT(DECIMAL(38, 10), rule_definition.Value) THEN 1
                    WHEN UPPER(rule_definition.Operator) = 'IS_BUSINESS_HOUR'
                        AND COALESCE(actual.NewValue, '0') = COALESCE(rule_definition.Value, '1') THEN 1
                    WHEN UPPER(rule_definition.Operator) = 'IS_HOLIDAY'
                        AND COALESCE(actual.NewValue, '0') = COALESCE(rule_definition.Value, '1') THEN 1
                    ELSE 0
                END)
        FROM #Evaluations AS evaluation
        INNER JOIN dbo.AutomationTriggerBlocks AS block ON block.TriggerId = evaluation.TriggerId
        INNER JOIN dbo.AutomationTriggerRules AS rule_definition ON rule_definition.TriggerBlockId = block.Id
        OUTER APPLY
        (
            SELECT TOP (1) delta.OldValue, delta.NewValue
            FROM dbo.AutomationTriggerQueueDelta AS delta
            WHERE delta.QueueSummaryId = evaluation.QueueSummaryId
              AND UPPER(delta.FieldSource) = CASE UPPER(rule_definition.FieldSource)
                    WHEN 'TICKET' THEN 'DEFAULT'
                    WHEN 'CUSTOM_FIELD' THEN 'CUSTOM'
                    WHEN 'EVENT_CONTEXT' THEN 'EVENT'
                    ELSE UPPER(rule_definition.FieldSource)
                  END
              AND LOWER(delta.FieldCode) = LOWER(CASE UPPER(rule_definition.FieldCode)
                    WHEN 'DEFAULT_STATUS' THEN 'status'
                    WHEN 'DEFAULT_PRIORITY' THEN 'priority'
                    WHEN 'DEFAULT_SOURCE' THEN 'source'
                    WHEN 'DEFAULT_GROUP' THEN 'groupid'
                    WHEN 'DEFAULT_AGENT' THEN 'assignedagentid'
                    WHEN 'HOURS_SINCE_CREATED' THEN 'hourssincecreated'
                    WHEN 'HOURS_SINCE_UPDATED' THEN 'hourssinceupdated'
                    WHEN 'HOURS_SINCE_STATUS_CHANGED' THEN 'hourssincestatuschanged'
                    WHEN 'EVENT_TYPE' THEN 'event'
                    WHEN 'ACTOR_TYPE' THEN 'actortype'
                    WHEN 'CHANGED_FIELD_CODE' THEN 'changedfieldcode'
                    ELSE rule_definition.FieldCode
                  END)
            ORDER BY CASE WHEN delta.OldValue IS NULL THEN 1 ELSE 0 END, delta.Id DESC
        ) AS actual;

        INSERT dbo.AutomationTriggerQueueRule
            (QueueSummaryId, TriggerId, RuleId, IsMatched, EvaluatedAt, ActualFromValue, ActualToValue, ExpectedValue)
        SELECT QueueSummaryId, TriggerId, RuleId, IsMatch, @Now, FromValue, ToValue, ExpectedValue
        FROM #RuleResults;

        INSERT dbo.AutomationEvaluationRules
        (
            EvaluationId, TriggerBlockId, RuleId, FieldSource, FieldCode, Operator,
            FromValue, ToValue, ExpectedValue, IsMatch, EvaluatedAt
        )
        SELECT
            EvaluationId, TriggerBlockId, RuleId, FieldSource, FieldCode, Operator,
            FromValue, ToValue, ExpectedValue, IsMatch, @Now
        FROM #RuleResults;

        -- LogicalOperator combines rules inside a block; matching any block matches the trigger.
        INSERT #BlockResults (EvaluationId, TriggerBlockId, LogicalOperator, IsMatch)
        SELECT
            evaluation.EvaluationId,
            block.Id,
            block.LogicalOperator,
            CONVERT(BIT, CASE
                WHEN COUNT(result.RuleId) = 0 THEN 1
                WHEN block.LogicalOperator = 'OR' AND MAX(CONVERT(INT, result.IsMatch)) = 1 THEN 1
                WHEN block.LogicalOperator = 'AND' AND MIN(CONVERT(INT, result.IsMatch)) = 1 THEN 1
                ELSE 0
            END)
        FROM #Evaluations AS evaluation
        INNER JOIN dbo.AutomationTriggerBlocks AS block ON block.TriggerId = evaluation.TriggerId
        LEFT JOIN #RuleResults AS result
            ON result.EvaluationId = evaluation.EvaluationId AND result.TriggerBlockId = block.Id
        GROUP BY evaluation.EvaluationId, block.Id, block.LogicalOperator;

        INSERT dbo.AutomationEvaluationBlocks
            (EvaluationId, TriggerBlockId, LogicalOperator, IsMatch, EvaluatedAt)
        SELECT EvaluationId, TriggerBlockId, LogicalOperator, IsMatch, @Now
        FROM #BlockResults;

        UPDATE evaluation
        SET IsMatch = CONVERT(BIT, CASE
            WHEN NOT EXISTS
            (
                SELECT 1 FROM dbo.AutomationTriggerBlocks AS block
                WHERE block.TriggerId = evaluation.TriggerId
            ) THEN 1
            WHEN EXISTS
            (
                SELECT 1 FROM #BlockResults AS result
                WHERE result.EvaluationId = evaluation.EvaluationId AND result.IsMatch = 1
            ) THEN 1
            ELSE 0
        END)
        FROM #Evaluations AS evaluation;

        UPDATE audit
        SET IsMatch = evaluation.IsMatch
        FROM dbo.AutomationEvaluations AS audit
        INNER JOIN #Evaluations AS evaluation ON evaluation.EvaluationId = audit.Id;

        ;WITH RankedMatches AS
        (
            SELECT
                evaluation.*,
                ROW_NUMBER() OVER
                (
                    PARTITION BY evaluation.QueueSummaryId
                    ORDER BY evaluation.SortOrder, evaluation.TriggerId
                ) AS MatchRank
            FROM #Evaluations AS evaluation
            WHERE evaluation.IsMatch = 1
        )
        INSERT #Selected
            (EvaluationId, ExecutionId, QueueSummaryId, TicketId, TriggerId, SortOrder)
        SELECT EvaluationId, NEWID(), QueueSummaryId, TicketId, TriggerId, SortOrder
        FROM RankedMatches
        WHERE ExecutionMode = 'ALL_MATCH' OR MatchRank = 1;

        UPDATE evaluation
        SET IsSelected = 1
        FROM #Evaluations AS evaluation
        INNER JOIN #Selected AS selected ON selected.EvaluationId = evaluation.EvaluationId;

        UPDATE audit
        SET IsSelected = 1
        FROM dbo.AutomationEvaluations AS audit
        INNER JOIN #Selected AS selected ON selected.EvaluationId = audit.Id;

        INSERT dbo.AutomationExecutions
        (
            Id, QueueSummaryId, TriggerId, TicketId, ParentExecutionId,
            RootExecutionId, ExecutionDepth, Status, CreatedAt
        )
        SELECT
            selected.ExecutionId,
            selected.QueueSummaryId,
            selected.TriggerId,
            selected.TicketId,
            claimed.SourceAutomationExecutionId,
            COALESCE(claimed.RootExecutionId, selected.ExecutionId),
            claimed.ExecutionDepth,
            'PENDING',
            @Now
        FROM #Selected AS selected
        INNER JOIN #Claimed AS claimed ON claimed.QueueSummaryId = selected.QueueSummaryId;

        INSERT dbo.AutomationTriggerQueueTrigger
        (
            QueueSummaryId, EvaluationId, TriggerId, AutomationExecutionId,
            SortOrder, Status, CreatedAt
        )
        SELECT
            QueueSummaryId, EvaluationId, TriggerId, ExecutionId, SortOrder, 'DISPATCHED', @Now
        FROM #Selected;

        INSERT dbo.AutomationTriggerQueueAction
        (
            Id, AutomationExecutionId, TriggerActionId, TicketId, ActionSequence,
            ActionType, ExecutionTarget, TargetField, ActionValue, Status, CreatedAt
        )
        SELECT
            NEWID(), selected.ExecutionId, action.Id, selected.TicketId, action.ActionOrder,
            action.ActionType, action.ExecutionTarget, action.TargetField, action.ActionValue,
            'READY', @Now
        FROM #Selected AS selected
        INNER JOIN dbo.AutomationTriggerActions AS action ON action.TriggerId = selected.TriggerId;

        -- A selected trigger with no actions is terminal immediately.
        UPDATE execution
        SET Status = 'COMPLETED', ExecutedAt = @Now
        FROM dbo.AutomationExecutions AS execution
        INNER JOIN #Selected AS selected ON selected.ExecutionId = execution.Id
        WHERE NOT EXISTS
        (
            SELECT 1 FROM dbo.AutomationTriggerQueueAction AS action
            WHERE action.AutomationExecutionId = execution.Id
        );

        UPDATE summary
        SET Status = 'COMPLETED',
            SkipReason = CASE
                WHEN NOT EXISTS
                (
                    SELECT 1 FROM #Evaluations AS evaluation
                    WHERE evaluation.QueueSummaryId = summary.Id AND evaluation.IsMatch = 1
                ) THEN 'NO_MATCH'
                ELSE NULL
            END,
            ProcessedAt = @Now,
            LeaseExpiresAt = NULL
        FROM dbo.AutomationTriggerQueueSummary AS summary
        INNER JOIN #Claimed AS claimed ON claimed.QueueSummaryId = summary.Id;

        -- No-match and no-action create automations can be made visible now. Action-bearing executions
        -- are finalized by the DB/application action completion procedures.
        UPDATE ticket
        SET CreateAutomationStatus = 'READY'
        FROM dbo.Tickets AS ticket
        INNER JOIN #Claimed AS claimed ON claimed.TicketId = ticket.Id
        WHERE claimed.EventType = 'TICKET_CREATED'
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.AutomationExecutions AS execution
              WHERE execution.QueueSummaryId = claimed.QueueSummaryId
                AND execution.Status NOT IN ('COMPLETED', 'PARTIAL_FAILED', 'FAILED', 'SKIPPED')
          );

        SELECT @ExecutionsCreatedCount = COUNT(*) FROM #Selected;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT @EvaluatedCount AS EvaluatedCount,
           @ExecutionsCreatedCount AS ExecutionsCreatedCount;
END;
GO
