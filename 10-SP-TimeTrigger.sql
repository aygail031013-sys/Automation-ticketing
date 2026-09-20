-- =================================================================================================
-- OneDesk Automation - set-based time-trigger producer
-- Time triggers enter the normal summary/delta pipeline and never create fake TicketActivityLogs.
-- =================================================================================================
USE OneDeskDb;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.ganymede_automationTimeTriggerScanBatch
    @EvaluationBucket VARCHAR(100) = NULL,
    @BatchSize INT = 200,
    @QueuedCount INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @BatchSize = CASE WHEN @BatchSize BETWEEN 1 AND 5000 THEN @BatchSize ELSE 200 END;
    SET @QueuedCount = 0;

    DECLARE @Now DATETIMEOFFSET = SYSUTCDATETIME() AT TIME ZONE 'UTC';
    IF NULLIF(LTRIM(RTRIM(@EvaluationBucket)), '') IS NULL
    BEGIN
        SET @EvaluationBucket = 'TT_' + CONVERT(CHAR(8), @Now, 112) + '_'
            + RIGHT('0' + CONVERT(VARCHAR(2), DATEPART(HOUR, @Now)), 2);
    END;

    CREATE TABLE #Candidates
    (
        TriggerId UNIQUEIDENTIFIER NOT NULL,
        TicketId UNIQUEIDENTIFIER NOT NULL,
        BusinessCalendarId UNIQUEIDENTIFIER NULL,
        IsBusinessHour BIT NOT NULL,
        IsHoliday BIT NOT NULL,
        PRIMARY KEY (TriggerId, TicketId)
    );
    CREATE TABLE #Queued
    (
        QueueSummaryId BIGINT NOT NULL PRIMARY KEY,
        TriggerId UNIQUEIDENTIFIER NOT NULL,
        TicketId UNIQUEIDENTIFIER NOT NULL
    );

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @LockResult INT;
        DECLARE @LockResource NVARCHAR(255) = N'OneDesk.Automation.TimeScanner.' + @EvaluationBucket;
        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource,
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 0;

        IF @LockResult < 0
        BEGIN
            COMMIT TRANSACTION;
            SELECT @QueuedCount AS QueuedCount;
            RETURN;
        END;

        ;WITH Prefiltered AS
        (
            SELECT TOP (@BatchSize)
                trigger_definition.Id AS TriggerId,
                ticket.Id AS TicketId,
                calendar.Id AS BusinessCalendarId,
                ticket.UpdatedAt,
                trigger_definition.Priority,
                local_context.LocalDate,
                local_context.LocalTime,
                local_context.LocalDayOfWeek
            FROM dbo.AutomationTriggers AS trigger_definition
            INNER JOIN dbo.Tickets AS ticket ON ticket.IsDeleted = 0
            OUTER APPLY
            (
                SELECT TOP (1) selected_calendar.Id, selected_calendar.Timezone
                FROM dbo.BusinessCalendars AS selected_calendar
                WHERE selected_calendar.IsActive = 1
                ORDER BY
                    CASE WHEN selected_calendar.Id = trigger_definition.BusinessCalendarId THEN 0 ELSE 1 END,
                    selected_calendar.IsDefault DESC,
                    selected_calendar.CreatedAt,
                    selected_calendar.Id
            ) AS calendar
            OUTER APPLY
            (
                SELECT CASE WHEN zone.name IS NULL THEN 'UTC' ELSE calendar.Timezone END AS TimezoneName
                FROM (VALUES (1)) AS singleton(Value)
                LEFT JOIN sys.time_zone_info AS zone ON zone.name = calendar.Timezone
            ) AS timezone_resolution
            CROSS APPLY
            (
                SELECT
                    CAST(@Now AT TIME ZONE COALESCE(timezone_resolution.TimezoneName, 'UTC') AS DATE) AS LocalDate,
                    CAST(@Now AT TIME ZONE COALESCE(timezone_resolution.TimezoneName, 'UTC') AS TIME(0)) AS LocalTime,
                    CONVERT(TINYINT, ((DATEPART(WEEKDAY,
                        CAST(@Now AT TIME ZONE COALESCE(timezone_resolution.TimezoneName, 'UTC') AS DATE))
                        + @@DATEFIRST - 2) % 7) + 1) AS LocalDayOfWeek
            ) AS local_context
            WHERE trigger_definition.EventType IN ('TIME_TRIGGER', 'SCHEDULE_DUE')
              AND trigger_definition.IsActive = 1
              AND NOT EXISTS
              (
                  SELECT 1
                  FROM dbo.AutomationTriggerQueueSummary AS existing
                  WHERE existing.TicketId = ticket.Id
                    AND existing.CandidateTriggerId = trigger_definition.Id
                    AND existing.EvaluationBucket = @EvaluationBucket
                    AND existing.QueueSourceType = 'TIME_TRIGGER'
              )
              -- Cheap, sargable configuration-derived prefilters. The full evaluator remains the
              -- authority; these predicates only remove obvious non-candidates.
              AND
              (
                  NOT EXISTS
                  (
                      SELECT 1
                      FROM dbo.AutomationTriggerBlocks AS block
                      INNER JOIN dbo.AutomationTriggerRules AS rule_definition ON rule_definition.TriggerBlockId = block.Id
                      WHERE block.TriggerId = trigger_definition.Id
                        AND rule_definition.FieldSource = 'DEFAULT' AND LOWER(rule_definition.FieldCode) = 'status'
                        AND UPPER(rule_definition.Operator) IN ('EQUALS', '=')
                  )
                  OR ticket.Status IN
                  (
                      SELECT rule_definition.Value
                      FROM dbo.AutomationTriggerBlocks AS block
                      INNER JOIN dbo.AutomationTriggerRules AS rule_definition ON rule_definition.TriggerBlockId = block.Id
                      WHERE block.TriggerId = trigger_definition.Id
                        AND rule_definition.FieldSource = 'DEFAULT' AND LOWER(rule_definition.FieldCode) = 'status'
                        AND UPPER(rule_definition.Operator) IN ('EQUALS', '=')
                  )
              )
              AND
              (
                  NOT EXISTS
                  (
                      SELECT 1
                      FROM dbo.AutomationTriggerBlocks AS block
                      INNER JOIN dbo.AutomationTriggerRules AS rule_definition ON rule_definition.TriggerBlockId = block.Id
                      WHERE block.TriggerId = trigger_definition.Id
                        AND rule_definition.FieldSource = 'DEFAULT' AND LOWER(rule_definition.FieldCode) = 'priority'
                        AND UPPER(rule_definition.Operator) IN ('EQUALS', '=')
                  )
                  OR ticket.Priority IN
                  (
                      SELECT rule_definition.Value
                      FROM dbo.AutomationTriggerBlocks AS block
                      INNER JOIN dbo.AutomationTriggerRules AS rule_definition ON rule_definition.TriggerBlockId = block.Id
                      WHERE block.TriggerId = trigger_definition.Id
                        AND rule_definition.FieldSource = 'DEFAULT' AND LOWER(rule_definition.FieldCode) = 'priority'
                        AND UPPER(rule_definition.Operator) IN ('EQUALS', '=')
                  )
              )
            ORDER BY trigger_definition.Priority, ticket.UpdatedAt, ticket.Id
        )
        INSERT #Candidates (TriggerId, TicketId, BusinessCalendarId, IsBusinessHour, IsHoliday)
        SELECT
            prefilter.TriggerId,
            prefilter.TicketId,
            prefilter.BusinessCalendarId,
            CONVERT(BIT, CASE
                WHEN prefilter.BusinessCalendarId IS NULL THEN 1
                WHEN holiday.Id IS NULL AND schedule.Id IS NOT NULL THEN 1
                ELSE 0
            END),
            CONVERT(BIT, CASE WHEN holiday.Id IS NULL THEN 0 ELSE 1 END)
        FROM Prefiltered AS prefilter
        OUTER APPLY
        (
            SELECT TOP (1) h.Id
            FROM dbo.BusinessCalendarHolidays AS h
            WHERE h.CalendarId = prefilter.BusinessCalendarId
              AND h.HolidayDate = prefilter.LocalDate
        ) AS holiday
        OUTER APPLY
        (
            SELECT TOP (1) s.Id
            FROM dbo.BusinessCalendarSchedules AS s
            WHERE s.CalendarId = prefilter.BusinessCalendarId
              AND s.DayOfWeek = prefilter.LocalDayOfWeek
              AND s.IsWorkingDay = 1
              AND prefilter.LocalTime >= s.StartTime
              AND prefilter.LocalTime < s.EndTime
        ) AS schedule;

        MERGE dbo.AutomationTriggerQueueSummary AS target
        USING #Candidates AS source ON 1 = 0
        WHEN NOT MATCHED THEN INSERT
        (
            TicketId, QueueSourceType, CandidateTriggerId, EvaluationBucket, EventType,
            OperationId, SourceAutomationExecutionId, RootExecutionId, ExecutionDepth,
            OccurredAt, BusinessCalendarId, IsBusinessHour, IsHoliday, Status, CreatedAt
        )
        VALUES
        (
            source.TicketId, 'TIME_TRIGGER', source.TriggerId, @EvaluationBucket, 'TIME_TRIGGER',
            NULL, NULL, NULL, 0, @Now, source.BusinessCalendarId,
            source.IsBusinessHour, source.IsHoliday, 'PENDING', @Now
        )
        OUTPUT inserted.Id, source.TriggerId, source.TicketId
            INTO #Queued (QueueSummaryId, TriggerId, TicketId);

        INSERT dbo.AutomationTriggerQueueDelta
            (QueueSummaryId, FieldSource, FieldCode, OldValue, NewValue)
        SELECT queued.QueueSummaryId, 'EVENT', context.FieldCode, NULL, context.FieldValue
        FROM #Queued AS queued
        INNER JOIN #Candidates AS candidate
            ON candidate.TriggerId = queued.TriggerId AND candidate.TicketId = queued.TicketId
        CROSS APPLY
        (
            VALUES
                ('event', CONVERT(NVARCHAR(MAX), 'TIME_TRIGGER')),
                ('isbusinesshour', CONVERT(NVARCHAR(MAX), candidate.IsBusinessHour)),
                ('isholiday', CONVERT(NVARCHAR(MAX), candidate.IsHoliday)),
                ('evaluationbucket', CONVERT(NVARCHAR(MAX), @EvaluationBucket))
        ) AS context(FieldCode, FieldValue);

        INSERT dbo.AutomationTriggerQueueDelta
            (QueueSummaryId, FieldSource, FieldCode, OldValue, NewValue)
        SELECT queued.QueueSummaryId, 'DEFAULT', snapshot.FieldCode, NULL, snapshot.FieldValue
        FROM #Queued AS queued
        INNER JOIN #Candidates AS candidate
            ON candidate.TriggerId = queued.TriggerId AND candidate.TicketId = queued.TicketId
        INNER JOIN dbo.Tickets AS ticket ON ticket.Id = queued.TicketId
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
                ('hourssincecreated', CONVERT(NVARCHAR(MAX), DATEDIFF(HOUR, ticket.CreatedAt, @Now))),
                ('hourssincestatuschanged', CONVERT(NVARCHAR(MAX), DATEDIFF(HOUR, COALESCE(ticket.StatusChangedAt, ticket.CreatedAt), @Now))),
                ('isbusinesshour', CONVERT(NVARCHAR(MAX), candidate.IsBusinessHour)),
                ('isholiday', CONVERT(NVARCHAR(MAX), candidate.IsHoliday))
        ) AS snapshot(FieldCode, FieldValue);

        INSERT dbo.AutomationTriggerQueueDelta
            (QueueSummaryId, FieldSource, FieldCode, OldValue, NewValue)
        SELECT
            queued.QueueSummaryId, 'CUSTOM', LOWER(field.FieldCode), NULL,
            COALESCE
            (
                value.TextValue, CONVERT(NVARCHAR(MAX), value.NumberValue),
                CONVERT(NVARCHAR(MAX), value.DecimalValue), CONVERT(NVARCHAR(MAX), value.DateValue, 23),
                CASE WHEN value.BooleanValue = 1 THEN 'true' WHEN value.BooleanValue = 0 THEN 'false' END,
                CONVERT(NVARCHAR(MAX), value.SelectedOptionId)
            )
        FROM #Queued AS queued
        INNER JOIN dbo.TicketFieldValues AS value ON value.TicketId = queued.TicketId
        INNER JOIN dbo.TicketFields AS field ON field.Id = value.TicketFieldId;

        INSERT dbo.AutomationTriggerQueueDelta
            (QueueSummaryId, FieldSource, FieldCode, OldValue, NewValue)
        SELECT queued.QueueSummaryId, 'TIME', time_value.FieldCode, NULL, time_value.FieldValue
        FROM #Queued AS queued
        INNER JOIN dbo.Tickets AS ticket ON ticket.Id = queued.TicketId
        CROSS APPLY
        (
            VALUES
                ('hourssincecreated', CONVERT(NVARCHAR(MAX), DATEDIFF(HOUR, ticket.CreatedAt, @Now))),
                ('hourssinceupdated', CONVERT(NVARCHAR(MAX), DATEDIFF(HOUR, ticket.UpdatedAt, @Now))),
                ('hourssincestatuschanged', CONVERT(NVARCHAR(MAX), DATEDIFF(HOUR, COALESCE(ticket.StatusChangedAt, ticket.CreatedAt), @Now)))
        ) AS time_value(FieldCode, FieldValue);

        INSERT dbo.AutomationTriggerQueueDelta
            (QueueSummaryId, FieldSource, FieldCode, OldValue, NewValue)
        SELECT queued.QueueSummaryId, 'REQUESTER', requester_value.FieldCode, NULL, requester_value.FieldValue
        FROM #Queued AS queued
        INNER JOIN dbo.Tickets AS ticket ON ticket.Id = queued.TicketId
        INNER JOIN dbo.Contacts AS requester ON requester.Id = ticket.RequesterContactId
        CROSS APPLY
        (
            VALUES
                ('status', CONVERT(NVARCHAR(MAX), requester.Status)),
                ('primary_company_id', CONVERT(NVARCHAR(MAX), requester.PrimaryCompanyId)),
                ('primary_email', CONVERT(NVARCHAR(MAX), requester.PrimaryEmail))
        ) AS requester_value(FieldCode, FieldValue);

        INSERT dbo.AutomationTriggerQueueDelta
            (QueueSummaryId, FieldSource, FieldCode, OldValue, NewValue)
        SELECT queued.QueueSummaryId, 'COMPANY', company_value.FieldCode, NULL, company_value.FieldValue
        FROM #Queued AS queued
        INNER JOIN dbo.Tickets AS ticket ON ticket.Id = queued.TicketId
        INNER JOIN dbo.Companies AS company ON company.Id = ticket.RequesterCompanyId
        OUTER APPLY
        (
            SELECT TOP (1) domain.Domain
            FROM dbo.CompanyDomains AS domain
            WHERE domain.CompanyId = company.Id
            ORDER BY domain.Id
        ) AS primary_domain
        CROSS APPLY
        (
            VALUES
                ('id', CONVERT(NVARCHAR(MAX), company.Id)),
                ('name', CONVERT(NVARCHAR(MAX), company.Name)),
                ('domain', CONVERT(NVARCHAR(MAX), primary_domain.Domain))
        ) AS company_value(FieldCode, FieldValue);

        INSERT dbo.AutomationTriggerQueueDelta
            (QueueSummaryId, FieldSource, FieldCode, OldValue, NewValue)
        SELECT queued.QueueSummaryId, 'ASSIGNED_AGENT', agent_value.FieldCode, NULL, agent_value.FieldValue
        FROM #Queued AS queued
        INNER JOIN dbo.Tickets AS ticket ON ticket.Id = queued.TicketId
        INNER JOIN dbo.Agents AS agent ON agent.Id = ticket.AssignedAgentId
        OUTER APPLY
        (
            SELECT TOP (1) membership.GroupId
            FROM dbo.GroupAgents AS membership
            WHERE membership.AgentId = agent.Id
            ORDER BY membership.Id
        ) AS primary_membership
        CROSS APPLY
        (
            VALUES
                ('status', CONVERT(NVARCHAR(MAX), agent.Status)),
                ('ticket_availability', CONVERT(NVARCHAR(MAX), agent.TicketAvailability)),
                ('group_id', CONVERT(NVARCHAR(MAX), primary_membership.GroupId))
        ) AS agent_value(FieldCode, FieldValue);

        SELECT @QueuedCount = COUNT(*) FROM #Queued;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT @QueuedCount AS QueuedCount;
END;
GO
