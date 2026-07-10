codeunit 70505 "AL Perf Canary"
{
    Access = Public;
    TableNo = "Job Queue Entry";

    var
        ServerUrlMissingErr: Label 'Server URL Base is not configured on the AL Perf Ship Setup card.';
        TenantCodeMissingErr: Label 'Tenant Code is not configured on the AL Perf Ship Setup card.';

    trigger OnRun()
    begin
        RunNow();
    end;

    /// Run once for the current session — used both from Job Queue and manual invocation.
    /// Profiles this session with cu1924 while the configured workload runs, then ships
    /// the profile through the shared ShipProfile transport. Cloud-safe: no scheduler
    /// table references.
    procedure RunNow()
    var
        Setup: Record "AL Perf Ship Setup";
        ShipLog: Record "AL Perf Ship Log";
        AutoShip: Codeunit "AL Perf Auto Ship";
        Profiler: Codeunit "Sampling Performance Profiler";
        ManifestJson: JsonObject;
        ProfileInStream: InStream;
        ActivityId: Guid;
        StartDateTime: DateTime;
        ActivityDuration: Duration;
        WorkloadId: Integer;
        WorkloadOk: Boolean;
        WorkloadError: Text;
        CanaryDescription: Text;
    begin
        Setup := Setup.GetOrCreate();
        if not Setup."Canary Enabled" then
            exit;
        if Setup."Server URL Base" = '' then
            Error(ServerUrlMissingErr);
        if Setup."Tenant Code" = '' then
            Error(TenantCodeMissingErr);

        WorkloadId := Setup."Canary Workload Codeunit ID";
        if WorkloadId = 0 then
            WorkloadId := Codeunit::"AL Perf Canary Workload";

        CanaryDescription := Setup."Canary Description";
        if CanaryDescription = '' then
            CanaryDescription := StrSubstNo('Canary workload %1', WorkloadId);

        ActivityId := CreateGuid();
        StartDateTime := CurrentDateTime;

        // Conditional Codeunit.Run is rejected while a write transaction is
        // open, and GetOrCreate may have inserted the setup record just now.
        Commit();

        Profiler.Start("Sampling Interval"::SampleEvery50ms);
        WorkloadOk := Codeunit.Run(WorkloadId);
        if not WorkloadOk then
            WorkloadError := GetLastErrorText();
        Profiler.Stop();

        ActivityDuration := CurrentDateTime - StartDateTime;
        ProfileInStream := Profiler.GetData();

        ManifestJson.Add('activityId', LowerCase(DelChr(Format(ActivityId), '=', '{}')));
        ManifestJson.Add('activityType', 'Canary');
        ManifestJson.Add('activityDescription', CanaryDescription);
        ManifestJson.Add('startTime', Format(StartDateTime, 0, 9));
        ManifestJson.Add('activityDuration', ActivityDuration);

        ShipLog.Init();
        ShipLog."Activity ID" := ActivityId;
        ShipLog.Canary := true;
        ShipLog."Activity Description" := CopyStr(CanaryDescription, 1, MaxStrLen(ShipLog."Activity Description"));
        ShipLog."Starting Date-Time" := StartDateTime;
        ShipLog.Status := ShipLog.Status::Pending;
        if not WorkloadOk then
            ShipLog."Error Message" := CopyStr(StrSubstNo('Workload failed: %1', WorkloadError), 1, 500);
        ShipLog.Insert();

        AutoShip.ShipProfile(Setup, ShipLog, ManifestJson, ProfileInStream);
    end;
}
