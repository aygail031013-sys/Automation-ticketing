-- =================================================================================================
-- OneDesk Automation - set-based activity collector
-- One queue summary is created per Ticket + business OperationId. Older rows without OperationId
-- are intentionally treated as one operation per activity row.
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
    SET XACT_ABORT ON;

    SET @BatchSize = CASE WHEN @BatchSize BETWEEN 1 AND 2000 THEN @BatchSize ELSE 100 END;
    SET @CollectedCount = 0;

    CREATE TABLE #CandidateOperations
    (
        OperationKey VARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
        FirstActivityLogId BIGINT NOT NULL
    );
    CREATE TABLE #CandidateLogs
    (
        Id BIGINT NOT NULL PRIMARY KEY,
        OperationKey VARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        OperationId UNIQUEIDENTIFIER NULL,
        TicketId UNIQUEIDENTIFIER NOT NULL,
        EventType VARCHAR(50) COLLATE DATABASE_DEFAULT NOT NULL,
        ActorType VARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL,
        OldValue NVARCHAR(MAX) NULL,
        NewValue NVARCHAR(MAX) NULL,
        AutomationExecutionId UNIQUEIDENTIFIER NULL,
        OccurredAt DATETIMEOFFSET NOT NULL
    );
    CREATE TABLE #SummaryMap
    (
        OperationKey VARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
        QueueSummaryId BIGINT NOT NULL UNIQUE
    );

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @LockResult INT;
        EXEC @LockResult = sys.sp_getapplock
            @Resource = 'OneDesk.Automation.ActivityCollector',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 0;

        IF @LockResult < 0
        BEGIN
            COMMIT TRANSACTION;
            SELECT @CollectedCount AS CollectedCount;
            RETURN;
        END;

        INSERT #CandidateOperations (OperationKey, FirstActivityLogId)
        SELECT TOP (@BatchSize)
            CASE WHEN tal.OperationId IS NOT NULL
                THEN 'OP:' + CONVERT(VARCHAR(36), tal.OperationId)
                ELSE 'LOG:' + CONVERT(VARCHAR(30), tal.Id)
            END,
            MIN(tal.Id)
        FROM dbo.TicketActivityLogs AS tal
        WHERE NOT EXISTS
        (
            SELECT 1 FROM dbo.AutomationTriggerQueueSource AS src
            WHERE src.TicketActivityLogId = tal.Id
        )
        GROUP BY CASE WHEN tal.OperationId IS NOT NULL
            THEN 'OP:' + CONVERT(VARCHAR(36), tal.OperationId)
            ELSE 'LOG:' + CONVERT(VARCHAR(30), tal.Id)
        END
        ORDER BY MIN(tal.Id);

        INSERT #CandidateLogs
        (
            Id, OperationKey, OperationId, TicketId, EventType, ActorType, OldValue, NewValue,
            AutomationExecutionId, OccurredAt
        )
        SELECT
            tal.Id,
            CASE WHEN tal.OperationId IS NOT NULL
                THEN 'OP:' + CONVERT(VARCHAR(36), tal.OperationId)
                ELSE 'LOG:' + CONVERT(VARCHAR(30), tal.Id)
            END,
            tal.OperationId, tal.TicketId, tal.Event, tal.ActorType, tal.OldValue, tal.NewValue,
            tal.AutomationExecutionId, tal.CreatedAt
        FROM dbo.TicketActivityLogs AS tal
        INNER JOIN #CandidateOperations AS candidate
            ON candidate.OperationKey = CASE WHEN tal.OperationId IS NOT NULL
                THEN 'OP:' + CONVERT(VARCHAR(36), tal.OperationId)
                ELSE 'LOG:' + CONVERT(VARCHAR(30), tal.Id)
            END
        WHERE NOT EXISTS
        (
            SELECT 1 FROM dbo.AutomationTriggerQueueSource AS src
            WHERE src.TicketActivityLogId = tal.Id
        );

        DECLARE @CalendarId UNIQUEIDENTIFIER = NULL;
        DECLARE @Timezone SYSNAME = 'UTC';
        SELECT TOP (1)
            @CalendarId = c.Id,
            @Timezone = CASE WHEN zone.name IS NULL THEN 'UTC' ELSE c.Timezone END
        FROM dbo.BusinessCalendars AS c
        LEFT JOIN sys.time_zone_info AS zone ON zone.name = c.Timezone
        WHERE c.IsActive = 1
        ORDER BY c.IsDefault DESC, c.CreatedAt, c.Id;

        ;WITH Operations AS
        (
            SELECT
                candidate.OperationKey,
                primary_log.OperationId,
                primary_log.TicketId,
                primary_log.AutomationExecutionId AS SourceExecutionId,
                timing.OccurredAt,
                primary_log.EventType
            FROM #CandidateOperations AS candidate
            CROSS APPLY
            (
                SELECT TOP (1)
                    p.OperationId, p.TicketId, p.AutomationExecutionId, p.EventType
                FROM #CandidateLogs AS p
                WHERE p.OperationKey = candidate.OperationKey
                ORDER BY p.Id
            ) AS primary_log
            CROSS APPLY
            (
                SELECT MIN(p.OccurredAt) AS OccurredAt
                FROM #CandidateLogs AS p
                WHERE p.OperationKey = candidate.OperationKey
            ) AS timing
        ),
        Context AS
        (
            SELECT
                o.*,
                CAST(o.OccurredAt AT TIME ZONE @Timezone AS DATE) AS LocalDate,
                CAST(o.OccurredAt AT TIME ZONE @Timezone AS TIME(0)) AS LocalTime,
                CONVERT(TINYINT, ((DATEPART(WEEKDAY,
                    CAST(o.OccurredAt AT TIME ZONE @Timezone AS DATE)) + @@DATEFIRST - 2) % 7) + 1)
                    AS LocalDayOfWeek
            FROM Operations AS o
        ),
        QueueRows AS
        (
            SELECT
                c.OperationKey, c.OperationId, c.TicketId, c.EventType, c.SourceExecutionId,
                CASE WHEN parent.Id IS NULL THEN NULL ELSE COALESCE(parent.RootExecutionId, parent.Id) END AS RootExecutionId,
                CASE WHEN c.SourceExecutionId IS NULL THEN 0 ELSE COALESCE(parent.ExecutionDepth, 0) + 1 END AS ExecutionDepth,
                c.OccurredAt,
                @CalendarId AS BusinessCalendarId,
                CONVERT(BIT, CASE
                    WHEN @CalendarId IS NULL THEN 1
                    WHEN holiday.Id IS NULL AND schedule.Id IS NOT NULL THEN 1
                    ELSE 0
                END) AS IsBusinessHour,
                CONVERT(BIT, CASE WHEN holiday.Id IS NULL THEN 0 ELSE 1 END) AS IsHoliday
            FROM Context AS c
            LEFT JOIN dbo.AutomationExecutions AS parent ON parent.Id = c.SourceExecutionId
            OUTER APPLY
            (
                SELECT TOP (1) h.Id FROM dbo.BusinessCalendarHolidays AS h
                WHERE h.CalendarId = @CalendarId AND h.HolidayDate = c.LocalDate
            ) AS holiday
            OUTER APPLY
            (
                SELECT TOP (1) s.Id FROM dbo.BusinessCalendarSchedules AS s
                WHERE s.CalendarId = @CalendarId
                  AND s.DayOfWeek = c.LocalDayOfWeek AND s.IsWorkingDay = 1
                  AND c.LocalTime >= s.StartTime AND c.LocalTime < s.EndTime
            ) AS schedule
        )
        MERGE dbo.AutomationTriggerQueueSummary AS target
        USING QueueRows AS source ON 1 = 0
        WHEN NOT MATCHED THEN
            INSERT
            (
                TicketId, QueueSourceType, CandidateTriggerId, EvaluationBucket, EventType,
                OperationId, SourceAutomationExecutionId, RootExecutionId, ExecutionDepth,
                OccurredAt, BusinessCalendarId, IsBusinessHour, IsHoliday, Status, CreatedAt
            )
            VALUES
            (
                source.TicketId, 'ACTIVITY_LOG', NULL,
                'ACTIVITY_' + source.EventType + '_' + source.OperationKey,
                source.EventType, source.OperationId, source.SourceExecutionId, source.RootExecutionId,
                source.ExecutionDepth, source.OccurredAt, source.BusinessCalendarId,
                source.IsBusinessHour, source.IsHoliday, 'PENDING',
                (SYSUTCDATETIME() AT TIME ZONE 'UTC')
            )
        OUTPUT source.OperationKey, inserted.Id INTO #SummaryMap (OperationKey, QueueSummaryId);

        INSERT dbo.AutomationTriggerQueueSource (QueueSummaryId, TicketActivityLogId, CreatedAt)
        SELECT map.QueueSummaryId, logs.Id, (SYSUTCDATETIME() AT TIME ZONE 'UTC')
        FROM #CandidateLogs AS logs
        INNER JOIN #SummaryMap AS map ON map.OperationKey = logs.OperationKey;

        INSERT dbo.AutomationTriggerQueueDelta
            (QueueSummaryId, FieldSource, FieldCode, OldValue, NewValue)
        SELECT map.QueueSummaryId, 'EVENT', valueset.FieldCode, NULL, valueset.FieldValue
        FROM #SummaryMap AS map
        INNER JOIN dbo.AutomationTriggerQueueSummary AS summary ON summary.Id = map.QueueSummaryId
        CROSS APPLY
        (
            VALUES
                ('event', CONVERT(NVARCHAR(MAX), summary.EventType)),
                ('isbusinesshour', CONVERT(NVARCHAR(MAX), summary.IsBusinessHour)),
                ('isholiday', CONVERT(NVARCHAR(MAX), summary.IsHoliday)),
                ('operationid', CONVERT(NVARCHAR(MAX), summary.OperationId))
        ) AS valueset(FieldCode, FieldValue);

        INSERT dbo.AutomationTriggerQueueDelta
            (QueueSummaryId, FieldSource, FieldCode, OldValue, NewValue)
        SELECT map.QueueSummaryId, 'EVENT', 'actortype', NULL, primary_log.ActorType
        FROM #SummaryMap AS map
        CROSS APPLY
        (
            SELECT TOP (1) logs.ActorType
            FROM #CandidateLogs AS logs
            WHERE logs.OperationKey = map.OperationKey
            ORDER BY logs.Id
        ) AS primary_log;

        CREATE TABLE #ChangedCodes
        (
            QueueSummaryId BIGINT NOT NULL,
            OperationKey VARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
            FieldCode VARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
            PRIMARY KEY (QueueSummaryId, FieldCode)
        );

        INSERT #ChangedCodes (QueueSummaryId, OperationKey, FieldCode)
        SELECT DISTINCT map.QueueSummaryId, logs.OperationKey, LOWER(json_key.[key])
        FROM #CandidateLogs AS logs
        INNER JOIN #SummaryMap AS map ON map.OperationKey = logs.OperationKey
        CROSS APPLY
        (
            SELECT [key] COLLATE DATABASE_DEFAULT AS [key] FROM OPENJSON(logs.OldValue)
            UNION
            SELECT [key] COLLATE DATABASE_DEFAULT AS [key] FROM OPENJSON(logs.NewValue)
        ) AS json_key
        WHERE LEN(json_key.[key]) <= 100;

        INSERT dbo.AutomationTriggerQueueDelta
            (QueueSummaryId, FieldSource, FieldCode, OldValue, NewValue)
        SELECT
            changed.QueueSummaryId,
            CASE WHEN field.FieldCategory = 'CUSTOM' THEN 'CUSTOM' ELSE 'DEFAULT' END,
            changed.FieldCode,
            old_value.Value,
            new_value.Value
        FROM #ChangedCodes AS changed
        LEFT JOIN dbo.TicketFields AS field ON LOWER(field.FieldCode) = changed.FieldCode
        OUTER APPLY
        (
            SELECT TOP (1) old_json.[value] AS Value
            FROM #CandidateLogs AS logs
            CROSS APPLY OPENJSON(logs.OldValue) AS old_json
            WHERE logs.OperationKey = changed.OperationKey
              AND LOWER(old_json.[key]) COLLATE DATABASE_DEFAULT = changed.FieldCode
            ORDER BY logs.Id
        ) AS old_value
        OUTER APPLY
        (
            SELECT TOP (1) new_json.[value] AS Value
            FROM #CandidateLogs AS logs
            CROSS APPLY OPENJSON(logs.NewValue) AS new_json
            WHERE logs.OperationKey = changed.OperationKey
              AND LOWER(new_json.[key]) COLLATE DATABASE_DEFAULT = changed.FieldCode
            ORDER BY logs.Id DESC
        ) AS new_value;

        INSERT dbo.AutomationTriggerQueueDelta
            (QueueSummaryId, FieldSource, FieldCode, OldValue, NewValue)
        SELECT map.QueueSummaryId, 'DEFAULT', snapshot.FieldCode, NULL, snapshot.FieldValue
        FROM #SummaryMap AS map
        INNER JOIN dbo.AutomationTriggerQueueSummary AS summary ON summary.Id = map.QueueSummaryId
        INNER JOIN dbo.Tickets AS ticket ON ticket.Id = summary.TicketId
        CROSS APPLY
        (
            VALUES
                ('status', CONVERT(NVARCHAR(MAX), ticket.Status)),
                ('priority', CONVERT(NVARCHAR(MAX), ticket.Priority)),
                ('subject', CONVERT(NVARCHAR(MAX), ticket.Subject)),
                ('source', CONVERT(NVARCHAR(MAX), ticket.Source)),
                ('groupid', CONVERT(NVARCHAR(MAX), ticket.GroupId)),
                ('assignedagentid', CONVERT(NVARCHAR(MAX), ticket.AssignedAgentId)),
                ('requestercontactid', CONVERT(NVARCHAR(MAX), ticket.RequesterContactId)),
                ('requestercompanyid', CONVERT(NVARCHAR(MAX), ticket.RequesterCompanyId)),
                ('typeoptionid', CONVERT(NVARCHAR(MAX), ticket.TypeOptionId)),
                ('duedate', CONVERT(NVARCHAR(MAX), ticket.DueDate, 127)),
                ('isbusinesshour', CONVERT(NVARCHAR(MAX), summary.IsBusinessHour)),
                ('isholiday', CONVERT(NVARCHAR(MAX), summary.IsHoliday))
        ) AS snapshot(FieldCode, FieldValue)
        WHERE NOT EXISTS
        (
            SELECT 1 FROM dbo.AutomationTriggerQueueDelta AS existing
            WHERE existing.QueueSummaryId = map.QueueSummaryId
              AND existing.FieldSource = 'DEFAULT'
              AND LOWER(existing.FieldCode) = snapshot.FieldCode
        );

        INSERT dbo.AutomationTriggerQueueDelta
            (QueueSummaryId, FieldSource, FieldCode, OldValue, NewValue)
        SELECT
            map.QueueSummaryId, 'CUSTOM', LOWER(field.FieldCode), NULL,
            COALESCE
            (
                value.TextValue, CONVERT(NVARCHAR(MAX), value.NumberValue),
                CONVERT(NVARCHAR(MAX), value.DecimalValue), CONVERT(NVARCHAR(MAX), value.DateValue, 23),
                CASE WHEN value.BooleanValue = 1 THEN 'true' WHEN value.BooleanValue = 0 THEN 'false' END,
                CONVERT(NVARCHAR(MAX), value.SelectedOptionId)
            )
        FROM #SummaryMap AS map
        INNER JOIN dbo.AutomationTriggerQueueSummary AS summary ON summary.Id = map.QueueSummaryId
        INNER JOIN dbo.TicketFieldValues AS value ON value.TicketId = summary.TicketId
        INNER JOIN dbo.TicketFields AS field ON field.Id = value.TicketFieldId
        WHERE NOT EXISTS
        (
            SELECT 1 FROM dbo.AutomationTriggerQueueDelta AS existing
            WHERE existing.QueueSummaryId = map.QueueSummaryId
              AND existing.FieldSource = 'CUSTOM'
              AND LOWER(existing.FieldCode) = LOWER(field.FieldCode)
        );

        SELECT @CollectedCount = COUNT(*) FROM #SummaryMap;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT @CollectedCount AS CollectedCount;
END;
GO
