-- =================================================================================================
-- OneDesk Automation v1.0 - Phase 2: Automation Trigger Queue Collector SP
-- =================================================================================================
USE OneDeskDb;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.ganymede_automationTriggerQueueCollectBatch
    @BatchSize INT = 100,
    @CollectedCount INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @CollectedCount = 0;

    -- Working table for candidate activity logs to process
    DECLARE @CandidateLogs TABLE
    (
        RowId INT IDENTITY(1,1) PRIMARY KEY,
        Id BIGINT NOT NULL,
        TicketId UNIQUEIDENTIFIER NOT NULL,
        Event VARCHAR(50) NOT NULL,
        ActorType VARCHAR(20) NOT NULL,
        ActorId UNIQUEIDENTIFIER NULL,
        OldValue NVARCHAR(MAX) NULL,
        NewValue NVARCHAR(MAX) NULL,
        AutomationExecutionId UNIQUEIDENTIFIER NULL,
        CreatedAt DATETIMEOFFSET NOT NULL
    );

    INSERT INTO @CandidateLogs
    (
        Id,
        TicketId,
        Event,
        ActorType,
        ActorId,
        OldValue,
        NewValue,
        AutomationExecutionId,
        CreatedAt
    )
    SELECT TOP (@BatchSize)
        tal.Id,
        tal.TicketId,
        tal.Event,
        tal.ActorType,
        tal.ActorId,
        tal.OldValue,
        tal.NewValue,
        tal.AutomationExecutionId,
        tal.CreatedAt
    FROM dbo.TicketActivityLogs tal WITH (NOLOCK)
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM dbo.AutomationTriggerQueueSource qs WITH (NOLOCK)
        WHERE qs.TicketActivityLogId = tal.Id
    )
    ORDER BY tal.Id ASC;

    DECLARE @TotalRows INT = (SELECT COUNT(*) FROM @CandidateLogs);
    DECLARE @CurrentRow INT = 1;

    WHILE @CurrentRow <= @TotalRows
    BEGIN
        DECLARE @LogId BIGINT;
        DECLARE @TicketId UNIQUEIDENTIFIER;
        DECLARE @Event VARCHAR(50);
        DECLARE @ActorType VARCHAR(20);
        DECLARE @ActorId UNIQUEIDENTIFIER;
        DECLARE @OldValue NVARCHAR(MAX);
        DECLARE @NewValue NVARCHAR(MAX);
        DECLARE @AutomationExecutionId UNIQUEIDENTIFIER;
        DECLARE @CreatedAt DATETIMEOFFSET;

        SELECT
            @LogId = Id,
            @TicketId = TicketId,
            @Event = Event,
            @ActorType = ActorType,
            @ActorId = ActorId,
            @OldValue = OldValue,
            @NewValue = NewValue,
            @AutomationExecutionId = AutomationExecutionId,
            @CreatedAt = CreatedAt
        FROM @CandidateLogs
        WHERE RowId = @CurrentRow;

        -- 1. Determine Lineage
        DECLARE @ParentExecId UNIQUEIDENTIFIER = NULL;
        DECLARE @RootExecId UNIQUEIDENTIFIER = NULL;
        DECLARE @NextDepth INT = 0;

        IF @AutomationExecutionId IS NOT NULL
        BEGIN
            SELECT TOP 1
                @ParentExecId = ae.Id,
                @RootExecId = ISNULL(ae.RootExecutionId, ae.Id),
                @NextDepth = ISNULL(ae.ExecutionDepth, 0) + 1
            FROM dbo.AutomationExecutions ae WITH (NOLOCK)
            WHERE ae.Id = @AutomationExecutionId;

            IF @RootExecId IS NULL
            BEGIN
                SET @ParentExecId = @AutomationExecutionId;
                SET @RootExecId = @AutomationExecutionId;
                SET @NextDepth = 1;
            END;
        END;

        -- 2. Resolve Business Calendar
        DECLARE @CalendarId UNIQUEIDENTIFIER = NULL;
        DECLARE @IsBusinessHour BIT = 0;
        DECLARE @IsHoliday BIT = 0;

        EXEC dbo.ganymede_businessCalendarResolve
            @BusinessCalendarId = NULL,
            @CheckTimeUtc = @CreatedAt,
            @ResolvedCalendarId = @CalendarId OUTPUT,
            @IsBusinessHour = @IsBusinessHour OUTPUT,
            @IsHoliday = @IsHoliday OUTPUT;

        -- 3. Insert Queue Summary Item
        DECLARE @QueueSummaryId BIGINT;
        DECLARE @Bucket VARCHAR(100) = 'ACTIVITY_' + @Event + '_' + CAST(@LogId AS VARCHAR(30));

        INSERT INTO dbo.AutomationTriggerQueueSummary
        (
            TicketId,
            QueueSourceType,
            CandidateTriggerId,
            EvaluationBucket,
            SourceAutomationExecutionId,
            RootExecutionId,
            ExecutionDepth,
            OccurredAt,
            BusinessCalendarId,
            IsBusinessHour,
            IsHoliday,
            Status,
            CreatedAt
        )
        VALUES
        (
            @TicketId,
            'ACTIVITY_LOG',
            NULL,
            @Bucket,
            @AutomationExecutionId,
            @RootExecId,
            @NextDepth,
            @CreatedAt,
            @CalendarId,
            @IsBusinessHour,
            @IsHoliday,
            'PENDING',
            (SYSUTCDATETIME() AT TIME ZONE 'UTC')
        );

        SET @QueueSummaryId = SCOPE_IDENTITY();

        -- 4. Map Queue Source
        INSERT INTO dbo.AutomationTriggerQueueSource
        (
            QueueSummaryId,
            TicketActivityLogId,
            CreatedAt
        )
        VALUES
        (
            @QueueSummaryId,
            @LogId,
            (SYSUTCDATETIME() AT TIME ZONE 'UTC')
        );

        -- 5. Materialize Delta Fields
        -- (a) EVENT source fields
        INSERT INTO dbo.AutomationTriggerQueueDelta
        (
            QueueSummaryId,
            FieldSource,
            FieldCode,
            OldValue,
            NewValue
        )
        VALUES
            (@QueueSummaryId, 'EVENT', 'event', NULL, @Event),
            (@QueueSummaryId, 'EVENT', 'actorType', NULL, @ActorType),
            (@QueueSummaryId, 'EVENT', 'isBusinessHour', NULL, CAST(@IsBusinessHour AS VARCHAR(1))),
            (@QueueSummaryId, 'EVENT', 'isHoliday', NULL, CAST(@IsHoliday AS VARCHAR(1)));

        -- (b) DEFAULT source fields from current Ticket state
        INSERT INTO dbo.AutomationTriggerQueueDelta
        (
            QueueSummaryId,
            FieldSource,
            FieldCode,
            OldValue,
            NewValue
        )
        SELECT
            @QueueSummaryId,
            'DEFAULT',
            prop.Code,
            NULL,
            prop.Val
        FROM dbo.Tickets t WITH (NOLOCK)
        CROSS APPLY
        (
            VALUES
                ('status', t.Status),
                ('priority', t.Priority),
                ('subject', t.Subject),
                ('source', t.Source),
                ('groupId', CAST(t.GroupId AS NVARCHAR(MAX))),
                ('assignedAgentId', CAST(t.AssignedAgentId AS NVARCHAR(MAX))),
                ('requesterContactId', CAST(t.RequesterContactId AS NVARCHAR(MAX))),
                ('requesterCompanyId', CAST(t.RequesterCompanyId AS NVARCHAR(MAX))),
                ('isBusinessHour', CAST(@IsBusinessHour AS NVARCHAR(MAX))),
                ('isHoliday', CAST(@IsHoliday AS NVARCHAR(MAX)))
        ) AS prop(Code, Val)
        WHERE t.Id = @TicketId;

        -- (c) Materialize JSON changes from NewValue and OldValue
        IF @NewValue IS NOT NULL AND ISJSON(@NewValue) = 1
        BEGIN
            INSERT INTO dbo.AutomationTriggerQueueDelta
            (
                QueueSummaryId,
                FieldSource,
                FieldCode,
                OldValue,
                NewValue
            )
            SELECT
                @QueueSummaryId,
                'DEFAULT',
                LOWER(new_prop.[key]) COLLATE DATABASE_DEFAULT,
                CASE 
                    WHEN @OldValue IS NOT NULL AND ISJSON(@OldValue) = 1 
                    THEN JSON_VALUE(@OldValue, '$.' + new_prop.[key])
                    ELSE NULL
                END,
                new_prop.[value]
            FROM OPENJSON(@NewValue) AS new_prop
            WHERE NOT EXISTS
            (
                SELECT 1 
                FROM dbo.AutomationTriggerQueueDelta
                WHERE QueueSummaryId = @QueueSummaryId
                  AND FieldSource = 'DEFAULT'
                  AND FieldCode = LOWER(new_prop.[key]) COLLATE DATABASE_DEFAULT
            );
        END;

        -- (d) CUSTOM fields from TicketFieldValues
        INSERT INTO dbo.AutomationTriggerQueueDelta
        (
            QueueSummaryId,
            FieldSource,
            FieldCode,
            OldValue,
            NewValue
        )
        SELECT
            @QueueSummaryId,
            'CUSTOM',
            tf.FieldCode,
            NULL,
            COALESCE(
                tfv.TextValue,
                CAST(tfv.NumberValue AS NVARCHAR(MAX)),
                CAST(tfv.DecimalValue AS NVARCHAR(MAX)),
                CONVERT(NVARCHAR(MAX), tfv.DateValue, 23),
                CASE WHEN tfv.BooleanValue = 1 THEN 'true' WHEN tfv.BooleanValue = 0 THEN 'false' END,
                CAST(tfv.SelectedOptionId AS NVARCHAR(MAX))
            )
        FROM dbo.TicketFieldValues tfv WITH (NOLOCK)
        INNER JOIN dbo.TicketFields tf WITH (NOLOCK)
            ON tf.Id = tfv.TicketFieldId
        WHERE tfv.TicketId = @TicketId;

        SET @CollectedCount = @CollectedCount + 1;
        SET @CurrentRow = @CurrentRow + 1;
    END;

    SELECT @CollectedCount AS CollectedCount;
END;
GO
