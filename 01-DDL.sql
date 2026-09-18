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
-- 7. Execution Tables: AutomationExecutions and AutomationExecutionActions
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

IF OBJECT_ID('dbo.AutomationExecutionActions', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.AutomationExecutionActions
    (
        Id UNIQUEIDENTIFIER NOT NULL PRIMARY KEY DEFAULT NEWID(),
        AutomationExecutionId UNIQUEIDENTIFIER NOT NULL REFERENCES dbo.AutomationExecutions(Id) ON DELETE CASCADE,
        ActionOrder INT NOT NULL DEFAULT 1,
        ActionType VARCHAR(50) NOT NULL,
        ActionValue NVARCHAR(MAX) NOT NULL, -- Immutable snapshot from AutomationTriggerActions
        RenderedValue NVARCHAR(MAX) NULL, -- Resolved value populated by Application Worker
        RenderedAt DATETIMEOFFSET NULL,
        Status VARCHAR(20) NOT NULL DEFAULT 'PENDING', -- PENDING, CLAIMED, COMPLETED, FAILED
        ClaimedAt DATETIMEOFFSET NULL,
        ClaimedBy VARCHAR(100) NULL,
        CompletedAt DATETIMEOFFSET NULL,
        ErrorMessage NVARCHAR(MAX) NULL,
        CreatedAt DATETIMEOFFSET NOT NULL DEFAULT (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
        CONSTRAINT CK_AutomationExecutionActions_Status CHECK (Status IN ('PENDING', 'CLAIMED', 'COMPLETED', 'FAILED'))
    );

    CREATE NONCLUSTERED INDEX IX_AutomationExecutionActions_Status_Claim
    ON dbo.AutomationExecutionActions (Status, ActionOrder ASC)
    INCLUDE (AutomationExecutionId, ActionType);
END;
GO
