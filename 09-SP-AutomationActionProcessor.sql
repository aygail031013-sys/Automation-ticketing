-- =================================================================================================
-- OneDesk Automation - set-based database field-action processor
-- Claims at most one action per ticket in a batch, applies updates set-wise, writes immutable action
-- history, and emits normal TicketActivityLogs carrying cascade lineage.
-- =================================================================================================
USE OneDeskDb;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.ganymede_automationActionProcessBatch
    @BatchSize INT = 100,
    @WorkerId VARCHAR(100) = 'DB-ActionProcessor',
    @ProcessedCount INT = 0 OUTPUT,
    @SucceededCount INT = 0 OUTPUT,
    @FailedCount INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @BatchSize = CASE WHEN @BatchSize BETWEEN 1 AND 1000 THEN @BatchSize ELSE 100 END;
    SET @ProcessedCount = 0;
    SET @SucceededCount = 0;
    SET @FailedCount = 0;

    DECLARE @Now DATETIMEOFFSET = SYSUTCDATETIME() AT TIME ZONE 'UTC';
    DECLARE @LeaseSeconds INT = COALESCE
    (
        (SELECT TRY_CONVERT(INT, SettingValue) FROM dbo.AutomationSettings WHERE SettingKey = 'ActionLeaseSeconds'),
        300
    );
    DECLARE @MaxAttempts INT = COALESCE
    (
        (SELECT TRY_CONVERT(INT, SettingValue) FROM dbo.AutomationSettings WHERE SettingKey = 'ActionMaxAttempts'),
        5
    );

    CREATE TABLE #ClaimedIds (ActionId UNIQUEIDENTIFIER NOT NULL PRIMARY KEY);
    CREATE TABLE #Work
    (
        ActionId UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
        AutomationExecutionId UNIQUEIDENTIFIER NOT NULL,
        TicketId UNIQUEIDENTIFIER NOT NULL,
        ActionType VARCHAR(50) NOT NULL,
        TargetField VARCHAR(100) NULL,
        ActionValue NVARCHAR(MAX) NOT NULL,
        DesiredValue NVARCHAR(MAX) NULL,
        AttemptCount INT NOT NULL,
        ClaimedAt DATETIMEOFFSET NOT NULL
    );
    CREATE TABLE #Mutations
    (
        ActionId UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
        FieldCode VARCHAR(100) NULL,
        TicketFieldId UNIQUEIDENTIFIER NULL,
        FromValue NVARCHAR(MAX) NULL,
        ToValue NVARCHAR(MAX) NULL,
        IsSuccess BIT NOT NULL,
        ErrorMessage NVARCHAR(2000) NULL
    );

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @ClaimLockResult INT;
        EXEC @ClaimLockResult = sys.sp_getapplock
            @Resource = 'OneDesk.Automation.ActionClaim',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 5000;
        IF @ClaimLockResult < 0
            THROW 51031, 'Unable to acquire the automation action claim lock.', 1;

        ;WITH Eligible AS
        (
            SELECT
                action.Id,
                action.TicketId,
                action.CreatedAt,
                action.ActionSequence,
                ROW_NUMBER() OVER
                (
                    PARTITION BY action.TicketId
                    ORDER BY action.CreatedAt, action.AutomationExecutionId, action.ActionSequence
                ) AS TicketRank
            FROM dbo.AutomationTriggerQueueAction AS action WITH (UPDLOCK, READPAST, ROWLOCK)
            WHERE action.ExecutionTarget = 'AUTOMATION'
              AND action.AttemptCount < @MaxAttempts
              AND
              (
                  action.Status = 'READY'
                  OR (action.Status = 'PROCESSING' AND action.LeaseExpiresAt < @Now)
              )
              AND NOT EXISTS
              (
                  SELECT 1
                  FROM dbo.AutomationTriggerQueueAction AS active_claim
                  WHERE active_claim.TicketId = action.TicketId
                    AND active_claim.Id <> action.Id
                    AND active_claim.Status = 'PROCESSING'
                    AND active_claim.LeaseExpiresAt >= @Now
              )
              AND NOT EXISTS
              (
                  SELECT 1
                  FROM dbo.AutomationTriggerQueueAction AS previous
                  WHERE previous.AutomationExecutionId = action.AutomationExecutionId
                    AND previous.ActionSequence < action.ActionSequence
                    AND previous.Status IN ('READY', 'PROCESSING')
              )
        )
        INSERT #ClaimedIds (ActionId)
        SELECT TOP (@BatchSize) Id
        FROM Eligible
        WHERE TicketRank = 1
        ORDER BY CreatedAt, ActionSequence;

        UPDATE action
        SET Status = 'PROCESSING',
            AttemptCount = AttemptCount + 1,
            ClaimedBy = @WorkerId,
            ClaimedAt = @Now,
            LeaseExpiresAt = DATEADD(SECOND, @LeaseSeconds, @Now),
            LastError = NULL
        FROM dbo.AutomationTriggerQueueAction AS action
        INNER JOIN #ClaimedIds AS claimed ON claimed.ActionId = action.Id;

        INSERT #Work
        (
            ActionId, AutomationExecutionId, TicketId, ActionType, TargetField,
            ActionValue, DesiredValue, AttemptCount, ClaimedAt
        )
        SELECT
            action.Id,
            action.AutomationExecutionId,
            action.TicketId,
            UPPER(action.ActionType),
            LOWER(action.TargetField),
            action.ActionValue,
            CASE UPPER(action.ActionType)
                WHEN 'SET_STATUS' THEN JSON_VALUE(action.ActionValue, '$.status')
                WHEN 'SET_PRIORITY' THEN JSON_VALUE(action.ActionValue, '$.priority')
                WHEN 'SET_GROUP' THEN COALESCE(JSON_VALUE(action.ActionValue, '$.groupId'), JSON_VALUE(action.ActionValue, '$.value'))
                WHEN 'ASSIGN_GROUP' THEN COALESCE(JSON_VALUE(action.ActionValue, '$.groupId'), JSON_VALUE(action.ActionValue, '$.value'))
                WHEN 'SET_AGENT' THEN COALESCE(JSON_VALUE(action.ActionValue, '$.assignedAgentId'), JSON_VALUE(action.ActionValue, '$.agentId'), JSON_VALUE(action.ActionValue, '$.value'))
                WHEN 'ASSIGN_AGENT' THEN COALESCE(JSON_VALUE(action.ActionValue, '$.assignedAgentId'), JSON_VALUE(action.ActionValue, '$.agentId'), JSON_VALUE(action.ActionValue, '$.value'))
                WHEN 'SET_TYPE' THEN COALESCE(JSON_VALUE(action.ActionValue, '$.typeOptionId'), JSON_VALUE(action.ActionValue, '$.value'))
                WHEN 'SET_DUE_DATE' THEN COALESCE(JSON_VALUE(action.ActionValue, '$.dueDate'), JSON_VALUE(action.ActionValue, '$.value'))
                WHEN 'SET_CUSTOM_FIELD' THEN COALESCE(JSON_VALUE(action.ActionValue, '$.value'), JSON_VALUE(action.ActionValue, '$.fieldValue'))
                ELSE NULL
            END,
            action.AttemptCount,
            action.ClaimedAt
        FROM dbo.AutomationTriggerQueueAction AS action
        INNER JOIN #ClaimedIds AS claimed ON claimed.ActionId = action.Id;

        UPDATE execution
        SET Status = 'IN_PROGRESS'
        FROM dbo.AutomationExecutions AS execution
        WHERE EXISTS
        (
            SELECT 1 FROM #Work AS work WHERE work.AutomationExecutionId = execution.Id
        );

        UPDATE ticket
        SET Status = work.DesiredValue,
            StatusChangedAt = @Now,
            UpdatedAt = @Now,
            UpdatedBy = 'AUTOMATION'
        OUTPUT
            work.ActionId, 'status', NULL,
            CONVERT(NVARCHAR(MAX), deleted.Status), CONVERT(NVARCHAR(MAX), inserted.Status),
            CONVERT(BIT, 1), NULL
        INTO #Mutations
            (ActionId, FieldCode, TicketFieldId, FromValue, ToValue, IsSuccess, ErrorMessage)
        FROM dbo.Tickets AS ticket
        INNER JOIN #Work AS work ON work.TicketId = ticket.Id
        WHERE work.ActionType = 'SET_STATUS'
          AND work.DesiredValue IN ('OPEN', 'PENDING', 'RESOLVED', 'CLOSED', 'WAITING_FOR_COACH', 'WAITING_FOR_WLB');

        UPDATE ticket
        SET Priority = work.DesiredValue,
            UpdatedAt = @Now,
            UpdatedBy = 'AUTOMATION'
        OUTPUT
            work.ActionId, 'priority', NULL,
            CONVERT(NVARCHAR(MAX), deleted.Priority), CONVERT(NVARCHAR(MAX), inserted.Priority),
            CONVERT(BIT, 1), NULL
        INTO #Mutations
            (ActionId, FieldCode, TicketFieldId, FromValue, ToValue, IsSuccess, ErrorMessage)
        FROM dbo.Tickets AS ticket
        INNER JOIN #Work AS work ON work.TicketId = ticket.Id
        WHERE work.ActionType = 'SET_PRIORITY'
          AND work.DesiredValue IN ('LOW', 'MEDIUM', 'HIGH', 'URGENT');

        UPDATE ticket
        SET GroupId = TRY_CONVERT(UNIQUEIDENTIFIER, work.DesiredValue),
            UpdatedAt = @Now,
            UpdatedBy = 'AUTOMATION'
        OUTPUT
            work.ActionId, 'groupid', NULL,
            CONVERT(NVARCHAR(MAX), deleted.GroupId), CONVERT(NVARCHAR(MAX), inserted.GroupId),
            CONVERT(BIT, 1), NULL
        INTO #Mutations
            (ActionId, FieldCode, TicketFieldId, FromValue, ToValue, IsSuccess, ErrorMessage)
        FROM dbo.Tickets AS ticket
        INNER JOIN #Work AS work ON work.TicketId = ticket.Id
        WHERE work.ActionType IN ('SET_GROUP', 'ASSIGN_GROUP')
          AND TRY_CONVERT(UNIQUEIDENTIFIER, work.DesiredValue) IS NOT NULL;

        UPDATE ticket
        SET AssignedAgentId = TRY_CONVERT(UNIQUEIDENTIFIER, work.DesiredValue),
            UpdatedAt = @Now,
            UpdatedBy = 'AUTOMATION'
        OUTPUT
            work.ActionId, 'assignedagentid', NULL,
            CONVERT(NVARCHAR(MAX), deleted.AssignedAgentId), CONVERT(NVARCHAR(MAX), inserted.AssignedAgentId),
            CONVERT(BIT, 1), NULL
        INTO #Mutations
            (ActionId, FieldCode, TicketFieldId, FromValue, ToValue, IsSuccess, ErrorMessage)
        FROM dbo.Tickets AS ticket
        INNER JOIN #Work AS work ON work.TicketId = ticket.Id
        WHERE work.ActionType IN ('SET_AGENT', 'ASSIGN_AGENT')
          AND TRY_CONVERT(UNIQUEIDENTIFIER, work.DesiredValue) IS NOT NULL;

        UPDATE ticket
        SET TypeOptionId = TRY_CONVERT(UNIQUEIDENTIFIER, NULLIF(work.DesiredValue, '')),
            UpdatedAt = @Now,
            UpdatedBy = 'AUTOMATION'
        OUTPUT
            work.ActionId, 'typeoptionid', NULL,
            CONVERT(NVARCHAR(MAX), deleted.TypeOptionId), CONVERT(NVARCHAR(MAX), inserted.TypeOptionId),
            CONVERT(BIT, 1), NULL
        INTO #Mutations
            (ActionId, FieldCode, TicketFieldId, FromValue, ToValue, IsSuccess, ErrorMessage)
        FROM dbo.Tickets AS ticket
        INNER JOIN #Work AS work ON work.TicketId = ticket.Id
        WHERE work.ActionType = 'SET_TYPE'
          AND (NULLIF(work.DesiredValue, '') IS NULL OR TRY_CONVERT(UNIQUEIDENTIFIER, work.DesiredValue) IS NOT NULL);

        UPDATE ticket
        SET DueDate = TRY_CONVERT(DATETIMEOFFSET, NULLIF(work.DesiredValue, '')),
            UpdatedAt = @Now,
            UpdatedBy = 'AUTOMATION'
        OUTPUT
            work.ActionId, 'duedate', NULL,
            CONVERT(NVARCHAR(MAX), deleted.DueDate, 127), CONVERT(NVARCHAR(MAX), inserted.DueDate, 127),
            CONVERT(BIT, 1), NULL
        INTO #Mutations
            (ActionId, FieldCode, TicketFieldId, FromValue, ToValue, IsSuccess, ErrorMessage)
        FROM dbo.Tickets AS ticket
        INNER JOIN #Work AS work ON work.TicketId = ticket.Id
        WHERE work.ActionType = 'SET_DUE_DATE'
          AND (NULLIF(work.DesiredValue, '') IS NULL OR TRY_CONVERT(DATETIMEOFFSET, work.DesiredValue) IS NOT NULL);

        CREATE TABLE #CustomWork
        (
            ActionId UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
            TicketId UNIQUEIDENTIFIER NOT NULL,
            TicketFieldId UNIQUEIDENTIFIER NOT NULL,
            FieldCode VARCHAR(100) NOT NULL,
            SelectedOptionId UNIQUEIDENTIFIER NULL,
            TextValue NVARCHAR(MAX) NULL,
            NumberValue BIGINT NULL,
            DecimalValue DECIMAL(18,4) NULL,
            DateValue DATE NULL,
            BooleanValue BIT NULL,
            IsValid BIT NOT NULL
        );

        INSERT #CustomWork
        (
            ActionId, TicketId, TicketFieldId, FieldCode, SelectedOptionId,
            TextValue, NumberValue, DecimalValue, DateValue, BooleanValue, IsValid
        )
        SELECT
            work.ActionId, work.TicketId, field.Id, LOWER(field.FieldCode),
            CASE WHEN field.FieldType IN ('DROPDOWN', 'DEPENDENT_DROPDOWN') THEN option_value.Id END,
            CASE WHEN field.FieldType IN ('SINGLE_LINE_TEXT', 'MULTI_LINE_TEXT') THEN work.DesiredValue END,
            CASE WHEN field.FieldType = 'NUMBER' THEN TRY_CONVERT(BIGINT, work.DesiredValue) END,
            CASE WHEN field.FieldType = 'DECIMAL' THEN TRY_CONVERT(DECIMAL(18,4), work.DesiredValue) END,
            CASE WHEN field.FieldType = 'DATE' THEN TRY_CONVERT(DATE, work.DesiredValue) END,
            CASE WHEN field.FieldType = 'CHECKBOX' THEN
                CASE WHEN LOWER(work.DesiredValue) IN ('1', 'true', 'yes') THEN 1
                     WHEN LOWER(work.DesiredValue) IN ('0', 'false', 'no') THEN 0 END
            END,
            CONVERT(BIT, CASE
                WHEN field.FieldType IN ('SINGLE_LINE_TEXT', 'MULTI_LINE_TEXT') AND work.DesiredValue IS NOT NULL THEN 1
                WHEN field.FieldType = 'NUMBER' AND TRY_CONVERT(BIGINT, work.DesiredValue) IS NOT NULL THEN 1
                WHEN field.FieldType = 'DECIMAL' AND TRY_CONVERT(DECIMAL(18,4), work.DesiredValue) IS NOT NULL THEN 1
                WHEN field.FieldType = 'DATE' AND TRY_CONVERT(DATE, work.DesiredValue) IS NOT NULL THEN 1
                WHEN field.FieldType = 'CHECKBOX' AND LOWER(work.DesiredValue) IN ('0', '1', 'true', 'false', 'yes', 'no') THEN 1
                WHEN field.FieldType IN ('DROPDOWN', 'DEPENDENT_DROPDOWN') AND option_value.Id IS NOT NULL THEN 1
                ELSE 0
            END)
        FROM #Work AS work
        INNER JOIN dbo.TicketFields AS field
            ON LOWER(field.FieldCode) = LOWER(COALESCE(work.TargetField, JSON_VALUE(work.ActionValue, '$.fieldCode')))
           AND field.FieldCategory = 'CUSTOM' AND field.Active = 1
        OUTER APPLY
        (
            SELECT TOP (1) option_definition.Id
            FROM dbo.TicketFieldOptions AS option_definition
            WHERE option_definition.TicketFieldId = field.Id
              AND option_definition.Active = 1
              AND
              (
                  option_definition.Id = TRY_CONVERT(UNIQUEIDENTIFIER, work.DesiredValue)
                  OR option_definition.OptionValue = work.DesiredValue
              )
            ORDER BY option_definition.SortOrder, option_definition.Id
        ) AS option_value
        WHERE work.ActionType = 'SET_CUSTOM_FIELD';

        MERGE dbo.TicketFieldValues AS target
        USING (SELECT * FROM #CustomWork WHERE IsValid = 1) AS source
            ON target.TicketId = source.TicketId AND target.TicketFieldId = source.TicketFieldId
        WHEN MATCHED THEN UPDATE SET
            SelectedOptionId = source.SelectedOptionId,
            TextValue = source.TextValue,
            NumberValue = source.NumberValue,
            DecimalValue = source.DecimalValue,
            DateValue = source.DateValue,
            BooleanValue = source.BooleanValue,
            UpdatedBy = 'AUTOMATION',
            UpdatedAt = @Now
        WHEN NOT MATCHED THEN INSERT
        (
            Id, TicketId, TicketFieldId, SelectedOptionId, TextValue, NumberValue,
            DecimalValue, DateValue, BooleanValue, CreatedBy, CreatedAt, UpdatedBy, UpdatedAt
        )
        VALUES
        (
            NEWID(), source.TicketId, source.TicketFieldId, source.SelectedOptionId,
            source.TextValue, source.NumberValue, source.DecimalValue, source.DateValue,
            source.BooleanValue, 'AUTOMATION', @Now, 'AUTOMATION', @Now
        )
        OUTPUT
            source.ActionId, source.FieldCode, source.TicketFieldId,
            COALESCE(CONVERT(NVARCHAR(MAX), deleted.SelectedOptionId), deleted.TextValue,
                     CONVERT(NVARCHAR(MAX), deleted.NumberValue), CONVERT(NVARCHAR(MAX), deleted.DecimalValue),
                     CONVERT(NVARCHAR(MAX), deleted.DateValue, 23), CONVERT(NVARCHAR(MAX), deleted.BooleanValue)),
            COALESCE(CONVERT(NVARCHAR(MAX), inserted.SelectedOptionId), inserted.TextValue,
                     CONVERT(NVARCHAR(MAX), inserted.NumberValue), CONVERT(NVARCHAR(MAX), inserted.DecimalValue),
                     CONVERT(NVARCHAR(MAX), inserted.DateValue, 23), CONVERT(NVARCHAR(MAX), inserted.BooleanValue)),
            CONVERT(BIT, 1), NULL
        INTO #Mutations
            (ActionId, FieldCode, TicketFieldId, FromValue, ToValue, IsSuccess, ErrorMessage);

        -- Every claimed row must receive a terminal result. Rows absent from #Mutations failed
        -- validation or named an unsupported database action.
        INSERT #Mutations
            (ActionId, FieldCode, TicketFieldId, FromValue, ToValue, IsSuccess, ErrorMessage)
        SELECT
            work.ActionId,
            COALESCE(work.TargetField, LOWER(work.ActionType)),
            NULL,
            NULL,
            work.DesiredValue,
            0,
            CASE
                WHEN work.ActionType NOT IN
                    ('SET_STATUS', 'SET_PRIORITY', 'SET_GROUP', 'ASSIGN_GROUP', 'SET_AGENT', 'ASSIGN_AGENT', 'SET_TYPE', 'SET_DUE_DATE', 'SET_CUSTOM_FIELD')
                    THEN 'UNSUPPORTED_AUTOMATION_ACTION'
                ELSE 'INVALID_ACTION_VALUE_OR_TARGET'
            END
        FROM #Work AS work
        WHERE NOT EXISTS (SELECT 1 FROM #Mutations AS mutation WHERE mutation.ActionId = work.ActionId);

        UPDATE ticket
        SET UpdatedAt = @Now,
            UpdatedBy = 'AUTOMATION'
        FROM dbo.Tickets AS ticket
        WHERE EXISTS
        (
            SELECT 1
            FROM #Mutations AS mutation
            INNER JOIN #Work AS work ON work.ActionId = mutation.ActionId
            WHERE work.TicketId = ticket.Id AND mutation.IsSuccess = 1
        );

        UPDATE action
        SET Status = CASE WHEN mutation.IsSuccess = 1 THEN 'SUCCEEDED' ELSE 'FAILED' END,
            CompletedAt = @Now,
            LeaseExpiresAt = NULL,
            LastError = mutation.ErrorMessage
        FROM dbo.AutomationTriggerQueueAction AS action
        INNER JOIN #Mutations AS mutation ON mutation.ActionId = action.Id;

        INSERT dbo.AutomationActionHistories
        (
            QueueActionId, AutomationExecutionId, TicketId, AttemptNumber,
            ActionType, ExecutionTarget, TargetField, ConfiguredValue, ResolvedValue,
            FromValue, ToValue, Status, WorkerId, ErrorMessage, StartedAt, CompletedAt
        )
        SELECT
            action.Id, action.AutomationExecutionId, action.TicketId, action.AttemptCount,
            action.ActionType, action.ExecutionTarget, action.TargetField, action.ActionValue, NULL,
            mutation.FromValue, mutation.ToValue,
            CASE WHEN mutation.IsSuccess = 1 THEN 'SUCCEEDED' ELSE 'FAILED' END,
            action.ClaimedBy, mutation.ErrorMessage, action.ClaimedAt, @Now
        FROM dbo.AutomationTriggerQueueAction AS action
        INNER JOIN #Mutations AS mutation ON mutation.ActionId = action.Id;

        -- Successful field mutations re-enter automation only through normal, lineage-bearing events.
        INSERT dbo.TicketActivityLogs
        (
            TicketId, Event, ActorType, ActorId, TicketFieldId, OldValue, NewValue,
            Description, PlainDescription, AutomationExecutionId, OperationId, CreatedAt
        )
        SELECT
            action.TicketId,
            'TICKET_UPDATED',
            'SYSTEM',
            NULL,
            mutation.TicketFieldId,
            N'{"' + STRING_ESCAPE(mutation.FieldCode, 'json') + N'":'
                + CASE WHEN mutation.FromValue IS NULL THEN N'null' ELSE N'"' + STRING_ESCAPE(mutation.FromValue, 'json') + N'"' END + N'}',
            N'{"' + STRING_ESCAPE(mutation.FieldCode, 'json') + N'":'
                + CASE WHEN mutation.ToValue IS NULL THEN N'null' ELSE N'"' + STRING_ESCAPE(mutation.ToValue, 'json') + N'"' END + N'}',
            N'Automation updated ' + mutation.FieldCode,
            N'Automation updated ' + mutation.FieldCode,
            action.AutomationExecutionId,
            NEWID(),
            @Now
        FROM #Mutations AS mutation
        INNER JOIN dbo.AutomationTriggerQueueAction AS action ON action.Id = mutation.ActionId
        WHERE mutation.IsSuccess = 1
          AND COALESCE(mutation.FromValue, '') <> COALESCE(mutation.ToValue, '');

        ;WITH AffectedExecutions AS
        (
            SELECT DISTINCT work.AutomationExecutionId FROM #Work AS work
        ),
        AggregateStatus AS
        (
            SELECT
                affected.AutomationExecutionId,
                COUNT(action.Id) AS TotalActions,
                SUM(CASE WHEN action.Status IN ('READY', 'PROCESSING') THEN 1 ELSE 0 END) AS OpenActions,
                SUM(CASE WHEN action.Status = 'FAILED' THEN 1 ELSE 0 END) AS FailedActions
            FROM AffectedExecutions AS affected
            INNER JOIN dbo.AutomationTriggerQueueAction AS action
                ON action.AutomationExecutionId = affected.AutomationExecutionId
            GROUP BY affected.AutomationExecutionId
        )
        UPDATE execution
        SET Status = CASE
                WHEN aggregate.OpenActions > 0 THEN 'IN_PROGRESS'
                WHEN aggregate.FailedActions = aggregate.TotalActions THEN 'FAILED'
                WHEN aggregate.FailedActions > 0 THEN 'PARTIAL_FAILED'
                ELSE 'COMPLETED'
            END,
            ExecutedAt = CASE WHEN aggregate.OpenActions = 0 THEN @Now ELSE NULL END
        FROM dbo.AutomationExecutions AS execution
        INNER JOIN AggregateStatus AS aggregate ON aggregate.AutomationExecutionId = execution.Id;

        UPDATE ticket
        SET CreateAutomationStatus = 'READY'
        FROM dbo.Tickets AS ticket
        WHERE EXISTS
        (
            SELECT 1
            FROM #Work AS work
            INNER JOIN dbo.AutomationExecutions AS execution ON execution.Id = work.AutomationExecutionId
            INNER JOIN dbo.AutomationTriggerQueueSummary AS origin ON origin.Id = execution.QueueSummaryId
            WHERE work.TicketId = ticket.Id
              AND origin.EventType = 'TICKET_CREATED'
              AND execution.ParentExecutionId IS NULL
        )
        AND NOT EXISTS
        (
            SELECT 1
            FROM dbo.AutomationExecutions AS direct_execution
            INNER JOIN dbo.AutomationTriggerQueueSummary AS direct_origin
                ON direct_origin.Id = direct_execution.QueueSummaryId
            WHERE direct_execution.TicketId = ticket.Id
              AND direct_origin.EventType = 'TICKET_CREATED'
              AND direct_execution.ParentExecutionId IS NULL
              AND direct_execution.Status NOT IN ('COMPLETED', 'PARTIAL_FAILED', 'FAILED', 'SKIPPED')
        );

        SELECT
            @ProcessedCount = COUNT(*),
            @SucceededCount = COALESCE(SUM(CASE WHEN IsSuccess = 1 THEN 1 ELSE 0 END), 0),
            @FailedCount = COALESCE(SUM(CASE WHEN IsSuccess = 0 THEN 1 ELSE 0 END), 0)
        FROM #Mutations;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT @ProcessedCount AS ProcessedCount,
           @SucceededCount AS SucceededCount,
           @FailedCount AS FailedCount;
END;
GO
