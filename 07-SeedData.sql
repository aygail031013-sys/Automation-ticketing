-- =================================================================================================
-- OneDesk Automation v1.0 - Phase 6: Seed Data
-- =================================================================================================
USE OneDeskDb;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- -------------------------------------------------------------------------------------------------
-- 1. Automation Settings
-- -------------------------------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM dbo.AutomationSettings WHERE SettingKey = 'MaxExecutionDepth')
BEGIN
    INSERT INTO dbo.AutomationSettings (SettingKey, SettingValue, Description)
    VALUES ('MaxExecutionDepth', '10', 'Maximum cascading rule execution depth to prevent infinite loops');
END
ELSE
BEGIN
    UPDATE dbo.AutomationSettings 
    SET SettingValue = '10' 
    WHERE SettingKey = 'MaxExecutionDepth';
END;
GO

-- -------------------------------------------------------------------------------------------------
-- 2. Automation Event Settings
-- -------------------------------------------------------------------------------------------------
MERGE INTO dbo.AutomationEventSettings AS target
USING (VALUES
    ('TICKET_CREATED', 'FIRST_MATCH', 1),
    ('TICKET_UPDATED', 'ALL_MATCH', 1),
    ('PUBLIC_REPLY_ADDED', 'FIRST_MATCH', 1),
    ('TIME_TRIGGER', 'ALL_MATCH', 1)
) AS source(EventType, ExecutionMode, IsActive)
ON target.EventType = source.EventType
WHEN MATCHED THEN
    UPDATE SET target.ExecutionMode = source.ExecutionMode,
               target.IsActive = source.IsActive,
               target.UpdatedAt = (SYSUTCDATETIME() AT TIME ZONE 'UTC')
WHEN NOT MATCHED THEN
    INSERT (EventType, ExecutionMode, IsActive)
    VALUES (source.EventType, source.ExecutionMode, source.IsActive);
GO

-- -------------------------------------------------------------------------------------------------
-- 3. Business Calendar & Schedules
-- -------------------------------------------------------------------------------------------------
DECLARE @CalendarId UNIQUEIDENTIFIER;

SELECT TOP 1 @CalendarId = Id 
FROM dbo.BusinessCalendars 
WHERE Name = 'Standard Support 9x5 UTC';

IF @CalendarId IS NULL
BEGIN
    SET @CalendarId = NEWID();
    INSERT INTO dbo.BusinessCalendars (Id, Name, Description, Timezone, IsDefault, IsActive)
    VALUES (@CalendarId, 'Standard Support 9x5 UTC', 'Mon-Fri 09:00-17:00 UTC business hours', 'UTC', 1, 1);
END;

-- Schedules: Mon-Fri 09:00 - 17:00 (Days 2 to 6)
DELETE FROM dbo.BusinessCalendarSchedules WHERE CalendarId = @CalendarId;

INSERT INTO dbo.BusinessCalendarSchedules (CalendarId, DayOfWeek, StartTime, EndTime, IsWorkingDay)
VALUES
    (@CalendarId, 1, '00:00:00', '23:59:59', 0), -- Sunday
    (@CalendarId, 2, '09:00:00', '17:00:00', 1), -- Monday
    (@CalendarId, 3, '09:00:00', '17:00:00', 1), -- Tuesday
    (@CalendarId, 4, '09:00:00', '17:00:00', 1), -- Wednesday
    (@CalendarId, 5, '09:00:00', '17:00:00', 1), -- Thursday
    (@CalendarId, 6, '09:00:00', '17:00:00', 1), -- Friday
    (@CalendarId, 7, '00:00:00', '23:59:59', 0); -- Saturday

-- Sample Holidays
IF NOT EXISTS (SELECT 1 FROM dbo.BusinessCalendarHolidays WHERE CalendarId = @CalendarId AND HolidayDate = '2026-12-25')
BEGIN
    INSERT INTO dbo.BusinessCalendarHolidays (CalendarId, HolidayDate, HolidayName)
    VALUES (@CalendarId, '2026-12-25', 'Christmas Day');
END;

IF NOT EXISTS (SELECT 1 FROM dbo.BusinessCalendarHolidays WHERE CalendarId = @CalendarId AND HolidayDate = '2026-01-01')
BEGIN
    INSERT INTO dbo.BusinessCalendarHolidays (CalendarId, HolidayDate, HolidayName)
    VALUES (@CalendarId, '2026-01-01', 'New Year Day');
END;
GO

-- -------------------------------------------------------------------------------------------------
-- 4. Sample Automation Triggers
-- -------------------------------------------------------------------------------------------------

-- 4.1 Trigger 1: Auto-Escalate Urgent Tickets (TICKET_CREATED, Priority 10)
DECLARE @Trigger1Id UNIQUEIDENTIFIER;
SELECT TOP 1 @Trigger1Id = Id FROM dbo.AutomationTriggers WHERE Name = 'Auto-Escalate Urgent Tickets';

IF @Trigger1Id IS NULL
BEGIN
    SET @Trigger1Id = NEWID();
    INSERT INTO dbo.AutomationTriggers (Id, Name, Description, EventType, Priority, IsActive)
    VALUES (@Trigger1Id, 'Auto-Escalate Urgent Tickets', 'Set priority to URGENT if subject contains URGENT', 'TICKET_CREATED', 10, 1);

    DECLARE @Block1Id UNIQUEIDENTIFIER = NEWID();
    INSERT INTO dbo.AutomationTriggerBlocks (Id, TriggerId, BlockOrder, LogicalOperator)
    VALUES (@Block1Id, @Trigger1Id, 1, 'AND');

    INSERT INTO dbo.AutomationTriggerRules (TriggerBlockId, RuleOrder, FieldSource, FieldCode, Operator, Value)
    VALUES (@Block1Id, 1, 'DEFAULT', 'subject', 'CONTAINS', 'URGENT');

    INSERT INTO dbo.AutomationTriggerActions
        (TriggerId, ActionOrder, ActionType, ActionValue, ExecutionTarget, TargetField)
    VALUES 
        (@Trigger1Id, 1, 'SET_PRIORITY', '{"priority": "URGENT"}', 'AUTOMATION', 'priority'),
        (@Trigger1Id, 2, 'SEND_EMAIL', '{"to": "oncall@example.com", "template": "urgent_alert", "subject": "Urgent Ticket {{ticket.ticketNo}} Alert"}', 'APPLICATION', NULL);
END;

-- 4.2 Trigger 2: Standard Ticket Triage (TICKET_CREATED, Priority 50 - Lower Priority)
DECLARE @Trigger2Id UNIQUEIDENTIFIER;
SELECT TOP 1 @Trigger2Id = Id FROM dbo.AutomationTriggers WHERE Name = 'Standard Ticket Triage';

IF @Trigger2Id IS NULL
BEGIN
    SET @Trigger2Id = NEWID();
    INSERT INTO dbo.AutomationTriggers (Id, Name, Description, EventType, Priority, IsActive)
    VALUES (@Trigger2Id, 'Standard Ticket Triage', 'Triage tickets created with status OPEN', 'TICKET_CREATED', 50, 1);

    DECLARE @Block2Id UNIQUEIDENTIFIER = NEWID();
    INSERT INTO dbo.AutomationTriggerBlocks (Id, TriggerId, BlockOrder, LogicalOperator)
    VALUES (@Block2Id, @Trigger2Id, 1, 'AND');

    INSERT INTO dbo.AutomationTriggerRules (TriggerBlockId, RuleOrder, FieldSource, FieldCode, Operator, Value)
    VALUES (@Block2Id, 1, 'DEFAULT', 'status', 'EQUALS', 'OPEN');

    INSERT INTO dbo.AutomationTriggerActions
        (TriggerId, ActionOrder, ActionType, ActionValue, ExecutionTarget, TargetField)
    VALUES (@Trigger2Id, 1, 'SET_STATUS', '{"status": "PENDING"}', 'AUTOMATION', 'status');
END;

-- 4.3 Trigger 3: Reopen Ticket on Customer Public Reply (PUBLIC_REPLY_ADDED, Priority 10)
DECLARE @Trigger3Id UNIQUEIDENTIFIER;
SELECT TOP 1 @Trigger3Id = Id FROM dbo.AutomationTriggers WHERE Name = 'Reopen Ticket On Customer Reply';

IF @Trigger3Id IS NULL
BEGIN
    SET @Trigger3Id = NEWID();
    INSERT INTO dbo.AutomationTriggers (Id, Name, Description, EventType, Priority, IsActive)
    VALUES (@Trigger3Id, 'Reopen Ticket On Customer Reply', 'Reopen ticket when customer adds public reply', 'PUBLIC_REPLY_ADDED', 10, 1);

    DECLARE @Block3Id UNIQUEIDENTIFIER = NEWID();
    INSERT INTO dbo.AutomationTriggerBlocks (Id, TriggerId, BlockOrder, LogicalOperator)
    VALUES (@Block3Id, @Trigger3Id, 1, 'AND');

    INSERT INTO dbo.AutomationTriggerRules (TriggerBlockId, RuleOrder, FieldSource, FieldCode, Operator, Value)
    VALUES 
        (@Block3Id, 1, 'EVENT', 'actorType', 'EQUALS', 'CUSTOMER'),
        (@Block3Id, 2, 'DEFAULT', 'status', 'EQUALS', 'PENDING');

    INSERT INTO dbo.AutomationTriggerActions
        (TriggerId, ActionOrder, ActionType, ActionValue, ExecutionTarget, TargetField)
    VALUES 
        (@Trigger3Id, 1, 'SET_STATUS', '{"status": "OPEN"}', 'AUTOMATION', 'status'),
        (@Trigger3Id, 2, 'ADD_NOTE', '{"body": "Reopened automatically following customer reply."}', 'APPLICATION', NULL);
END;

-- 4.4 Trigger 4: Auto-Close Inactive Pending Tickets (TIME_TRIGGER, Priority 10)
DECLARE @Trigger4Id UNIQUEIDENTIFIER;
SELECT TOP 1 @Trigger4Id = Id FROM dbo.AutomationTriggers WHERE Name = 'Auto-Close Inactive Pending Tickets';

IF @Trigger4Id IS NULL
BEGIN
    SET @Trigger4Id = NEWID();
    INSERT INTO dbo.AutomationTriggers (Id, Name, Description, EventType, Priority, IsActive)
    VALUES (@Trigger4Id, 'Auto-Close Inactive Pending Tickets', 'Close tickets pending for over 24 hours', 'TIME_TRIGGER', 10, 1);

    DECLARE @Block4Id UNIQUEIDENTIFIER = NEWID();
    INSERT INTO dbo.AutomationTriggerBlocks (Id, TriggerId, BlockOrder, LogicalOperator)
    VALUES (@Block4Id, @Trigger4Id, 1, 'AND');

    INSERT INTO dbo.AutomationTriggerRules (TriggerBlockId, RuleOrder, FieldSource, FieldCode, Operator, Value)
    VALUES 
        (@Block4Id, 1, 'DEFAULT', 'status', 'EQUALS', 'PENDING'),
        (@Block4Id, 2, 'DEFAULT', 'hoursSinceStatusChanged', 'GREATER_THAN', '24');

    INSERT INTO dbo.AutomationTriggerActions
        (TriggerId, ActionOrder, ActionType, ActionValue, ExecutionTarget, TargetField)
    VALUES 
        (@Trigger4Id, 1, 'SET_STATUS', '{"status": "CLOSED"}', 'AUTOMATION', 'status'),
        (@Trigger4Id, 2, 'SEND_EMAIL', '{"to": "{{ticket.requesterEmail}}", "template": "ticket_closed_notice"}', 'APPLICATION', NULL);
END;

-- 4.5 Trigger 5 & 6: Cascade Loop Test Triggers (TICKET_UPDATED)
DECLARE @Trigger5Id UNIQUEIDENTIFIER;
SELECT TOP 1 @Trigger5Id = Id FROM dbo.AutomationTriggers WHERE Name = 'Cascade Loop Ping';

IF @Trigger5Id IS NULL
BEGIN
    SET @Trigger5Id = NEWID();
    INSERT INTO dbo.AutomationTriggers (Id, Name, Description, EventType, Priority, IsActive)
    VALUES (@Trigger5Id, 'Cascade Loop Ping', 'Transitions WAITING_FOR_COACH to WAITING_FOR_WLB', 'TICKET_UPDATED', 10, 1);

    DECLARE @Block5Id UNIQUEIDENTIFIER = NEWID();
    INSERT INTO dbo.AutomationTriggerBlocks (Id, TriggerId, BlockOrder, LogicalOperator)
    VALUES (@Block5Id, @Trigger5Id, 1, 'AND');

    INSERT INTO dbo.AutomationTriggerRules (TriggerBlockId, RuleOrder, FieldSource, FieldCode, Operator, Value)
    VALUES (@Block5Id, 1, 'DEFAULT', 'status', 'CHANGED_TO', 'WAITING_FOR_COACH');

    INSERT INTO dbo.AutomationTriggerActions
        (TriggerId, ActionOrder, ActionType, ActionValue, ExecutionTarget, TargetField)
    VALUES (@Trigger5Id, 1, 'SET_STATUS', '{"status": "WAITING_FOR_WLB"}', 'AUTOMATION', 'status');
END
ELSE
BEGIN
    UPDATE dbo.AutomationTriggerRules SET Value = 'WAITING_FOR_COACH' WHERE TriggerBlockId IN (SELECT Id FROM dbo.AutomationTriggerBlocks WHERE TriggerId = @Trigger5Id);
    UPDATE dbo.AutomationTriggerActions
    SET ActionValue = '{"status": "WAITING_FOR_WLB"}', ExecutionTarget = 'AUTOMATION', TargetField = 'status'
    WHERE TriggerId = @Trigger5Id;
END;

DECLARE @Trigger6Id UNIQUEIDENTIFIER;
SELECT TOP 1 @Trigger6Id = Id FROM dbo.AutomationTriggers WHERE Name = 'Cascade Loop Pong';

IF @Trigger6Id IS NULL
BEGIN
    SET @Trigger6Id = NEWID();
    INSERT INTO dbo.AutomationTriggers (Id, Name, Description, EventType, Priority, IsActive)
    VALUES (@Trigger6Id, 'Cascade Loop Pong', 'Transitions WAITING_FOR_WLB to WAITING_FOR_COACH', 'TICKET_UPDATED', 10, 1);

    DECLARE @Block6Id UNIQUEIDENTIFIER = NEWID();
    INSERT INTO dbo.AutomationTriggerBlocks (Id, TriggerId, BlockOrder, LogicalOperator)
    VALUES (@Block6Id, @Trigger6Id, 1, 'AND');

    INSERT INTO dbo.AutomationTriggerRules (TriggerBlockId, RuleOrder, FieldSource, FieldCode, Operator, Value)
    VALUES (@Block6Id, 1, 'DEFAULT', 'status', 'CHANGED_TO', 'WAITING_FOR_WLB');

    INSERT INTO dbo.AutomationTriggerActions
        (TriggerId, ActionOrder, ActionType, ActionValue, ExecutionTarget, TargetField)
    VALUES (@Trigger6Id, 1, 'SET_STATUS', '{"status": "WAITING_FOR_COACH"}', 'AUTOMATION', 'status');
END
ELSE
BEGIN
    UPDATE dbo.AutomationTriggerRules SET Value = 'WAITING_FOR_WLB' WHERE TriggerBlockId IN (SELECT Id FROM dbo.AutomationTriggerBlocks WHERE TriggerId = @Trigger6Id);
    UPDATE dbo.AutomationTriggerActions
    SET ActionValue = '{"status": "WAITING_FOR_COACH"}', ExecutionTarget = 'AUTOMATION', TargetField = 'status'
    WHERE TriggerId = @Trigger6Id;
END;

-- Normalize rows from installations that previously ran the v1 draft seed before ExecutionTarget
-- and TargetField existed. This changes configuration only; dispatched ActionValue snapshots remain
-- immutable.
UPDATE dbo.AutomationTriggerActions
SET ExecutionTarget = CASE
        WHEN ActionType IN ('SET_STATUS', 'SET_PRIORITY', 'SET_GROUP', 'ASSIGN_GROUP', 'SET_AGENT', 'ASSIGN_AGENT',
                            'SET_TYPE', 'SET_DUE_DATE', 'SET_CUSTOM_FIELD') THEN 'AUTOMATION'
        ELSE 'APPLICATION'
    END,
    TargetField = CASE ActionType
        WHEN 'SET_STATUS' THEN 'status'
        WHEN 'SET_PRIORITY' THEN 'priority'
        WHEN 'SET_GROUP' THEN 'groupId'
        WHEN 'ASSIGN_GROUP' THEN 'groupId'
        WHEN 'SET_AGENT' THEN 'assignedAgentId'
        WHEN 'ASSIGN_AGENT' THEN 'assignedAgentId'
        WHEN 'SET_TYPE' THEN 'typeOptionId'
        WHEN 'SET_DUE_DATE' THEN 'dueDate'
        ELSE TargetField
    END;
GO

PRINT 'Seed data inserted successfully.';
GO
