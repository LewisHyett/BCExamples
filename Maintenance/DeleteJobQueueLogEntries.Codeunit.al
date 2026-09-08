codeunit 89003 "Delete Job Queue Log Ent."
{
    // Job Queue codeunit: deletes Job Queue Log Entries older than 7 days.
    // Commits after every 10,000 deleted records and stops after 100,000 per run.
    InherentEntitlements = X;
    InherentPermissions = X;

    trigger OnRun()
    begin
        DeleteAgedLogEntries();
    end;

    var
        RetentionDays: Integer;
        CommitBatchSize: Integer;
        MaxDeletionsPerRun: Integer;

    procedure SetRetentionDays(NewRetentionDays: Integer)
    begin
        RetentionDays := NewRetentionDays;
    end;

    local procedure DeleteAgedLogEntries()
    var
        RetentionDateTime: DateTime;
        DeletedTotal: Integer;
        DeletedInBatch: Integer;
    begin
        ApplyDefaults();
        RetentionDateTime := CreateDateTime(CalcDate('<-' + Format(RetentionDays) + 'D>', Today), 0T);

        repeat
            DeletedInBatch := DeleteBatch(RetentionDateTime, MaxDeletionsPerRun - DeletedTotal);
            DeletedTotal += DeletedInBatch;
            if DeletedInBatch > 0 then
                Commit();
        until (DeletedInBatch = 0) or (DeletedTotal >= MaxDeletionsPerRun);
    end;

    local procedure DeleteBatch(RetentionDateTime: DateTime; RemainingCap: Integer) DeletedInBatch: Integer
    var
        JobQueueLogEntry: Record "Job Queue Log Entry";
        BatchLimit: Integer;
    begin
        BatchLimit := CommitBatchSize;
        if RemainingCap < BatchLimit then
            BatchLimit := RemainingCap;
        if BatchLimit <= 0 then
            exit(0);

        JobQueueLogEntry.SetFilter("Start Date/Time", '<%1', RetentionDateTime);
        if not JobQueueLogEntry.FindSet() then
            exit(0);

        repeat
            JobQueueLogEntry.Delete(true);
            DeletedInBatch += 1;
        until (JobQueueLogEntry.Next() = 0) or (DeletedInBatch >= BatchLimit);
    end;

    local procedure ApplyDefaults()
    begin
        if RetentionDays <= 0 then
            RetentionDays := 7;
        CommitBatchSize := 10000;
        MaxDeletionsPerRun := 100000;
    end;
}