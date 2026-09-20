-- =================================================================================================
-- OneDesk Automation v1.0 - Phase 2: Ticket Activity Integration SPs
-- =================================================================================================
USE OneDeskDb;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- -------------------------------------------------------------------------------------------------
-- 1. ganymede_ticketActivityLogCreateForCreatedTicket (Updated to accept @AutomationExecutionId)
-- -------------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.ganymede_ticketActivityLogCreateForCreatedTicket
    @TicketId UNIQUEIDENTIFIER,
    @ActorId UNIQUEIDENTIFIER,
    @AutomationExecutionId UNIQUEIDENTIFIER = NULL,
    @OperationId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TicketSnapshot NVARCHAR(MAX);
    DECLARE @ActivityOperationId UNIQUEIDENTIFIER = COALESCE(@OperationId, NEWID());

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.Tickets AS ticket
        WHERE ticket.Id = @TicketId
          AND ticket.IsDeleted = 0
    )
    BEGIN
        SELECT 16 AS ErrorCode, 'TICKET_NOT_FOUND' AS ErrorMessage;
        RETURN;
    END;

    -- User-facing reads must filter this column.  The evaluator/action finalizer changes it back to
    -- READY after every directly selected TICKET_CREATED execution reaches a terminal state.
    UPDATE dbo.Tickets
    SET CreateAutomationStatus = CASE
        WHEN EXISTS
        (
            SELECT 1
            FROM dbo.AutomationTriggers
            WHERE EventType = 'TICKET_CREATED' AND IsActive = 1
        ) THEN 'PENDING'
        ELSE 'READY'
    END
    WHERE Id = @TicketId;

    SELECT @TicketSnapshot =
    (
        SELECT
            ticket.TicketNo AS TicketNo,
            ticket.Subject AS Subject,
            ticket.Status AS Status,
            ticket.Priority AS Priority,
            ticket.Source AS Source
        FROM dbo.Tickets AS ticket
        WHERE ticket.Id = @TicketId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    );

    INSERT INTO dbo.TicketActivityLogs
    (
        TicketId,
        Event,
        ActorType,
        ActorId,
        OldValue,
        NewValue,
        Description,
        PlainDescription,
        AutomationExecutionId,
        OperationId,
        CreatedAt
    )
    VALUES
    (
        @TicketId,
        'TICKET_CREATED',
        'AGENT',
        @ActorId,
        NULL,
        @TicketSnapshot,
        'Ticket created',
        'Ticket created',
        @AutomationExecutionId,
        @ActivityOperationId,
        (SYSUTCDATETIME() AT TIME ZONE 'UTC')
    );

    INSERT INTO dbo.TicketActivityLogs
    (
        TicketId,
        Event,
        ActorType,
        ActorId,
        TicketMessageId,
        OldValue,
        NewValue,
        Description,
        PlainDescription,
        AutomationExecutionId,
        OperationId,
        CreatedAt
    )
    SELECT
        message.TicketId AS TicketId,
        'INITIAL_MESSAGE_ADDED',
        message.AuthorType AS AuthorType,
        message.AuthorId AS AuthorId,
        message.Id AS Id,
        NULL,
        (
            SELECT message.Body, message.PlainBody
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        ),
        'Initial message added',
        'Initial message added',
        @AutomationExecutionId,
        @ActivityOperationId,
        (SYSUTCDATETIME() AT TIME ZONE 'UTC')
    FROM dbo.TicketMessages AS message
    WHERE message.TicketId = @TicketId
      AND message.MessageType = 'INITIAL_MESSAGE'
      AND message.IsDeleted = 0;

    INSERT INTO dbo.TicketActivityLogs
    (
        TicketId,
        Event,
        ActorType,
        ActorId,
        TicketFieldId,
        OldValue,
        NewValue,
        Description,
        PlainDescription,
        AutomationExecutionId,
        OperationId,
        CreatedAt
    )
    SELECT
        FieldValue.TicketId AS TicketId,
        'FIELD_VALUE_CREATED',
        'AGENT',
        @ActorId,
        FieldValue.TicketFieldId AS TicketFieldId,
        NULL,
        (
            SELECT
                field.FieldCode AS FieldCode,
                FieldValue.SelectedOptionId AS SelectedOptionId,
                FieldValue.TextValue AS TextValue,
                FieldValue.NumberValue AS NumberValue,
                FieldValue.DecimalValue AS DecimalValue,
                FieldValue.DateValue AS DateValue,
                FieldValue.BooleanValue AS BooleanValue
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        ),
        'Ticket field value created',
        'Ticket field value created',
        @AutomationExecutionId,
        @ActivityOperationId,
        (SYSUTCDATETIME() AT TIME ZONE 'UTC')
    FROM dbo.TicketFieldValues AS FieldValue
    INNER JOIN dbo.TicketFields AS field
        ON field.Id = FieldValue.TicketFieldId
    WHERE FieldValue.TicketId = @TicketId;

    SELECT 0 AS ErrorCode, '' AS ErrorMessage;
END;
GO

-- -------------------------------------------------------------------------------------------------
-- 2. ganymede_ticketActivityLogCreateForPublicReply (Updated to accept @AutomationExecutionId)
-- -------------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.ganymede_ticketActivityLogCreateForPublicReply
    @TicketId UNIQUEIDENTIFIER,
    @TicketMessageId UNIQUEIDENTIFIER,
    @ActorId UNIQUEIDENTIFIER,
    @AutomationExecutionId UNIQUEIDENTIFIER = NULL,
    @OperationId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ErrorCode INT = 0;
    DECLARE @ErrorMessage VARCHAR(100) = '';
    DECLARE @MessageBody NVARCHAR(MAX);
    DECLARE @MessagePlainBody NVARCHAR(MAX);
    DECLARE @AuthorType VARCHAR(20) = 'AGENT';
    DECLARE @FoundMessageId UNIQUEIDENTIFIER;
    DECLARE @NewValue NVARCHAR(MAX);

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.Tickets AS ticket
        WHERE ticket.Id = @TicketId
          AND ticket.IsDeleted = 0
    )
    BEGIN
        SET @ErrorCode = 16;
        SET @ErrorMessage = 'TICKET_NOT_FOUND';
    END;

    IF @ErrorCode = 0
    BEGIN
        SELECT
            @FoundMessageId = message.Id,
            @MessageBody = message.Body,
            @MessagePlainBody = message.PlainBody,
            @AuthorType = ISNULL(message.AuthorType, 'AGENT')
        FROM dbo.TicketMessages AS message
        WHERE message.Id = @TicketMessageId
          AND message.TicketId = @TicketId
          AND message.MessageType = 'CONVERSATION_REPLY'
          AND message.Visibility = 'PUBLIC'
          AND message.IsDeleted = 0;

        IF @FoundMessageId IS NULL
        BEGIN
            SET @ErrorCode = 16;
            SET @ErrorMessage = 'TICKET_NOT_FOUND';
        END;
    END;

    IF @ErrorCode = 0
    BEGIN
        SELECT @NewValue =
        (
            SELECT
                @MessageBody AS Body,
                @MessagePlainBody AS PlainBody
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        INSERT INTO dbo.TicketActivityLogs
        (
            TicketId,
            Event,
            ActorType,
            ActorId,
            TicketMessageId,
            OldValue,
            NewValue,
            Description,
            PlainDescription,
            AutomationExecutionId,
            OperationId,
            CreatedAt
        )
        VALUES
        (
            @TicketId,
            'PUBLIC_REPLY_ADDED',
            @AuthorType,
            @ActorId,
            @TicketMessageId,
            NULL,
            @NewValue,
            'Public reply added',
            'Public reply added',
            @AutomationExecutionId,
            COALESCE(@OperationId, NEWID()),
            (SYSUTCDATETIME() AT TIME ZONE 'UTC')
        );

    END;

    SELECT
        @ErrorCode AS ErrorCode,
        @ErrorMessage AS ErrorMessage;
END;
GO

-- -------------------------------------------------------------------------------------------------
-- 3. ganymede_ticketActivityLogCreateForNote (Updated to accept @AutomationExecutionId)
-- -------------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.ganymede_ticketActivityLogCreateForNote
    @TicketId UNIQUEIDENTIFIER,
    @TicketMessageId UNIQUEIDENTIFIER,
    @ActorId UNIQUEIDENTIFIER,
    @AutomationExecutionId UNIQUEIDENTIFIER = NULL,
    @OperationId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ErrorCode INT = 0;
    DECLARE @ErrorMessage VARCHAR(100) = '';
    DECLARE @MessageBody NVARCHAR(MAX);
    DECLARE @MessagePlainBody NVARCHAR(MAX);
    DECLARE @MessageType VARCHAR(30);
    DECLARE @FoundMessageId UNIQUEIDENTIFIER;
    DECLARE @Event VARCHAR(50);
    DECLARE @Description NVARCHAR(MAX);
    DECLARE @NewValue NVARCHAR(MAX);

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.Tickets AS ticket
        WHERE ticket.Id = @TicketId
          AND ticket.IsDeleted = 0
    )
    BEGIN
        SET @ErrorCode = 16;
        SET @ErrorMessage = 'TICKET_NOT_FOUND';
    END;

    IF @ErrorCode = 0
    BEGIN
        SELECT
            @FoundMessageId = message.Id,
            @MessageBody = message.Body,
            @MessagePlainBody = message.PlainBody,
            @MessageType = message.MessageType
        FROM dbo.TicketMessages AS message
        WHERE message.Id = @TicketMessageId
          AND message.TicketId = @TicketId
          AND message.MessageType IN ('PUBLIC_NOTE', 'INTERNAL_NOTE')
          AND message.IsDeleted = 0;

        IF @FoundMessageId IS NULL
        BEGIN
            SET @ErrorCode = 16;
            SET @ErrorMessage = 'TICKET_NOT_FOUND';
        END;
    END;

    IF @ErrorCode = 0
    BEGIN
        SET @Event = CASE
                         WHEN @MessageType = 'PUBLIC_NOTE' THEN 'PUBLIC_NOTE_ADDED'
                         ELSE 'INTERNAL_NOTE_ADDED'
                     END;
        SET @Description = CASE
                               WHEN @MessageType = 'PUBLIC_NOTE' THEN 'Public note added'
                               ELSE 'Internal note added'
                           END;

        SELECT @NewValue =
        (
            SELECT
                @MessageBody AS Body,
                @MessagePlainBody AS PlainBody,
                @MessageType AS MessageType
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        INSERT INTO dbo.TicketActivityLogs
        (
            TicketId,
            Event,
            ActorType,
            ActorId,
            TicketMessageId,
            OldValue,
            NewValue,
            Description,
            PlainDescription,
            AutomationExecutionId,
            OperationId,
            CreatedAt
        )
        VALUES
        (
            @TicketId,
            @Event,
            'AGENT',
            @ActorId,
            @TicketMessageId,
            NULL,
            @NewValue,
            @Description,
            @Description,
            @AutomationExecutionId,
            COALESCE(@OperationId, NEWID()),
            (SYSUTCDATETIME() AT TIME ZONE 'UTC')
        );

    END;

    SELECT
        @ErrorCode AS ErrorCode,
        @ErrorMessage AS ErrorMessage;
END;
GO

-- -------------------------------------------------------------------------------------------------
-- 4. ganymede_ticketActivityLogCreateForUpdatedTicket (New SP for Property Changes)
-- -------------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.ganymede_ticketActivityLogCreateForUpdatedTicket
    @TicketId UNIQUEIDENTIFIER,
    @ActorId UNIQUEIDENTIFIER = NULL,
    @ActorType VARCHAR(20) = 'AGENT',
    @OldValuesJson NVARCHAR(MAX) = NULL,
    @NewValuesJson NVARCHAR(MAX) = NULL,
    @Description NVARCHAR(MAX) = 'Ticket updated',
    @PlainDescription NVARCHAR(MAX) = 'Ticket updated',
    @AutomationExecutionId UNIQUEIDENTIFIER = NULL,
    @OperationId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.Tickets AS ticket
        WHERE ticket.Id = @TicketId
          AND ticket.IsDeleted = 0
    )
    BEGIN
        SELECT 16 AS ErrorCode, 'TICKET_NOT_FOUND' AS ErrorMessage;
        RETURN;
    END;

    IF (@OldValuesJson IS NOT NULL AND ISJSON(@OldValuesJson) = 0)
       OR (@NewValuesJson IS NOT NULL AND ISJSON(@NewValuesJson) = 0)
    BEGIN
        SELECT 16 AS ErrorCode, 'INVALID_ACTIVITY_JSON' AS ErrorMessage;
        RETURN;
    END;

    INSERT INTO dbo.TicketActivityLogs
    (
        TicketId,
        Event,
        ActorType,
        ActorId,
        OldValue,
        NewValue,
        Description,
        PlainDescription,
        AutomationExecutionId,
        OperationId,
        CreatedAt
    )
    VALUES
    (
        @TicketId,
        'TICKET_UPDATED',
        ISNULL(@ActorType, 'AGENT'),
        @ActorId,
        @OldValuesJson,
        @NewValuesJson,
        ISNULL(@Description, 'Ticket updated'),
        ISNULL(@PlainDescription, 'Ticket updated'),
        @AutomationExecutionId,
        COALESCE(@OperationId, NEWID()),
        (SYSUTCDATETIME() AT TIME ZONE 'UTC')
    );

    SELECT 0 AS ErrorCode, '' AS ErrorMessage;
END;
GO
