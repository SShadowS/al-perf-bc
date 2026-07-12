codeunit 70505 "AL Perf Canary"
{
    Access = Public;
    TableNo = "Job Queue Entry";

    var
        ServerUrlMissingErr: Label 'Server URL Base is not configured on the AL Perf Ship Setup card.';
        TenantCodeMissingErr: Label 'Tenant Code is not configured on the AL Perf Ship Setup card.';
        AlreadyRecordingErr: Label 'A performance profiler recording is already in progress. Stop it before running the canary.';
        CanaryRunStartedTelemetryMsg: Label 'AL Perf canary run started.', Locked = true;

    trigger OnRun()
    begin
        RunCanary(true);
    end;

    /// Manual invocation (e.g. the "Run Canary Now" page action) — always runs
    /// immediately, without scheduling jitter or the ALP0001 breadcrumb.
    procedure RunNow()
    begin
        RunCanary(false);
    end;

    /// Profiles this session with cu1924 while the configured workload runs, then ships
    /// the profile through the shared ShipProfile transport. Cloud-safe: no scheduler
    /// table references. Scheduled = true only for the Job Queue (OnRun) path: applies
    /// the configured scheduling jitter and emits the ALP0001 telemetry breadcrumb.
    local procedure RunCanary(Scheduled: Boolean)
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

        // Conditional Codeunit.Run is rejected while a write transaction is
        // open, and GetOrCreate may have inserted the setup record just now.
        Commit();

        if Profiler.IsRecordingInProgress() then
            Error(AlreadyRecordingErr);

        // Jitter only delays the scheduled path, and only after the guards above —
        // a guarded early exit (disabled, misconfigured, already recording) must
        // never sleep pointlessly.
        if Scheduled then
            ApplyJitter(Setup."Canary Jitter (max minutes)");

        ActivityId := CreateGuid();
        StartDateTime := CurrentDateTime;

        if Scheduled then
            LogCanaryStart(ActivityId, CanaryDescription);

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

    local procedure ApplyJitter(MaxJitterMinutes: Integer)
    begin
        if MaxJitterMinutes <= 0 then
            exit;
        Sleep(Random(MaxJitterMinutes * 60) * 1000);
    end;

    local procedure LogCanaryStart(ActivityId: Guid; CanaryDescription: Text)
    var
        Dimensions: Dictionary of [Text, Text];
    begin
        Dimensions.Add('ActivityId', LowerCase(DelChr(Format(ActivityId), '=', '{}')));
        Dimensions.Add('ActivityDescription', CanaryDescription);
        Session.LogMessage('ALP0001', CanaryRunStartedTelemetryMsg, Verbosity::Normal, DataClassification::SystemMetadata, TelemetryScope::ExtensionPublisher, Dimensions);
    end;
}
