-- =================================================================================================
-- OneDesk Automation v1.0 - Phase 1: Schema Setup (DDL)
-- =================================================================================================
USE OneDeskDb;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- -------------------------------------------------------------------------------------------------
-- 1. Integration Alteration: TicketActivityLogs
-- -------------------------------------------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID('dbo.TicketActivityLogs') 
      AND name = 'AutomationExecutionId'
)
BEGIN
    ALTER TABLE dbo.TicketActivityLogs
    ADD AutomationExecutionId UNIQUEIDENTIFIER NULL;
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes 
    WHERE name = 'IX_TicketActivityLogs_AutomationExecutionId' 
      AND object_id = OBJECT_ID('dbo.TicketActivityLogs')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_TicketActivityLogs_AutomationExecutionId
    ON dbo.TicketActivityLogs (AutomationExecutionId)
    WHERE AutomationExecutionId IS NOT NULL;
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes 
    WHERE name = 'IX_TicketActivityLogs_Id_CreatedAt' 
      AND object_id = OBJECT_ID('dbo.TicketActivityLogs')
)
BEGIN
    CREATE NONCLUSTERED INDEX IX_TicketActivityLogs_Id_CreatedAt
    ON dbo.TicketActivityLogs (Id ASC, CreatedAt ASC);
END;
GO

-- -------------------------------------------------------------------------------------------------
-- 2. Configuration: AutomationSettings
-- -------------------------------------------------------------------------------------------------
IF OBJECT_ID('dbo.AutomationSettings', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AutomationSettings
    (
        SettingKey VARCHAR(50) NOT NULL PRIMARY KEY,
        SettingValue NVARCHAR(500) NOT NULL,
        Description NVARCHAR(500) NULL,
        CreatedAt DATETIMEOFFSET NOT NULL DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
        UpdatedAt DATETIMEOFFSET NOT NULL DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC')
    );

    INSERT INTO dbo.AutomationSettings (SettingKey, SettingValue, Description)
    VALUES ('MaxExecutionDepth', '10', 'Maximum cascading rule execution depth to prevent infinite loops');
END;
GO

-- -------------------------------------------------------------------------------------------------
-- 3. Configuration: Business Calendars, Schedules, and Holidays
-- -------------------------------------------------------------------------------------------------
IF OBJECT_ID('dbo.BusinessCalendars', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.BusinessCalendars
    (
        Id UNIQUEIDENTIFIER NOT NULL PRIMARY KEY DEFAULT NEWID(),
        Name NVARCHAR(100) NOT NULL,
        Description NVARCHAR(500) NULL,
        Timezone VARCHAR(50) NOT NULL DEFAULT 'UTC',
        IsDefault BIT NOT NULL DEFAULT 0,
        IsActive BIT NOT NULL DEFAULT 1,
        CreatedAt DATETIMEOFFSET NOT NULL DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
        UpdatedAt DATETIMEOFFSET NOT NULL DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC')
    );
END;
GO

IF OBJECT_ID('dbo.BusinessCalendarSchedules', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.BusinessCalendarSchedules
    (
        Id UNIQUEIDENTIFIER NOT NULL PRIMARY KEY DEFAULT NEWID(),
        CalendarId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.BusinessCalendars(Id) ON DELETE CASCADE,
        DayOfWeek TINYINT NOT NULL, -- 1=Sunday, 2=Monday, ..., 7=Saturday (Standard DATEPART dw)
        StartTime TIME(0) NOT NULL,
        EndTime TIME(0) NOT NULL,
        IsWorkingDay BIT NOT NULL DEFAULT 1,
        CONSTRAINT CK_BusinessCalendarSchedules_Time CHECK (EndTime > StartTime OR IsWorkingDay = 0),
        CONSTRAINT CK_BusinessCalendarSchedules_Day CHECK (DayOfWeek BETWEEN 1 AND 7)
    );

    CREATE NONCLUSTERED INDEX IX_BusinessCalendarSchedules_Calendar_Day 
    ON dbo.BusinessCalendarSchedules (CalendarId, DayOfWeek, IsWorkingDay);
END;
GO

IF OBJECT_ID('dbo.BusinessCalendarHolidays', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.BusinessCalendarHolidays
    (
        Id UNIQUEIDENTIFIER NOT NULL PRIMARY KEY DEFAULT NEWID(),
        CalendarId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.BusinessCalendars(Id) ON DELETE CASCADE,
        HolidayDate DATE NOT NULL,
        HolidayName NVARCHAR(100) NOT NULL,
        CreatedAt DATETIMEOFFSET NOT NULL DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
        CONSTRAINT UQ_BusinessCalendarHolidays UNIQUE (CalendarId, HolidayDate)
    );

    CREATE NONCLUSTERED INDEX IX_BusinessCalendarHolidays_Date 
    ON dbo.BusinessCalendarHolidays (CalendarId, HolidayDate);
END;
GO

-- -------------------------------------------------------------------------------------------------
-- 4. Configuration: AutomationEventSettings
-- -------------------------------------------------------------------------------------------------
IF OBJECT_ID('dbo.AutomationEventSettings', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AutomationEventSettings
    (
        Id UNIQUEIDENTIFIER NOT NULL PRIMARY KEY DEFAULT NEWID(),
        EventType VARCHAR(50) NOT NULL,
        ExecutionMode VARCHAR(20) NOT NULL DEFAULT 'FIRST_MATCH', -- FIRST_MATCH or ALL_MATCH
        IsActive BIT NOT NULL DEFAULT 1,
        CreatedAt DATETIMEOFFSET NOT NULL DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
        UpdatedAt DATETIMEOFFSET NOT NULL DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
        CONSTRAINT UQ_AutomationEventSettings_EventType UNIQUE (EventType),
        CONSTRAINT CK_AutomationEventSettings_Mode CHECK (ExecutionMode IN ('FIRST_MATCH', 'ALL_MATCH'))
    );
END;
GO

-- -------------------------------------------------------------------------------------------------
-- 5. Configuration: AutomationTriggers, Blocks, Rules, and Actions
-- -------------------------------------------------------------------------------------------------
IF OBJECT_ID('dbo.AutomationTriggers', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AutomationTriggers
    (
        Id UNIQUEIDENTIFIER NOT NULL PRIMARY KEY DEFAULT NEWID(),
        Name NVARCHAR(200) NOT NULL,
        Description NVARCHAR(MAX) NULL,
        EventType VARCHAR(50) NOT NULL, -- TICKET_CREATED, TICKET_UPDATED, PUBLIC_REPLY_ADDED, TIME_TRIGGER, etc.
        Priority INT NOT NULL DEFAULT 100, -- Lower number = higher priority for evaluation
        IsActive BIT NOT NULL DEFAULT 1,
        BusinessCalendarId UNIQUEIDENTIFIER NULL REFERENCES dbo.BusinessCalendars(Id),
        TimeTriggerCron VARCHAR(100) NULL,
        CreatedBy NVARCHAR(320) NOT NULL DEFAULT 'SYSTEM',
        CreatedAt DATETIMEOFFSET NOT NULL DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
        UpdatedBy NVARCHAR(320) NOT NULL DEFAULT 'SYSTEM',
        UpdatedAt DATETIMEOFFSET NOT NULL DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC')
    );

    CREATE NONCLUSTERED INDEX IX_AutomationTriggers_EventType_Priority
    ON dbo.AutomationTriggers (EventType, IsActive, Priority);
END;
GO

IF OBJECT_ID('dbo.AutomationTriggerBlocks', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AutomationTriggerBlocks
    (
        Id UNIQUEIDENTIFIER NOT NULL PRIMARY KEY DEFAULT NEWID(),
        TriggerId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.AutomationTriggers(Id) ON DELETE CASCADE,
        BlockOrder INT NOT NULL DEFAULT 1,
        LogicalOperator VARCHAR(10) NOT NULL DEFAULT 'AND', -- AND, OR
        CreatedAt DATETIMEOFFSET NOT NULL DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
        CONSTRAINT CK_AutomationTriggerBlocks_Op CHECK (LogicalOperator IN ('AND', 'OR'))
    );

    CREATE NONCLUSTERED INDEX IX_AutomationTriggerBlocks_TriggerId
    ON dbo.AutomationTriggerBlocks (TriggerId, BlockOrder);
END;
GO

IF OBJECT_ID('dbo.AutomationTriggerRules', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AutomationTriggerRules
    (
        Id UNIQUEIDENTIFIER NOT NULL PRIMARY KEY DEFAULT NEWID(),
        TriggerBlockId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.AutomationTriggerBlocks(Id) ON DELETE CASCADE,
        RuleOrder INT NOT NULL DEFAULT 1,
        FieldSource VARCHAR(20) NOT NULL, -- DEFAULT, CUSTOM, EVENT, SYSTEM
        FieldCode VARCHAR(100) NOT NULL, -- status, priority, groupId, or custom field code
        Operator VARCHAR(50) NOT NULL,   -- EQUALS, NOT_EQUALS, CONTAINS, CHANGED_FROM, CHANGED_TO, etc.
        Value NVARCHAR(MAX) NULL,
        SecondaryValue NVARCHAR(MAX) NULL,
        CreatedAt DATETIMEOFFSET NOT NULL DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
        CONSTRAINT CK_AutomationTriggerRules_Source CHECK (FieldSource IN ('DEFAULT', 'CUSTOM', 'EVENT', 'SYSTEM'))
    );

    CREATE NONCLUSTERED INDEX IX_AutomationTriggerRules_BlockId
    ON dbo.AutomationTriggerRules (TriggerBlockId, RuleOrder);
END;
GO

IF OBJECT_ID('dbo.AutomationTriggerActions', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AutomationTriggerActions
    (
        Id UNIQUEIDENTIFIER NOT NULL PRIMARY KEY DEFAULT NEWID(),
        TriggerId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.AutomationTriggers(Id) ON DELETE CASCADE,
        ActionOrder INT NOT NULL DEFAULT 1,
        ActionType VARCHAR(50) NOT NULL, -- SET_STATUS, SET_PRIORITY, ASSIGN_AGENT, ASSIGN_GROUP, SEND_EMAIL, ADD_REPLY, etc.
        ActionValue NVARCHAR(MAX) NOT NULL, -- Immutable template or JSON configuration
        CreatedAt DATETIMEOFFSET NOT NULL DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC')
    );

    CREATE NONCLUSTERED INDEX IX_AutomationTriggerActions_TriggerId
    ON dbo.AutomationTriggerActions (TriggerId, ActionOrder);
END;
GO

-- -------------------------------------------------------------------------------------------------
-- 6. Queue Tables: AutomationTriggerQueueSummary, Source, Delta, Rule
-- -------------------------------------------------------------------------------------------------
IF OBJECT_ID('dbo.AutomationTriggerQueueSummary', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AutomationTriggerQueueSummary
    (
        Id BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        TicketId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.Tickets(Id),
        QueueSourceType VARCHAR(30) NOT NULL, -- ACTIVITY_LOG, TIME_TRIGGER
        CandidateTriggerId UNIQUEIDENTIFIER NULL REFERENCES dbo.AutomationTriggers(Id),
        EvaluationBucket VARCHAR(100) NOT NULL DEFAULT '',
        SourceAutomationExecutionId UNIQUEIDENTIFIER NULL,
        RootExecutionId UNIQUEIDENTIFIER NULL,
        ExecutionDepth INT NOT NULL DEFAULT 0,
        OccurredAt DATETIMEOFFSET NOT NULL,
        BusinessCalendarId UNIQUEIDENTIFIER NULL REFERENCES dbo.BusinessCalendars(Id),
        IsBusinessHour BIT NOT NULL DEFAULT 0,
        IsHoliday BIT NOT NULL DEFAULT 0,
        Status VARCHAR(20) NOT NULL DEFAULT 'PENDING', -- PENDING, PROCESSING, COMPLETED, SKIPPED, FAILED
        SkipReason VARCHAR(50) NULL, -- SKIPPED_MAX_DEPTH, NO_MATCH
        ProcessedAt DATETIMEOFFSET NULL,
        CreatedAt DATETIMEOFFSET NOT NULL DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
        CONSTRAINT CK_AutomationTriggerQueueSummary_Status CHECK (Status IN ('PENDING', 'PROCESSING', 'COMPLETED', 'SKIPPED', 'FAILED'))
    );

    CREATE NONCLUSTERED INDEX IX_AutomationTriggerQueueSummary_Status_OccurredAt
    ON dbo.AutomationTriggerQueueSummary (Status, OccurredAt ASC)
    INCLUDE (TicketId, QueueSourceType, CandidateTriggerId, ExecutionDepth);

    CREATE UNIQUE NONCLUSTERED INDEX UQ_AutomationTriggerQueueSummary_TimeTrigger_Bucket
    ON dbo.AutomationTriggerQueueSummary (TicketId, CandidateTriggerId, EvaluationBucket)
    WHERE QueueSourceType = 'TIME_TRIGGER' AND CandidateTriggerId IS NOT NULL;
END;
GO

IF OBJECT_ID('dbo.AutomationTriggerQueueSource', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AutomationTriggerQueueSource
    (
        QueueSummaryId BIGINT NOT NULL REFERENCES dbo.AutomationTriggerQueueSummary(Id) ON DELETE CASCADE,
        TicketActivityLogId BIGINT NOT NULL REFERENCES dbo.TicketActivityLogs(Id),
        CreatedAt DATETIMEOFFSET NOT NULL DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
        PRIMARY KEY (QueueSummaryId, TicketActivityLogId)
    );

    CREATE NONCLUSTERED INDEX IX_AutomationTriggerQueueSource_ActivityLogId
    ON dbo.AutomationTriggerQueueSource (TicketActivityLogId);
END;
GO

IF OBJECT_ID('dbo.AutomationTriggerQueueDelta', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AutomationTriggerQueueDelta
    (
        Id BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        QueueSummaryId BIGINT NOT NULL REFERENCES dbo.AutomationTriggerQueueSummary(Id) ON DELETE CASCADE,
        FieldSource VARCHAR(20) NOT NULL, -- DEFAULT, CUSTOM, EVENT
        FieldCode VARCHAR(100) NOT NULL,
        OldValue NVARCHAR(MAX) NULL,
        NewValue NVARCHAR(MAX) NULL,
        CreatedAt DATETIMEOFFSET NOT NULL DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC')
    );

    CREATE NONCLUSTERED INDEX IX_AutomationTriggerQueueDelta_Summary_Field
    ON dbo.AutomationTriggerQueueDelta (QueueSummaryId, FieldSource, FieldCode);
END;
GO

IF OBJECT_ID('dbo.AutomationTriggerQueueRule', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AutomationTriggerQueueRule
    (
        Id BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        QueueSummaryId BIGINT NOT NULL REFERENCES dbo.AutomationTriggerQueueSummary(Id) ON DELETE CASCADE,
        TriggerId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.AutomationTriggers(Id),
        RuleId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.AutomationTriggerRules(Id),
        IsMatched BIT NOT NULL,
        EvaluatedAt DATETIMEOFFSET NOT NULL DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC')
    );

    CREATE NONCLUSTERED INDEX IX_AutomationTriggerQueueRule_Summary
    ON dbo.AutomationTriggerQueueRule (QueueSummaryId, TriggerId, IsMatched);
END;
GO

-- -------------------------------------------------------------------------------------------------
-- 7. Durable execution occurrence table
-- -------------------------------------------------------------------------------------------------
IF OBJECT_ID('dbo.AutomationExecutions', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AutomationExecutions
    (
        Id UNIQUEIDENTIFIER NOT NULL PRIMARY KEY DEFAULT NEWID(),
        QueueSummaryId BIGINT NOT NULL REFERENCES dbo.AutomationTriggerQueueSummary(Id),
        TriggerId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.AutomationTriggers(Id),
        TicketId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.Tickets(Id),
        ParentExecutionId UNIQUEIDENTIFIER NULL REFERENCES dbo.AutomationExecutions(Id),
        RootExecutionId UNIQUEIDENTIFIER NOT NULL,
        ExecutionDepth INT NOT NULL DEFAULT 0,
        Status VARCHAR(20) NOT NULL DEFAULT 'PENDING', -- PENDING, IN_PROGRESS, COMPLETED, PARTIAL_FAILED, FAILED, SKIPPED
        SkipReason VARCHAR(50) NULL,
        ExecutedAt DATETIMEOFFSET NULL,
        CreatedAt DATETIMEOFFSET NOT NULL DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
        CONSTRAINT CK_AutomationExecutions_Status CHECK (Status IN ('PENDING', 'IN_PROGRESS', 'COMPLETED', 'PARTIAL_FAILED', 'FAILED', 'SKIPPED'))
    );

    CREATE NONCLUSTERED INDEX IX_AutomationExecutions_Ticket_Lineage
    ON dbo.AutomationExecutions (TicketId, RootExecutionId, ExecutionDepth);
END;
GO

-- -------------------------------------------------------------------------------------------------
-- 8. Flow-guide compatibility migration
--
-- The original v1 draft combined execution and action state. The flow guide deliberately keeps
-- queue state, durable evaluation audit, selected trigger state, executable action state, and final
-- action history separate.  The following migration is safe to run both for a new database and over
-- an earlier v1 draft.
-- -------------------------------------------------------------------------------------------------

IF COL_LENGTH('dbo.TicketActivityLogs', 'OperationId') IS NULL
BEGIN
    ALTER TABLE dbo.TicketActivityLogs ADD OperationId UNIQUEIDENTIFIER NULL;
END;
GO

IF COL_LENGTH('dbo.Tickets', 'CreateAutomationStatus') IS NULL
BEGIN
    ALTER TABLE dbo.Tickets ADD CreateAutomationStatus VARCHAR(20) NOT NULL
        CONSTRAINT DF_Tickets_CreateAutomationStatus DEFAULT ('READY');
END;
GO

IF NOT EXISTS
(
    SELECT 1 FROM sys.check_constraints
    WHERE parent_object_id = OBJECT_ID('dbo.Tickets')
      AND name = 'CK_Tickets_CreateAutomationStatus'
)
BEGIN
    ALTER TABLE dbo.Tickets ADD CONSTRAINT CK_Tickets_CreateAutomationStatus
        CHECK (CreateAutomationStatus IN ('PENDING', 'READY'));
END;
GO

IF COL_LENGTH('dbo.AutomationTriggerActions', 'ExecutionTarget') IS NULL
BEGIN
    ALTER TABLE dbo.AutomationTriggerActions ADD ExecutionTarget VARCHAR(20) NULL;
END;
GO

UPDATE dbo.AutomationTriggerActions
SET ExecutionTarget = CASE
        WHEN ActionType IN ('SET_STATUS', 'SET_PRIORITY', 'SET_GROUP', 'SET_AGENT',
                            'SET_TYPE', 'SET_DUE_DATE', 'SET_CUSTOM_FIELD')
            THEN 'AUTOMATION'
        ELSE 'APPLICATION'
    END
WHERE ExecutionTarget IS NULL;
GO

IF EXISTS
(
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.AutomationTriggerActions')
      AND name = 'ExecutionTarget' AND is_nullable = 1
)
BEGIN
    ALTER TABLE dbo.AutomationTriggerActions ALTER COLUMN ExecutionTarget VARCHAR(20) NOT NULL;
END;
GO

IF NOT EXISTS
(
    SELECT 1 FROM sys.default_constraints
    WHERE parent_object_id = OBJECT_ID('dbo.AutomationTriggerActions')
      AND name = 'DF_AutomationTriggerActions_ExecutionTarget'
)
BEGIN
    ALTER TABLE dbo.AutomationTriggerActions ADD
        CONSTRAINT DF_AutomationTriggerActions_ExecutionTarget DEFAULT ('APPLICATION') FOR ExecutionTarget;
END;
GO

IF NOT EXISTS
(
    SELECT 1 FROM sys.check_constraints
    WHERE parent_object_id = OBJECT_ID('dbo.AutomationTriggerActions')
      AND name = 'CK_AutomationTriggerActions_ExecutionTarget'
)
BEGIN
    ALTER TABLE dbo.AutomationTriggerActions ADD
        CONSTRAINT CK_AutomationTriggerActions_ExecutionTarget CHECK (ExecutionTarget IN ('AUTOMATION', 'APPLICATION'));
END;
GO

IF COL_LENGTH('dbo.AutomationTriggerActions', 'TargetField') IS NULL
BEGIN
    ALTER TABLE dbo.AutomationTriggerActions ADD TargetField VARCHAR(100) NULL;
END;
GO

UPDATE dbo.AutomationTriggerActions
SET TargetField = CASE ActionType
        WHEN 'SET_STATUS' THEN 'status'
        WHEN 'SET_PRIORITY' THEN 'priority'
        WHEN 'SET_GROUP' THEN 'groupId'
        WHEN 'SET_AGENT' THEN 'assignedAgentId'
        WHEN 'SET_TYPE' THEN 'typeOptionId'
        WHEN 'SET_DUE_DATE' THEN 'dueDate'
        ELSE TargetField
    END
WHERE TargetField IS NULL;
GO

IF COL_LENGTH('dbo.AutomationTriggerQueueSummary', 'EventType') IS NULL
BEGIN
    ALTER TABLE dbo.AutomationTriggerQueueSummary ADD EventType VARCHAR(50) NULL;
END;
GO

UPDATE dbo.AutomationTriggerQueueSummary SET EventType = 'UNKNOWN' WHERE EventType IS NULL;
GO

IF EXISTS
(
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.AutomationTriggerQueueSummary')
      AND name = 'EventType' AND is_nullable = 1
)
BEGIN
    ALTER TABLE dbo.AutomationTriggerQueueSummary ALTER COLUMN EventType VARCHAR(50) NOT NULL;
END;
GO

IF COL_LENGTH('dbo.AutomationTriggerQueueSummary', 'OperationId') IS NULL
    ALTER TABLE dbo.AutomationTriggerQueueSummary ADD OperationId UNIQUEIDENTIFIER NULL;
GO
IF COL_LENGTH('dbo.AutomationTriggerQueueSummary', 'ClaimedBy') IS NULL
    ALTER TABLE dbo.AutomationTriggerQueueSummary ADD ClaimedBy VARCHAR(100) NULL;
GO
IF COL_LENGTH('dbo.AutomationTriggerQueueSummary', 'ClaimedAt') IS NULL
    ALTER TABLE dbo.AutomationTriggerQueueSummary ADD ClaimedAt DATETIMEOFFSET NULL;
GO
IF COL_LENGTH('dbo.AutomationTriggerQueueSummary', 'LeaseExpiresAt') IS NULL
    ALTER TABLE dbo.AutomationTriggerQueueSummary ADD LeaseExpiresAt DATETIMEOFFSET NULL;
GO
IF COL_LENGTH('dbo.AutomationTriggerQueueSummary', 'ErrorMessage') IS NULL
    ALTER TABLE dbo.AutomationTriggerQueueSummary ADD ErrorMessage NVARCHAR(2000) NULL;
GO

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.AutomationTriggerQueueSummary')
      AND name = 'UQ_AutomationTriggerQueueSummary_ActivityOperation'
)
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UQ_AutomationTriggerQueueSummary_ActivityOperation
    ON dbo.AutomationTriggerQueueSummary (TicketId, OperationId)
    WHERE QueueSourceType = 'ACTIVITY_LOG' AND OperationId IS NOT NULL;
END;
GO

IF NOT EXISTS
(
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.AutomationTriggerQueueSource')
      AND name = 'UQ_AutomationTriggerQueueSource_ActivityLogId'
)
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UQ_AutomationTriggerQueueSource_ActivityLogId
    ON dbo.AutomationTriggerQueueSource (TicketActivityLogId);
END;
GO

IF COL_LENGTH('dbo.AutomationTriggerQueueRule', 'ActualFromValue') IS NULL
    ALTER TABLE dbo.AutomationTriggerQueueRule ADD ActualFromValue NVARCHAR(MAX) NULL;
GO
IF COL_LENGTH('dbo.AutomationTriggerQueueRule', 'ActualToValue') IS NULL
    ALTER TABLE dbo.AutomationTriggerQueueRule ADD ActualToValue NVARCHAR(MAX) NULL;
GO
IF COL_LENGTH('dbo.AutomationTriggerQueueRule', 'ExpectedValue') IS NULL
    ALTER TABLE dbo.AutomationTriggerQueueRule ADD ExpectedValue NVARCHAR(MAX) NULL;
GO

-- Durable audit: one row for every candidate trigger, whether or not it matched or was selected.
IF OBJECT_ID('dbo.AutomationEvaluations', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AutomationEvaluations
    (
        Id UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_AutomationEvaluations PRIMARY KEY,
        QueueSummaryId BIGINT NOT NULL REFERENCES dbo.AutomationTriggerQueueSummary(Id),
        TicketId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.Tickets(Id),
        TriggerId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.AutomationTriggers(Id),
        EventType VARCHAR(50) NOT NULL,
        ExecutionMode VARCHAR(20) NOT NULL,
        SortOrder INT NOT NULL,
        IsMatch BIT NOT NULL,
        IsSelected BIT NOT NULL,
        EvaluatedAt DATETIMEOFFSET NOT NULL CONSTRAINT DF_AutomationEvaluations_EvaluatedAt
            DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
        CONSTRAINT UQ_AutomationEvaluations_Queue_Trigger UNIQUE (QueueSummaryId, TriggerId)
    );

    CREATE INDEX IX_AutomationEvaluations_Ticket_EvaluatedAt
        ON dbo.AutomationEvaluations (TicketId, EvaluatedAt DESC)
        INCLUDE (TriggerId, EventType, IsMatch, IsSelected);
    CREATE INDEX IX_AutomationEvaluations_Retention
        ON dbo.AutomationEvaluations (EvaluatedAt, Id);
END;
GO

IF OBJECT_ID('dbo.AutomationEvaluationBlocks', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AutomationEvaluationBlocks
    (
        Id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AutomationEvaluationBlocks PRIMARY KEY,
        EvaluationId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.AutomationEvaluations(Id),
        TriggerBlockId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.AutomationTriggerBlocks(Id),
        LogicalOperator VARCHAR(10) NOT NULL,
        IsMatch BIT NOT NULL,
        EvaluatedAt DATETIMEOFFSET NOT NULL CONSTRAINT DF_AutomationEvaluationBlocks_EvaluatedAt
            DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
        CONSTRAINT UQ_AutomationEvaluationBlocks_Evaluation_Block UNIQUE (EvaluationId, TriggerBlockId)
    );

    CREATE INDEX IX_AutomationEvaluationBlocks_Retention
        ON dbo.AutomationEvaluationBlocks (EvaluatedAt, Id);
END;
GO

IF OBJECT_ID('dbo.AutomationEvaluationRules', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AutomationEvaluationRules
    (
        Id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AutomationEvaluationRules PRIMARY KEY,
        EvaluationId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.AutomationEvaluations(Id),
        TriggerBlockId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.AutomationTriggerBlocks(Id),
        RuleId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.AutomationTriggerRules(Id),
        FieldSource VARCHAR(20) NOT NULL,
        FieldCode VARCHAR(100) NOT NULL,
        Operator VARCHAR(50) NOT NULL,
        FromValue NVARCHAR(MAX) NULL,
        ToValue NVARCHAR(MAX) NULL,
        ExpectedValue NVARCHAR(MAX) NULL,
        IsMatch BIT NOT NULL,
        EvaluatedAt DATETIMEOFFSET NOT NULL CONSTRAINT DF_AutomationEvaluationRules_EvaluatedAt
            DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
        CONSTRAINT UQ_AutomationEvaluationRules_Evaluation_Rule UNIQUE (EvaluationId, RuleId)
    );

    CREATE INDEX IX_AutomationEvaluationRules_Evaluation
        ON dbo.AutomationEvaluationRules (EvaluationId, TriggerBlockId, IsMatch);
    CREATE INDEX IX_AutomationEvaluationRules_Retention
        ON dbo.AutomationEvaluationRules (EvaluatedAt, Id);
END;
GO

IF OBJECT_ID('dbo.AutomationTriggerQueueTrigger', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AutomationTriggerQueueTrigger
    (
        Id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AutomationTriggerQueueTrigger PRIMARY KEY,
        QueueSummaryId BIGINT NOT NULL REFERENCES dbo.AutomationTriggerQueueSummary(Id),
        EvaluationId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.AutomationEvaluations(Id),
        TriggerId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.AutomationTriggers(Id),
        AutomationExecutionId UNIQUEIDENTIFIER NULL,
        SortOrder INT NOT NULL,
        Status VARCHAR(20) NOT NULL CONSTRAINT DF_AutomationTriggerQueueTrigger_Status DEFAULT ('SELECTED'),
        CreatedAt DATETIMEOFFSET NOT NULL CONSTRAINT DF_AutomationTriggerQueueTrigger_CreatedAt
            DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
        CONSTRAINT CK_AutomationTriggerQueueTrigger_Status CHECK (Status IN ('SELECTED', 'DISPATCHED')),
        CONSTRAINT UQ_AutomationTriggerQueueTrigger_Queue_Trigger UNIQUE (QueueSummaryId, TriggerId)
    );

    CREATE INDEX IX_AutomationTriggerQueueTrigger_Status
        ON dbo.AutomationTriggerQueueTrigger (Status, Id);
END;
GO

IF OBJECT_ID('dbo.AutomationTriggerQueueAction', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AutomationTriggerQueueAction
    (
        Id UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_AutomationTriggerQueueAction PRIMARY KEY,
        AutomationExecutionId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.AutomationExecutions(Id),
        TriggerActionId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.AutomationTriggerActions(Id),
        TicketId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.Tickets(Id),
        ActionSequence INT NOT NULL,
        ActionType VARCHAR(50) NOT NULL,
        ExecutionTarget VARCHAR(20) NOT NULL,
        TargetField VARCHAR(100) NULL,
        ActionValue NVARCHAR(MAX) NOT NULL,
        RenderedValue NVARCHAR(MAX) NULL,
        RenderedAt DATETIMEOFFSET NULL,
        Status VARCHAR(20) NOT NULL CONSTRAINT DF_AutomationTriggerQueueAction_Status DEFAULT ('READY'),
        AttemptCount INT NOT NULL CONSTRAINT DF_AutomationTriggerQueueAction_AttemptCount DEFAULT (0),
        ClaimedBy VARCHAR(100) NULL,
        ClaimedAt DATETIMEOFFSET NULL,
        LeaseExpiresAt DATETIMEOFFSET NULL,
        CompletedAt DATETIMEOFFSET NULL,
        LastError NVARCHAR(2000) NULL,
        CreatedAt DATETIMEOFFSET NOT NULL CONSTRAINT DF_AutomationTriggerQueueAction_CreatedAt
            DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
        CONSTRAINT CK_AutomationTriggerQueueAction_Target CHECK (ExecutionTarget IN ('AUTOMATION', 'APPLICATION')),
        CONSTRAINT CK_AutomationTriggerQueueAction_Status CHECK (Status IN ('READY', 'PROCESSING', 'SUCCEEDED', 'FAILED')),
        CONSTRAINT CK_AutomationTriggerQueueAction_AttemptCount CHECK (AttemptCount >= 0),
        CONSTRAINT UQ_AutomationTriggerQueueAction_Execution_Sequence UNIQUE (AutomationExecutionId, ActionSequence)
    );

    CREATE INDEX IX_AutomationTriggerQueueAction_Claim
        ON dbo.AutomationTriggerQueueAction (ExecutionTarget, Status, LeaseExpiresAt, CreatedAt)
        INCLUDE (AutomationExecutionId, TicketId, ActionSequence, AttemptCount, ActionType);
END;
GO

IF OBJECT_ID('dbo.AutomationActionHistories', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AutomationActionHistories
    (
        Id BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AutomationActionHistories PRIMARY KEY,
        QueueActionId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.AutomationTriggerQueueAction(Id),
        AutomationExecutionId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.AutomationExecutions(Id),
        TicketId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.Tickets(Id),
        AttemptNumber INT NOT NULL,
        ActionType VARCHAR(50) NOT NULL,
        ExecutionTarget VARCHAR(20) NOT NULL,
        TargetField VARCHAR(100) NULL,
        ConfiguredValue NVARCHAR(MAX) NOT NULL,
        ResolvedValue NVARCHAR(MAX) NULL,
        FromValue NVARCHAR(MAX) NULL,
        ToValue NVARCHAR(MAX) NULL,
        Status VARCHAR(20) NOT NULL,
        WorkerId VARCHAR(100) NULL,
        ErrorMessage NVARCHAR(2000) NULL,
        StartedAt DATETIMEOFFSET NULL,
        CompletedAt DATETIMEOFFSET NOT NULL,
        CONSTRAINT CK_AutomationActionHistories_Status CHECK (Status IN ('SUCCEEDED', 'FAILED')),
        CONSTRAINT UQ_AutomationActionHistories_Action_Attempt UNIQUE (QueueActionId, AttemptNumber)
    );

    CREATE INDEX IX_AutomationActionHistories_Execution
        ON dbo.AutomationActionHistories (AutomationExecutionId, Id);
    CREATE INDEX IX_AutomationActionHistories_Retention
        ON dbo.AutomationActionHistories (CompletedAt, Id);
END;
GO

-- Add the QueueTrigger -> Execution relationship after both tables exist.  It is intentionally not
-- cascading: queue cleanup must never remove durable execution/audit rows.
IF NOT EXISTS
(
    SELECT 1 FROM sys.foreign_keys
    WHERE parent_object_id = OBJECT_ID('dbo.AutomationTriggerQueueTrigger')
      AND name = 'FK_AutomationTriggerQueueTrigger_AutomationExecution'
)
BEGIN
    ALTER TABLE dbo.AutomationTriggerQueueTrigger WITH CHECK ADD CONSTRAINT
        FK_AutomationTriggerQueueTrigger_AutomationExecution
        FOREIGN KEY (AutomationExecutionId) REFERENCES dbo.AutomationExecutions(Id);
END;
GO

MERGE dbo.AutomationSettings AS target
USING
(
    VALUES
        ('ActionLeaseSeconds', '300', 'Lease duration for atomically claimed application actions'),
        ('ActionMaxAttempts', '5', 'Maximum action delivery attempts before terminal failure'),
        ('QueueRetentionDays', '7', 'Completed processing queue retention'),
        ('RuleAuditRetentionDays', '30', 'Detailed evaluation rule audit retention'),
        ('AuditRetentionDays', '365', 'Evaluation, execution, and action summary retention')
) AS source(SettingKey, SettingValue, Description)
ON target.SettingKey = source.SettingKey
WHEN NOT MATCHED THEN
    INSERT (SettingKey, SettingValue, Description)
    VALUES (source.SettingKey, source.SettingValue, source.Description);
GO

-- Durable rows retain the originating queue id as a correlation value, not as a lifecycle foreign
-- key.  Removing these two FKs allows bounded queue cleanup without deleting audit/executions.
DECLARE @DropQueueForeignKeySql NVARCHAR(MAX) = NULL;
SELECT TOP (1)
    @DropQueueForeignKeySql = N'ALTER TABLE dbo.AutomationExecutions DROP CONSTRAINT '
        + QUOTENAME(foreign_key.name) + N';'
FROM sys.foreign_keys AS foreign_key
INNER JOIN sys.foreign_key_columns AS foreign_key_column
    ON foreign_key_column.constraint_object_id = foreign_key.object_id
WHERE foreign_key.parent_object_id = OBJECT_ID('dbo.AutomationExecutions')
  AND foreign_key.referenced_object_id = OBJECT_ID('dbo.AutomationTriggerQueueSummary')
  AND COL_NAME(foreign_key.parent_object_id, foreign_key_column.parent_column_id) = 'QueueSummaryId';
IF @DropQueueForeignKeySql IS NOT NULL EXEC sys.sp_executesql @DropQueueForeignKeySql;
GO

DECLARE @DropAuditQueueForeignKeySql NVARCHAR(MAX) = NULL;
SELECT TOP (1)
    @DropAuditQueueForeignKeySql = N'ALTER TABLE dbo.AutomationEvaluations DROP CONSTRAINT '
        + QUOTENAME(foreign_key.name) + N';'
FROM sys.foreign_keys AS foreign_key
INNER JOIN sys.foreign_key_columns AS foreign_key_column
    ON foreign_key_column.constraint_object_id = foreign_key.object_id
WHERE foreign_key.parent_object_id = OBJECT_ID('dbo.AutomationEvaluations')
  AND foreign_key.referenced_object_id = OBJECT_ID('dbo.AutomationTriggerQueueSummary')
  AND COL_NAME(foreign_key.parent_object_id, foreign_key_column.parent_column_id) = 'QueueSummaryId';
IF @DropAuditQueueForeignKeySql IS NOT NULL EXEC sys.sp_executesql @DropAuditQueueForeignKeySql;
GO

DECLARE @DropHistoryActionForeignKeySql NVARCHAR(MAX) = NULL;
SELECT TOP (1)
    @DropHistoryActionForeignKeySql = N'ALTER TABLE dbo.AutomationActionHistories DROP CONSTRAINT '
        + QUOTENAME(foreign_key.name) + N';'
FROM sys.foreign_keys AS foreign_key
INNER JOIN sys.foreign_key_columns AS foreign_key_column
    ON foreign_key_column.constraint_object_id = foreign_key.object_id
WHERE foreign_key.parent_object_id = OBJECT_ID('dbo.AutomationActionHistories')
  AND foreign_key.referenced_object_id = OBJECT_ID('dbo.AutomationTriggerQueueAction')
  AND COL_NAME(foreign_key.parent_object_id, foreign_key_column.parent_column_id) = 'QueueActionId';
IF @DropHistoryActionForeignKeySql IS NOT NULL EXEC sys.sp_executesql @DropHistoryActionForeignKeySql;
GO
