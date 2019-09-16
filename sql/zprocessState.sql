select count(ZProcessState),ZProcessState from alerts.status where TicketGroup <> 'IGNOREALERT' and Severity > 0 and IBMManaged != 10 and (SuppressEscl != 4 AND SuppressEscl != 6) AND (RCorrDelay = 0 AND RCauseServerSerial= 0) and CustomerCode <> '' and CustomerCode <> 'C00' GROUP by ZProcessState;
go
