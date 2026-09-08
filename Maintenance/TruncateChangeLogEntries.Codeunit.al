codeunit 89002 "Upgrade"
{
    Subtype = Upgrade;

    trigger OnUpgradePerCompany()
    begin
        TruncateChangeLogEntries();
    end;

    var
        UpgradeTag: Codeunit "Upgrade Tag";

    local procedure TruncateChangeLogEntries()
    var
        ChangeLogEntry: Record "Change Log Entry";
    begin
        if UpgradeTag.HasUpgradeTag(GetTruncateChangeLogEntriesUpgradeTagCode()) then
            exit;

        ChangeLogEntry.SetFilter("Table No.", '%1|%2|%3', Database::"Job Queue Entry", Database::"Job Queue Log Entry", Database::"Job Queue Category");
        ChangeLogEntry.Truncate(true);

        UpgradeTag.SetUpgradeTag(GetTruncateChangeLogEntriesUpgradeTagCode());
    end;

    local procedure GetTruncateChangeLogEntriesUpgradeTagCode(): Code[250]
    begin
        exit('_Upgrade_TruncateChangeLogEntries_008092026');
    end;
}