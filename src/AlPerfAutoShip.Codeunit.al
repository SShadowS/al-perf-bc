codeunit 70503 "AL Perf Auto Ship"
{
    Access = Public;
    TableNo = "Job Queue Entry";

    var
        CrLf: Text[2];
        BearerSecretKeyTok: Label 'al-perf-poc-bearer-secret', Locked = true;

    trigger OnRun()
    begin
        ShipPending();
    end;

    /// Run once for the current session — used both from Job Queue and manual invocation.
    procedure ShipPending()
    var
        Setup: Record "AL Perf Ship Setup";
        PerfProfiles: Record "Performance Profiles";
        ShipLog: Record "AL Perf Ship Log";
        WindowStart: DateTime;
        ShippedCount: Integer;
        FailedCount: Integer;
    begin
        Setup := Setup.GetOrCreate();
        if not Setup.Enabled then
            exit;

        if Setup."Last Run DateTime" = 0DT then
            WindowStart := CurrentDateTime - 24 * 60 * 60 * 1000  // first run: 24h backfill
        else
            WindowStart := Setup."Last Run DateTime" - 60 * 60 * 1000; // 1h overlap

        PerfProfiles.SetFilter("Starting Date-Time", '>=%1', WindowStart);
        if PerfProfiles.FindSet() then
            repeat
                if not ShipLog.Get(PerfProfiles."Activity ID") then begin
                    if ShipOne(Setup, PerfProfiles) then
                        ShippedCount += 1
                    else
                        FailedCount += 1;
                end else
                    if ShipLog.Status = ShipLog.Status::Failed then
                        if ShipOne(Setup, PerfProfiles) then
                            ShippedCount += 1
                        else
                            FailedCount += 1;
            until PerfProfiles.Next() = 0;

        Setup."Last Run DateTime" := CurrentDateTime;
        if FailedCount > 0 then
            Setup."Last Error" := StrSubstNo('Shipped %1, failed %2 in last run', ShippedCount, FailedCount)
        else
            Setup."Last Error" := '';
        Setup.Modify();
    end;

    local procedure ShipOne(Setup: Record "AL Perf Ship Setup"; var PerfProfile: Record "Performance Profiles"): Boolean
    var
        ShipLog: Record "AL Perf Ship Log";
        BodyTempBlob: Codeunit "Temp Blob";
        Client: HttpClient;
        RequestMsg: HttpRequestMessage;
        ResponseMsg: HttpResponseMessage;
        Content: HttpContent;
        Headers: HttpHeaders;
        BodyInStream: InStream;
        ContentType: Text;
        ResponseText: Text;
        StatusCode: Integer;
        Url: Text;
    begin
        InitCrLf();

        if not InitShipLog(ShipLog, PerfProfile) then
            exit(false);

        PerfProfile.CalcFields(Profile);
        if not PerfProfile.Profile.HasValue() then begin
            ShipLog.Status := ShipLog.Status::Failed;
            ShipLog."Error Message" := 'Profile blob empty';
            ShipLog.Modify();
            exit(false);
        end;

        BuildMultipartBody(PerfProfile, BodyTempBlob, ContentType);
        BodyTempBlob.CreateInStream(BodyInStream);

        Content.WriteFrom(BodyInStream);
        Content.GetHeaders(Headers);
        if Headers.Contains('Content-Type') then
            Headers.Remove('Content-Type');
        Headers.Add('Content-Type', ContentType);

        Url := Setup."Server URL Base" + '/api/ingest';
        RequestMsg.Method('POST');
        RequestMsg.SetRequestUri(Url);
        RequestMsg.Content(Content);

        RequestMsg.GetHeaders(Headers);
        Headers.Add('Authorization', 'Bearer ' + GetBearerSecret());
        Headers.Add('X-Tenant-Id', Setup."Tenant Code");
        Headers.Add('X-Idempotency-Key', LowerCase(DelChr(Format(PerfProfile."Activity ID"), '=', '{}')));

        Client.Timeout(120000);
        if not Client.Send(RequestMsg, ResponseMsg) then begin
            ShipLog.Status := ShipLog.Status::Failed;
            ShipLog."Error Message" := CopyStr(StrSubstNo('Connection failed to %1', Url), 1, 500);
            ShipLog.Modify();
            exit(false);
        end;

        StatusCode := ResponseMsg.HttpStatusCode();
        ResponseMsg.Content().ReadAs(ResponseText);

        ShipLog."HTTP Status" := StatusCode;
        if (StatusCode >= 200) and (StatusCode < 300) then begin
            ShipLog.Status := ShipLog.Status::Shipped;
            ShipLog."Shipped At" := CurrentDateTime;
            if StrLen(ResponseText) <= 100 then
                ShipLog."Server Profile ID" := CopyStr(ResponseText, 1, 100);
            ShipLog.Modify();
            exit(true);
        end;

        ShipLog.Status := ShipLog.Status::Failed;
        ShipLog."Error Message" := CopyStr(ResponseText, 1, 500);
        ShipLog.Modify();
        exit(false);
    end;

    local procedure InitShipLog(var ShipLog: Record "AL Perf Ship Log"; PerfProfile: Record "Performance Profiles"): Boolean
    begin
        if ShipLog.Get(PerfProfile."Activity ID") then begin
            if ShipLog.Status = ShipLog.Status::Shipped then
                exit(false);
        end else begin
            ShipLog.Init();
            ShipLog."Activity ID" := PerfProfile."Activity ID";
            ShipLog.Insert();
        end;
        ShipLog."Schedule ID" := PerfProfile."Schedule ID";
        ShipLog."Activity Description" := CopyStr(PerfProfile."Activity Description", 1, MaxStrLen(ShipLog."Activity Description"));
        ShipLog."Starting Date-Time" := PerfProfile."Starting Date-Time";
        ShipLog.Status := ShipLog.Status::Pending;
        ShipLog."Profile Size (bytes)" := 0;  // set in caller after CalcFields if you have a size source
        exit(true);
    end;

    local procedure BuildMultipartBody(var PerfProfile: Record "Performance Profiles"; var TempBlob: Codeunit "Temp Blob"; var ContentType: Text)
    var
        OutStr: OutStream;
        ProfileInStream: InStream;
        Boundary: Text;
        BoundaryGuid: Guid;
        ManifestObj: JsonObject;
        ManifestText: Text;
        PerfSched: Record "Performance Profile Scheduler";
    begin
        BoundaryGuid := CreateGuid();
        Boundary := DelChr(Format(BoundaryGuid), '=', '{}');
        TempBlob.CreateOutStream(OutStr, TextEncoding::UTF8);

        // Manifest
        PerfProfile.CalcFields("User Name");
        ManifestObj.Add('activityId', LowerCase(DelChr(Format(PerfProfile."Activity ID"), '=', '{}')));
        ManifestObj.Add('activityType', MapClientType(PerfProfile."Client Type"));
        ManifestObj.Add('activityDescription', PerfProfile."Activity Description");
        ManifestObj.Add('startTime', Format(PerfProfile."Starting Date-Time", 0, 9));
        ManifestObj.Add('activityDuration', PerfProfile."Activity Duration");
        ManifestObj.Add('alExecutionDuration', PerfProfile.Duration);
        ManifestObj.Add('sqlCallDuration', PerfProfile."Sql Call Duration");
        ManifestObj.Add('sqlCallCount', PerfProfile."Sql Statement Number");
        ManifestObj.Add('httpCallDuration', PerfProfile."Http Call Duration");
        ManifestObj.Add('httpCallCount', PerfProfile."Http Call Number");
        ManifestObj.Add('userName', PerfProfile."User Name");
        ManifestObj.Add('clientSessionId', PerfProfile."Client Session ID");
        if not IsNullGuid(PerfProfile."Schedule ID") then begin
            ManifestObj.Add('scheduleId', LowerCase(DelChr(Format(PerfProfile."Schedule ID"), '=', '{}')));
            if PerfSched.Get(PerfProfile."Schedule ID") then
                ManifestObj.Add('scheduleDescription', PerfSched.Description);
        end;
        ManifestObj.WriteTo(ManifestText);

        OutStr.WriteText('--' + Boundary + CrLf);
        OutStr.WriteText('Content-Disposition: form-data; name="manifest"; filename="manifest.json"' + CrLf);
        OutStr.WriteText('Content-Type: application/json' + CrLf);
        OutStr.WriteText(CrLf);
        OutStr.WriteText(ManifestText);

        // Profile
        PerfProfile.Profile.CreateInStream(ProfileInStream);
        OutStr.WriteText(CrLf + '--' + Boundary + CrLf);
        OutStr.WriteText('Content-Disposition: form-data; name="profile"; filename="profile.alcpuprofile"' + CrLf);
        OutStr.WriteText('Content-Type: application/octet-stream' + CrLf);
        OutStr.WriteText(CrLf);
        CopyStream(OutStr, ProfileInStream);

        OutStr.WriteText(CrLf + '--' + Boundary + '--' + CrLf);

        ContentType := 'multipart/form-data; boundary=' + Boundary;
    end;

    local procedure MapClientType(ClientType: Option): Text
    begin
        case ClientType of
            0, 1: exit('WebClient');
            2: exit('WebServiceAPI');
            3: exit('Background');
            else
                exit('WebClient');
        end;
    end;

    local procedure InitCrLf()
    begin
        if CrLf = '' then begin
            CrLf[1] := 13;
            CrLf[2] := 10;
        end;
    end;

    procedure SetBearerSecret(NewSecret: Text)
    begin
        IsolatedStorage.Set(BearerSecretKeyTok, NewSecret, DataScope::Module);
    end;

    procedure GetBearerSecret(): Text
    var
        Secret: Text;
    begin
        if not IsolatedStorage.Get(BearerSecretKeyTok, DataScope::Module, Secret) then
            Error('Bearer secret is not set. Configure it via the AL Perf Ship Setup card.');
        exit(Secret);
    end;

    /// Phase B: download plaintext profile and pipe to Performance Profiler page (v0).
    /// Phase E: switch to encrypted-bundle decrypt path.
    procedure OpenProfile(ShipLog: Record "AL Perf Ship Log")
    var
        Setup: Record "AL Perf Ship Setup";
        Client: HttpClient;
        RequestMsg: HttpRequestMessage;
        ResponseMsg: HttpResponseMessage;
        Headers: HttpHeaders;
        TempBlob: Codeunit "Temp Blob";
        BlobInStream: InStream;
        BlobOutStream: OutStream;
        SamplingProfiler: Codeunit "Sampling Performance Profiler";
        ProfilerPage: Page "Performance Profiler";
        Url: Text;
        StatusCode: Integer;
        ActivityIdText: Text;
    begin
        Setup := Setup.GetOrCreate();
        ActivityIdText := LowerCase(DelChr(Format(ShipLog."Activity ID"), '=', '{}'));
        Url := Setup."Server URL Base" + '/api/profiles/' + ActivityIdText + '?tenant=' + Setup."Tenant Code";
        RequestMsg.Method('GET');
        RequestMsg.SetRequestUri(Url);
        RequestMsg.GetHeaders(Headers);
        Headers.Add('Authorization', 'Bearer ' + GetBearerSecret());

        if not Client.Send(RequestMsg, ResponseMsg) then
            Error('Connection to %1 failed', Url);

        StatusCode := ResponseMsg.HttpStatusCode();
        if (StatusCode < 200) or (StatusCode >= 300) then
            Error('Server returned HTTP %1 fetching profile', StatusCode);

        TempBlob.CreateOutStream(BlobOutStream);
        ResponseMsg.Content().ReadAs(BlobInStream);
        CopyStream(BlobOutStream, BlobInStream);
        TempBlob.CreateInStream(BlobInStream);

        SamplingProfiler.SetData(BlobInStream);
        ProfilerPage.SetData(BlobInStream);
        ProfilerPage.Run();
    end;
}
