-- =================================================================================================
-- OneDesk Automation v1.0 - Phase 4: Business Calendar Resolution SP
-- =================================================================================================
USE OneDeskDb;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.ganymede_businessCalendarResolve
    @BusinessCalendarId UNIQUEIDENTIFIER = NULL,
    @CheckTimeUtc DATETIMEOFFSET = NULL,
    @ResolvedCalendarId UNIQUEIDENTIFIER = NULL OUTPUT,
    @IsBusinessHour BIT = 0 OUTPUT,
    @IsHoliday BIT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Default time to current UTC time if not supplied
    IF @CheckTimeUtc IS NULL
    BEGIN
        SET @CheckTimeUtc = SYSUTCDATETIME() AT TIME ZONE 'UTC';
    END;

    -- Resolve Calendar
    DECLARE @CalendarId UNIQUEIDENTIFIER = @BusinessCalendarId;
    DECLARE @Timezone VARCHAR(50) = 'UTC';

    IF @CalendarId IS NOT NULL
    BEGIN
        SELECT TOP 1 
            @CalendarId = Id,
            @Timezone = ISNULL(Timezone, 'UTC')
        FROM dbo.BusinessCalendars WITH (NOLOCK)
        WHERE Id = @CalendarId AND IsActive = 1;
    END;

    -- If not specified or not found, resolve to default active calendar
    IF @CalendarId IS NULL
    BEGIN
        SELECT TOP 1 
            @CalendarId = Id,
            @Timezone = ISNULL(Timezone, 'UTC')
        FROM dbo.BusinessCalendars WITH (NOLOCK)
        WHERE IsDefault = 1 AND IsActive = 1;
    END;

    -- If still no default found, fall back to any active calendar
    IF @CalendarId IS NULL
    BEGIN
        SELECT TOP 1 
            @CalendarId = Id,
            @Timezone = ISNULL(Timezone, 'UTC')
        FROM dbo.BusinessCalendars WITH (NOLOCK)
        WHERE IsActive = 1
        ORDER BY CreatedAt ASC;
    END;

    SET @ResolvedCalendarId = @CalendarId;

    -- If no calendar exists in the system at all, assume 24x7 normal business hour, not holiday
    IF @CalendarId IS NULL
    BEGIN
        SET @IsBusinessHour = 1;
        SET @IsHoliday = 0;

        SELECT 
            @ResolvedCalendarId AS CalendarId, 
            @IsBusinessHour AS IsBusinessHour, 
            @IsHoliday AS IsHoliday;
        RETURN;
    END;

    -- Validate timezone exists in system; fallback to UTC if not
    IF NOT EXISTS (SELECT 1 FROM sys.time_zone_info WHERE name = @Timezone)
    BEGIN
        SET @Timezone = 'UTC';
    END;

    -- Convert check time to calendar local time
    DECLARE @LocalTime DATETIMEOFFSET;
    SET @LocalTime = @CheckTimeUtc AT TIME ZONE @Timezone;

    DECLARE @LocalDate DATE = CAST(@LocalTime AS DATE);
    DECLARE @LocalTimeOfDay TIME(0) = CAST(@LocalTime AS TIME(0));

    -- Calculate normalized DayOfWeek: 1=Sunday, 2=Monday, ..., 7=Saturday
    -- Deterministic regardless of @@DATEFIRST setting
    DECLARE @DayOfWeek TINYINT;
    SET @DayOfWeek = ((DATEPART(dw, @LocalDate) + @@DATEFIRST - 2) % 7) + 1;

    -- Check if date is a configured Holiday
    IF EXISTS (
        SELECT 1 
        FROM dbo.BusinessCalendarHolidays WITH (NOLOCK)
        WHERE CalendarId = @CalendarId
          AND HolidayDate = @LocalDate
    )
    BEGIN
        SET @IsHoliday = 1;
        SET @IsBusinessHour = 0;
    END
    ELSE
    BEGIN
        SET @IsHoliday = 0;

        -- Check if day & time fall within working schedule
        IF EXISTS (
            SELECT 1 
            FROM dbo.BusinessCalendarSchedules WITH (NOLOCK)
            WHERE CalendarId = @CalendarId
              AND DayOfWeek = @DayOfWeek
              AND IsWorkingDay = 1
              AND @LocalTimeOfDay >= StartTime
              AND @LocalTimeOfDay < EndTime
        )
        BEGIN
            SET @IsBusinessHour = 1;
        END
        ELSE
        BEGIN
            SET @IsBusinessHour = 0;
        END;
    END;

    -- Return result set only for top-level callers executing as a query
    IF @@NESTLEVEL = 1
    BEGIN
        SELECT 
            @ResolvedCalendarId AS CalendarId, 
            @IsBusinessHour AS IsBusinessHour, 
            @IsHoliday AS IsHoliday;
    END;
END;
GO
