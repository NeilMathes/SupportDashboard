USE [Footprints]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER PROCEDURE [dbo].[cusip_ActiveTickets]
AS
BEGIN

	SELECT 
		COUNT(*) AS CurrentTickets
	FROM 
		MASTER4 m
	WHERE 
		m.mrSTATUS NOT IN ('Closed','Resolved', '_DELETED_', 'Client__bAcceptance', 'Contracted__bWork', 'Development', 'Pending','Escalated__b__u__bDevelopment','Escalated__b__u__bCBSW__bDevelopment','Escalated__b__u__bTier__b2')
		AND m.mrASSIGNEES LIKE 'Support%'
		AND NOT m.Scheduled__bCall >= DATEADD(d,1,CAST(GETDATE() AS DATE))

END
