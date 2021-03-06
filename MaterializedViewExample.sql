/*
MIT License

Copyright (c) 2018 codexguy

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

For more details on the usage of this script, visit www.xskrape.com
and the article at: https://www.xskrape.com/home/article/Merging-Data-with-Ease
and at: https://www.c-sharpcorner.com/article/using-materialized-views-effectively/
*/

IF NOT EXISTS (SELECT 0 FROM sys.schemas s WHERE s.name = 'Source')
	EXEC ('CREATE SCHEMA [Source] AUTHORIZATION dbo')
GO

IF NOT EXISTS (SELECT 0 FROM sys.schemas s WHERE s.name = 'Dest')
	EXEC ('CREATE SCHEMA [Dest] AUTHORIZATION dbo')
GO

IF OBJECT_ID('Source.Event') IS NOT NULL
	DROP TABLE [Source].[Event]
GO

IF OBJECT_ID('Source.EventType') IS NOT NULL
	DROP TABLE [Source].[EventType]
GO

IF OBJECT_ID('[Dest].[WidgetLatestState]') IS NOT NULL
	DROP TABLE [Dest].[WidgetLatestState]
GO

CREATE TABLE [Source].[EventType] (
EventTypeID tinyint NOT NULL IDENTITY PRIMARY KEY,
EventTypeCode varchar(20) NOT NULL,
EventTypeDesc varchar(100) NOT NULL)
GO

INSERT [Source].[EventType] (EventTypeCode, EventTypeDesc) VALUES ('ARRIVE', 'Widget Arrival');
INSERT [Source].[EventType] (EventTypeCode, EventTypeDesc) VALUES ('CAN_ARRIVE', 'Cancel Widget Arrival');
INSERT [Source].[EventType] (EventTypeCode, EventTypeDesc) VALUES ('LEAVE', 'Widget Depart');
INSERT [Source].[EventType] (EventTypeCode, EventTypeDesc) VALUES ('CAN_LEAVE', 'Cancel Widget Depart');
GO

CREATE TABLE [Source].[Event] (
WidgetID int NOT NULL,
EventTypeID tinyint NOT NULL REFERENCES [Source].[EventType] (EventTypeID),
TripID int NOT NULL,
EventDate datetime NOT NULL,
PRIMARY KEY (WidgetID, EventTypeID, EventDate, TripID))
GO

CREATE INDEX IDX_Event_Date ON [Source].[Event] (EventDate, EventTypeID) INCLUDE (WidgetID)
GO
CREATE INDEX IDX_Event_Widget ON [Source].[Event] (WidgetID, TripID, EventDate) INCLUDE (EventTypeID)
GO
CREATE INDEX IDX_Event_Trip ON [Source].[Event] (TripID, WidgetID)
GO

CREATE TABLE [Dest].[WidgetLatestState] (
WidgetID int NOT NULL PRIMARY KEY,
LastTripID int NOT NULL,
LastEventDate datetime NOT NULL,
ArrivalDate datetime NOT NULL,
DepartureDate datetime NULL)
GO

CREATE INDEX IDX_WidgetLatestState_LastTrip ON [Dest].[WidgetLatestState] (LastTripID)
GO
CREATE INDEX IDX_WidgetLatestState_Arrival ON [Dest].[WidgetLatestState] (ArrivalDate)
GO
CREATE INDEX IDX_WidgetLatestState_Departure ON [Dest].[WidgetLatestState] (DepartureDate)
GO

IF OBJECT_ID('[Dest].[uv_WidgetLatestState]') IS NOT NULL
	DROP VIEW [Dest].[uv_WidgetLatestState]
GO

CREATE VIEW [Dest].[uv_WidgetLatestState]
AS
SELECT
	lw.WidgetID
	, la.LastTripID
	, lw.LastEventDate
	, la.ArrivalDate
	, (SELECT MAX(de.EventDate)
		FROM [Source].[Event] de
		WHERE de.EventTypeID = 3
		AND de.WidgetID = lw.WidgetID
		AND de.TripID = la.LastTripID
		AND NOT EXISTS
			(SELECT 0
			FROM [Source].[Event] dc
			WHERE lw.WidgetID = dc.WidgetID
			AND la.LastTripID = dc.TripID
			AND dc.EventTypeID = 4
			AND dc.EventDate > de.EventDate)) AS DepartureDate
FROM
	(SELECT
		e.WidgetID
		, MAX(e.EventDate) AS LastEventDate
	FROM
		[Source].[Event] e
	GROUP BY
		e.WidgetID) lw
	LEFT OUTER JOIN
	(SELECT
		ae.WidgetID
		, ae.TripID AS LastTripID
		, ae.EventDate AS ArrivalDate
	FROM
		[Source].[Event] ae
	WHERE
		ae.EventTypeID = 1
	AND	ae.EventDate =
		(SELECT MAX(la.EventDate)
		FROM [Source].[Event] la
		WHERE la.EventTypeID = 1
		AND la.WidgetID = ae.WidgetID
		AND NOT EXISTS
			(SELECT 0
			FROM [Source].[Event] ac
			WHERE la.WidgetID = ac.WidgetID
			AND la.TripID = ac.TripID
			AND ac.EventTypeID = 2
			AND ac.EventDate > la.EventDate))) AS la ON lw.WidgetID = la.WidgetID
GO

TRUNCATE TABLE [Source].[Event]
GO

-- Populate with 2.15 million pseudo-random events
-- TODO: change filename to match the location of downloaded file from GitHub
BULK INSERT [Source].[Event] FROM 'C:\Source\xSkrape\Articles\CEF\MergingDataMaterializedViews\Event20180903-1336.dat' WITH ( DATAFILETYPE = 'NATIVE' );

-- Baseline: truncate/insert
DECLARE @start datetime2;
SET @start = SYSDATETIME();

TRUNCATE TABLE [Dest].[WidgetLatestState];

INSERT [Dest].[WidgetLatestState] (
	WidgetID
	, LastTripID
	, LastEventDate
	, ArrivalDate
	, DepartureDate
	)
SELECT
	WidgetID
	, LastTripID
	, LastEventDate
	, ArrivalDate
	, DepartureDate
FROM
	[Dest].[uv_WidgetLatestState]
WHERE
	LastTripID IS NOT NULL;

PRINT @@ROWCOUNT;
PRINT 'TRUNCATE/INSERT elapsed: ' + STR(DATEDIFF(ms, @start, SYSDATETIME()));

-- MERGE of entire view
SET @start = SYSDATETIME();

MERGE [Dest].[WidgetLatestState] AS a
 USING (
 SELECT
   v.[WidgetID]
	, v.[LastTripID]
	, v.[LastEventDate]
	, v.[ArrivalDate]
	, v.[DepartureDate]
 FROM
   [Dest].[uv_WidgetLatestState] v
 ) AS T
 ON
 (
   a.[WidgetID] = t.[WidgetID]
 )

WHEN MATCHED AND t.ArrivalDate IS NOT NULL THEN
     UPDATE
      SET LastTripID = t.LastTripID
	, LastEventDate = t.LastEventDate
	, ArrivalDate = t.ArrivalDate
	, DepartureDate = t.DepartureDate

WHEN NOT MATCHED BY TARGET AND t.ArrivalDate IS NOT NULL THEN
      INSERT (
        WidgetID
	, LastTripID
	, LastEventDate
	, ArrivalDate
	, DepartureDate
      ) VALUES (
        t.[WidgetID]
	, t.[LastTripID]
	, t.[LastEventDate]
	, t.[ArrivalDate]
	, t.[DepartureDate]
      )

WHEN MATCHED AND t.ArrivalDate IS NULL THEN
     DELETE;

PRINT @@ROWCOUNT;
PRINT 'Bare MERGE elapsed: ' + STR(DATEDIFF(ms, @start, SYSDATETIME()));

-- MERGE of entire view
SET @start = SYSDATETIME();

MERGE [Dest].[WidgetLatestState] AS a
 USING (
 SELECT
   v.[WidgetID]
	, v.[LastTripID]
	, v.[LastEventDate]
	, v.[ArrivalDate]
	, v.[DepartureDate]
 FROM
   [Dest].[uv_WidgetLatestState] v
 ) AS T
 ON
 (
   a.[WidgetID] = t.[WidgetID]
 )

WHEN MATCHED 
	 AND t.ArrivalDate IS NOT NULL
     AND ((a.[LastTripID] <> CONVERT(int, t.[LastTripID]))
          OR (a.[LastEventDate] <> CONVERT(datetime, t.[LastEventDate]))
          OR (a.[ArrivalDate] <> CONVERT(datetime, t.[ArrivalDate]))
          OR (a.[DepartureDate] <> CONVERT(datetime, t.[DepartureDate]) OR (a.[DepartureDate] IS NULL AND t.[DepartureDate] IS NOT NULL) OR (a.[DepartureDate] IS NOT NULL AND t.[DepartureDate] IS NULL))) THEN
     UPDATE
      SET LastTripID = t.LastTripID
	, LastEventDate = t.LastEventDate
	, ArrivalDate = t.ArrivalDate
	, DepartureDate = t.DepartureDate

WHEN NOT MATCHED BY TARGET AND t.ArrivalDate IS NOT NULL THEN
      INSERT (
        WidgetID
	, LastTripID
	, LastEventDate
	, ArrivalDate
	, DepartureDate
      ) VALUES (
        t.[WidgetID]
	, t.[LastTripID]
	, t.[LastEventDate]
	, t.[ArrivalDate]
	, t.[DepartureDate]
      )

WHEN MATCHED AND t.ArrivalDate IS NULL THEN
     DELETE;

PRINT @@ROWCOUNT;
PRINT 'No material change MERGE elapsed: ' + STR(DATEDIFF(ms, @start, SYSDATETIME()));

-- Use of a control date filter with MERGE
DECLARE @lastprocessed datetime2;
SELECT @lastprocessed = MAX(e.EventDate) FROM [Source].[Event] e;
SET @start = SYSDATETIME();

MERGE [Dest].[WidgetLatestState] AS a
 USING (
 SELECT
   v.[WidgetID]
	, v.[LastTripID]
	, v.[LastEventDate]
	, v.[ArrivalDate]
	, v.[DepartureDate]
 FROM
   [Dest].[uv_WidgetLatestState] v
 WHERE
   v.LastEventDate > @lastprocessed
 ) AS T
 ON
 (
   a.[WidgetID] = t.[WidgetID]
 )

WHEN MATCHED 
	 AND t.ArrivalDate IS NOT NULL
     AND t.LastEventDate > @lastprocessed AND ((a.[LastTripID] <> CONVERT(int, t.[LastTripID]))
          OR (a.[LastEventDate] <> CONVERT(datetime, t.[LastEventDate]))
          OR (a.[ArrivalDate] <> CONVERT(datetime, t.[ArrivalDate]))
          OR (a.[DepartureDate] <> CONVERT(datetime, t.[DepartureDate]) OR (a.[DepartureDate] IS NULL AND t.[DepartureDate] IS NOT NULL) OR (a.[DepartureDate] IS NOT NULL AND t.[DepartureDate] IS NULL))) THEN
     UPDATE
      SET LastTripID = t.LastTripID
	, LastEventDate = t.LastEventDate
	, ArrivalDate = t.ArrivalDate
	, DepartureDate = t.DepartureDate

WHEN NOT MATCHED BY TARGET AND t.ArrivalDate IS NOT NULL THEN
      INSERT (
        WidgetID
	, LastTripID
	, LastEventDate
	, ArrivalDate
	, DepartureDate
      ) VALUES (
        t.[WidgetID]
	, t.[LastTripID]
	, t.[LastEventDate]
	, t.[ArrivalDate]
	, t.[DepartureDate]
      )

WHEN MATCHED AND t.ArrivalDate IS NULL THEN
     DELETE;

PRINT @@ROWCOUNT;
PRINT 'Control date, material changes only MERGE elapsed: ' + STR(DATEDIFF(ms, @start, SYSDATETIME()));
GO

IF OBJECT_ID('dbo.SystemParameter') IS NOT NULL
	DROP TABLE dbo.SystemParameter
GO

-- Stick control date in table, create a procedure that can use our best performing solution, over and over on a scheduled basis
CREATE TABLE dbo.SystemParameter
(KeyName varchar(100) NOT NULL PRIMARY KEY,
KeyValue varchar(1000) NULL)
GO

INSERT dbo.SystemParameter (KeyName, KeyValue) VALUES ('WidgetLastLoadDate', '1/1/1900');
GO

IF OBJECT_ID('Dest.up_WidgetLatestState_Load') IS NOT NULL
	DROP PROC Dest.up_WidgetLatestState_Load
GO

CREATE PROCEDURE Dest.up_WidgetLatestState_Load
AS
BEGIN

DECLARE @rc int;
DECLARE @start datetime2;
SET @start = SYSDATETIME();

DECLARE @lastprocessed datetime2;
SELECT @lastprocessed = KeyValue 
FROM dbo.SystemParameter
WHERE KeyName = 'WidgetLastLoadDate';

MERGE [Dest].[WidgetLatestState] AS a
 USING (
 SELECT
   v.[WidgetID]
	, v.[LastTripID]
	, v.[LastEventDate]
	, v.[ArrivalDate]
	, v.[DepartureDate]
 FROM
   [Dest].[uv_WidgetLatestState] v
 WHERE
   v.LastEventDate > @lastprocessed
 ) AS T
 ON
 (
   a.[WidgetID] = t.[WidgetID]
 )

WHEN MATCHED 
     AND t.ArrivalDate IS NOT NULL
     AND t.LastEventDate >= @lastprocessed AND ((a.[LastTripID] <> CONVERT(int, t.[LastTripID]))
          OR (a.[LastEventDate] <> CONVERT(datetime, t.[LastEventDate]))
          OR (a.[ArrivalDate] <> CONVERT(datetime, t.[ArrivalDate]))
          OR (a.[DepartureDate] <> CONVERT(datetime, t.[DepartureDate]) OR (a.[DepartureDate] IS NULL AND t.[DepartureDate] IS NOT NULL) OR (a.[DepartureDate] IS NOT NULL AND t.[DepartureDate] IS NULL))) THEN
     UPDATE
      SET LastTripID = t.LastTripID
	, LastEventDate = t.LastEventDate
	, ArrivalDate = t.ArrivalDate
	, DepartureDate = t.DepartureDate

WHEN NOT MATCHED BY TARGET AND t.ArrivalDate IS NOT NULL THEN
      INSERT (
        WidgetID
	, LastTripID
	, LastEventDate
	, ArrivalDate
	, DepartureDate
      ) VALUES (
        t.[WidgetID]
	, t.[LastTripID]
	, t.[LastEventDate]
	, t.[ArrivalDate]
	, t.[DepartureDate]
      )

WHEN MATCHED AND t.ArrivalDate IS NULL THEN
     DELETE;

SET @rc = @@ROWCOUNT;

UPDATE dbo.SystemParameter
SET KeyValue = CONVERT(varchar(100), @start)
WHERE KeyName = 'WidgetLastLoadDate';

PRINT 'In Proc, Control date, material changes only MERGE elapsed: ' + STR(DATEDIFF(ms, @start, SYSDATETIME()));
PRINT @rc;

END
GO

-- Try it out... first one slow since control date is far in past
EXEC Dest.up_WidgetLatestState_Load;

-- ... next time should be much, MUCH faster!
EXEC Dest.up_WidgetLatestState_Load;
GO

-- Let's add 50 new events
DECLARE @start datetime2;
SET @start = SYSDATETIME();

INSERT [Source].[Event] (
	[WidgetID]
	, [EventTypeID]
	, [TripID]
	, [EventDate] )
SELECT TOP 50
	e.[WidgetID]
	, 3
	, e.[TripID]
	, @start
FROM
	[Source].[Event] e
GROUP BY
	e.WidgetID, e.TripID
HAVING
	COUNT(*) = 1;

EXEC Dest.up_WidgetLatestState_Load;
GO

-- Test performance of query against materialed view versus source data (non-materialized view)
DECLARE @temp int;
DECLARE @start datetime2;
SET @start = SYSDATETIME();

SELECT @temp = COUNT(*)
FROM [Dest].[WidgetLatestState] w
WHERE w.DepartureDate IS NULL;

PRINT 'Onsite Count, using materialized view: ' + STR(DATEDIFF(ms, @start, SYSDATETIME()));
PRINT @temp;

SET @start = SYSDATETIME();

SELECT @temp = COUNT(*)
FROM [Dest].[uv_WidgetLatestState] w
WHERE w.DepartureDate IS NULL
AND w.ArrivalDate IS NOT NULL;

PRINT 'Onsite Count, using NON-materialized view: ' + STR(DATEDIFF(ms, @start, SYSDATETIME()));
PRINT @temp;
GO

/********************************************************************************************/
-- Queued approach changes

IF OBJECT_ID('[dbo].[WidgetLatestStateQueue]') IS NOT NULL
	DROP TABLE [dbo].[WidgetLatestStateQueue]
GO

CREATE TABLE [dbo].[WidgetLatestStateQueue]
(WidgetID int NOT NULL PRIMARY KEY)
GO

IF OBJECT_ID('dbo.up_WidgetLatestStateQueue_Populate') IS NOT NULL
	DROP PROC dbo.up_WidgetLatestStateQueue_Populate
GO

CREATE PROCEDURE dbo.up_WidgetLatestStateQueue_Populate
	@start datetime2 = NULL
AS
BEGIN
	SET NOCOUNT ON;
	PRINT CONVERT(varchar, GETDATE(), 114);

	IF @start IS NULL
		SET @start = DATEADD(dd, -1, SYSDATETIME());

	INSERT dbo.WidgetLatestStateQueue (WidgetID)
	SELECT DISTINCT e.WidgetID
	FROM 
		[Source].[Event] e
	WHERE
		e.EventDate >= @start
	AND NOT EXISTS (SELECT 0 FROM dbo.WidgetLatestStateQueue q WHERE e.WidgetID = q.WidgetID);

	PRINT CONVERT(varchar, GETDATE(), 114);
END
GO

IF OBJECT_ID('dbo.up_WidgetLatestStateQueue_ByID') IS NOT NULL
	DROP PROC dbo.up_WidgetLatestStateQueue_ByID
GO

CREATE PROCEDURE dbo.up_WidgetLatestStateQueue_ByID
	@WidgetID int
AS
BEGIN
	MERGE [Dest].[WidgetLatestState] AS a
	 USING (
	 SELECT
	   v.[WidgetID]
		, v.[LastTripID]
		, v.[LastEventDate]
		, v.[ArrivalDate]
		, v.[DepartureDate]
	 FROM
	   [Dest].[uv_WidgetLatestState] v
	 WHERE
	   v.WidgetID = @WidgetID
	 ) AS T
	 ON
	 (
	   a.[WidgetID] = t.[WidgetID]
	 )

	WHEN MATCHED 
		 AND t.ArrivalDate IS NOT NULL
		 AND ((a.[LastTripID] <> CONVERT(int, t.[LastTripID]))
			  OR (a.[LastEventDate] <> CONVERT(datetime, t.[LastEventDate]))
			  OR (a.[ArrivalDate] <> CONVERT(datetime, t.[ArrivalDate]))
			  OR (a.[DepartureDate] <> CONVERT(datetime, t.[DepartureDate]) OR (a.[DepartureDate] IS NULL AND t.[DepartureDate] IS NOT NULL) OR (a.[DepartureDate] IS NOT NULL AND t.[DepartureDate] IS NULL))) THEN
		 UPDATE
		  SET LastTripID = t.LastTripID
		, LastEventDate = t.LastEventDate
		, ArrivalDate = t.ArrivalDate
		, DepartureDate = t.DepartureDate

	WHEN NOT MATCHED BY TARGET AND t.ArrivalDate IS NOT NULL THEN
		  INSERT (
			WidgetID
		, LastTripID
		, LastEventDate
		, ArrivalDate
		, DepartureDate
		  ) VALUES (
			t.[WidgetID]
		, t.[LastTripID]
		, t.[LastEventDate]
		, t.[ArrivalDate]
		, t.[DepartureDate]
		  )

	WHEN MATCHED AND t.ArrivalDate IS NULL THEN
		 DELETE;
END
GO

IF OBJECT_ID('dbo.up_WidgetLatestStateQueue_Process') IS NOT NULL
	DROP PROC dbo.up_WidgetLatestStateQueue_Process
GO

CREATE PROCEDURE dbo.up_WidgetLatestStateQueue_Process
AS
BEGIN
	SET NOCOUNT ON;
	PRINT CONVERT(varchar, GETDATE(), 114);

	DECLARE @WidgetID int;
	SELECT TOP 1 @WidgetID = WidgetID FROM dbo.WidgetLatestStateQueue;

	WHILE @WidgetID IS NOT NULL
	BEGIN
		EXEC dbo.up_WidgetLatestStateQueue_ByID @WidgetID;

		DELETE dbo.WidgetLatestStateQueue WHERE WidgetID = @WidgetID;

		SET @WidgetID = NULL;
		SELECT TOP 1 @WidgetID = WidgetID FROM dbo.WidgetLatestStateQueue;
	END

	PRINT CONVERT(varchar, GETDATE(), 114);
END
GO

IF OBJECT_ID('dbo.up_WidgetLatestStateQueue_ProcessAll') IS NOT NULL
	DROP PROC dbo.up_WidgetLatestStateQueue_ProcessAll
GO

CREATE PROCEDURE dbo.up_WidgetLatestStateQueue_ProcessAll
	@start datetime2 = NULL
AS
BEGIN
	EXEC dbo.up_WidgetLatestStateQueue_Populate @start;

	DECLARE @cnt int;
	SELECT @cnt = COUNT(*)
	FROM dbo.WidgetLatestStateQueue;

	PRINT 'To process: ' + STR(@cnt);

	EXEC dbo.up_WidgetLatestStateQueue_Process;
END
GO

-- We will test performance using all on-premise widgets
INSERT dbo.WidgetLatestStateQueue (WidgetID)
SELECT w.WidgetID
FROM [Dest].[uv_WidgetLatestState] w
WHERE w.DepartureDate IS NULL
AND w.ArrivalDate IS NOT NULL;
GO

EXEC dbo.up_WidgetLatestStateQueue_Process
GO

INSERT dbo.WidgetLatestStateQueue (WidgetID)
SELECT w.WidgetID
FROM [Dest].[uv_WidgetLatestState] w
WHERE w.DepartureDate IS NULL
AND w.ArrivalDate IS NOT NULL;
GO

-- This example tends to show an unfavorable performance profile for row-by-row compared to a set-based MERGE.
-- This is a good reason to evaluate your own workloads and likely update patterns - as noted in my article on queued merging, I have a production example that clearly
--  favors row-by-row by more than 50% (90% with parallelism). In any case, this example demonstrates one way of performing row-by-row merges.
PRINT CONVERT(varchar, GETDATE(), 114);

	MERGE [Dest].[WidgetLatestState] AS a
	 USING (
	 SELECT
	   v.[WidgetID]
		, v.[LastTripID]
		, v.[LastEventDate]
		, v.[ArrivalDate]
		, v.[DepartureDate]
	 FROM
	   [Dest].[uv_WidgetLatestState] v
	   JOIN dbo.WidgetLatestStateQueue q
		ON v.WidgetID = q.WidgetID
	 ) AS T
	 ON
	 (
	   a.[WidgetID] = t.[WidgetID]
	 )

	WHEN MATCHED 
		 AND t.ArrivalDate IS NOT NULL
		 AND ((a.[LastTripID] <> CONVERT(int, t.[LastTripID]))
			  OR (a.[LastEventDate] <> CONVERT(datetime, t.[LastEventDate]))
			  OR (a.[ArrivalDate] <> CONVERT(datetime, t.[ArrivalDate]))
			  OR (a.[DepartureDate] <> CONVERT(datetime, t.[DepartureDate]) OR (a.[DepartureDate] IS NULL AND t.[DepartureDate] IS NOT NULL) OR (a.[DepartureDate] IS NOT NULL AND t.[DepartureDate] IS NULL))) THEN
		 UPDATE
		  SET LastTripID = t.LastTripID
		, LastEventDate = t.LastEventDate
		, ArrivalDate = t.ArrivalDate
		, DepartureDate = t.DepartureDate

	WHEN NOT MATCHED BY TARGET AND t.ArrivalDate IS NOT NULL THEN
		  INSERT (
			WidgetID
		, LastTripID
		, LastEventDate
		, ArrivalDate
		, DepartureDate
		  ) VALUES (
			t.[WidgetID]
		, t.[LastTripID]
		, t.[LastEventDate]
		, t.[ArrivalDate]
		, t.[DepartureDate]
		  )

	WHEN MATCHED AND t.ArrivalDate IS NULL THEN
		 DELETE;

PRINT CONVERT(varchar, GETDATE(), 114);
GO
