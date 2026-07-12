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
        JitterSeconds: Integer;
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

        ActivityId := CreateGuid();

        // Jitter only delays the scheduled path, and only after the guards above —
        // a guarded early exit (disabled, misconfigured, already recording) must
        // never sleep pointlessly. ALP0001 fires before the sleep (carrying the
        // rolled jitter) so a Job Queue watchdog kill mid-sleep still leaves a
        // breadcrumb, instead of looking indistinguishable from "never ran".
        if Scheduled then begin
            JitterSeconds := RollJitterSeconds(Setup."Canary Jitter (max minutes)");
            LogCanaryStart(ActivityId, CanaryDescription, JitterSeconds);
            if JitterSeconds > 0 then
                Sleep(JitterSeconds * 1000);
        end;

        StartDateTime := CurrentDateTime;

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

    local procedure RollJitterSeconds(MaxJitterMinutes: Integer): Integer
    begin
        if MaxJitterMinutes <= 0 then
            exit(0);
        // Random() runs from a fixed seed until reseeded; each Job Queue run is a
        // fresh session, so without this every run (and every tenant) would sleep
        // the same duration — no fleet desynchronization.
        Randomize();
        exit(Random(MaxJitterMinutes * 60));
    end;

    local procedure LogCanaryStart(ActivityId: Guid; CanaryDescription: Text; JitterSeconds: Integer)
    var
        Dimensions: Dictionary of [Text, Text];
    begin
        Dimensions.Add('ActivityId', LowerCase(DelChr(Format(ActivityId), '=', '{}')));
        Dimensions.Add('ActivityDescription', CanaryDescription);
        Dimensions.Add('JitterSeconds', Format(JitterSeconds));
        Session.LogMessage('ALP0001', CanaryRunStartedTelemetryMsg, Verbosity::Normal, DataClassification::SystemMetadata, TelemetryScope::ExtensionPublisher, Dimensions);
    end;
}
