codeunit 70503 "AL Perf Auto Ship"
{
    Access = Public;
    TableNo = "Job Queue Entry";

    var
        CrLf: Text[2];
        BearerSecretKeyTok: Label 'al-perf-poc-bearer-secret', Locked = true;
        TenantTokenKeyTok: Label 'al-perf-tenant-token', Locked = true;
        ShipSucceededTelemetryMsg: Label 'AL Perf profile shipped.', Locked = true;
        ShipFailedTelemetryMsg: Label 'AL Perf profile ship failed.', Locked = true;

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
        RetriedCount: Integer;
    begin
        Setup := Setup.GetOrCreate();
        if not Setup.Enabled then
            exit;

        // Sweep FAILED rows (any age, not just this run's window) before shipping new
        // profiles, so a stuck fleet catches up on backlog every run instead of only
        // retrying failures that happen to still fall inside the window below.
        RetryFailedShipments(Setup, RetriedCount, FailedCount);

        if Setup."Last Run DateTime" = 0DT then
            WindowStart := CurrentDateTime - 24 * 60 * 60 * 1000  // first run: 24h backfill
        else
            WindowStart := Setup."Last Run DateTime" - 60 * 60 * 1000; // 1h overlap

        // Only genuinely new profiles here — Failed retries (any age) are handled by
        // the RetryFailedShipments sweep above, so this loop no longer needs its own
        // Failed-in-window branch.
        PerfProfiles.SetFilter("Starting Date-Time", '>=%1', WindowStart);
        if PerfProfiles.FindSet() then
            repeat
                if not ShipLog.Get(PerfProfiles."Activity ID") then
                    if ShipOne(Setup, PerfProfiles) then
                        ShippedCount += 1
                    else
                        FailedCount += 1;
            until PerfProfiles.Next() = 0;

        Setup."Last Run DateTime" := CurrentDateTime;
        if FailedCount > 0 then
            Setup."Last Error" := StrSubstNo('Shipped %1, retried %2, failed %3 in last run', ShippedCount, RetriedCount, FailedCount)
        else
            Setup."Last Error" := '';
        Setup.Modify();
    end;

    /// D2 retry sweep: FAILED rows below the attempt cap are re-shipped via the same
    /// ShipProfile transport ShipOne uses. Runs before new-profile processing so a
    /// backlog catches up every ShipPending call, independent of the window below.
    local procedure RetryFailedShipments(Setup: Record "AL Perf Ship Setup"; var RetriedCount: Integer; var FailedCount: Integer)
    var
        ShipLog: Record "AL Perf Ship Log";
    begin
        ShipLog.SetRange(Status, ShipLog.Status::Failed);
        ShipLog.SetFilter(Attempts, '<%1', MaxRetryAttempts());
        if ShipLog.FindSet(true) then
            repeat
                if RetryShipLogRow(Setup, ShipLog) then
                    RetriedCount += 1
                else
                    FailedCount += 1;
            until ShipLog.Next() = 0;
    end;

    /// Manual "Retry Now" page action — same re-ship path as the sweep, uncapped
    /// (an operator's deliberate click is allowed to retry a row the automatic sweep
    /// has already given up on). Resets nothing on ShipLog before retrying.
    procedure RetryOne(var ShipLog: Record "AL Perf Ship Log")
    var
        Setup: Record "AL Perf Ship Setup";
        NotFailedErr: Label 'Only a Failed shipment can be retried.';
    begin
        if ShipLog.Status <> ShipLog.Status::Failed then
            Error(NotFailedErr);
        Setup := Setup.GetOrCreate();
        RetryShipLogRow(Setup, ShipLog);
    end;

    /// Shared by the sweep and the manual retry action. The source Performance
    /// Profiles record can be gone by retry time — deleted, or (for canary rows)
    /// never persisted in the first place, since the canary ships an in-memory
    /// profile that only ever existed for the duration of its own session. Either
    /// way there is nothing left to re-ship, so this is a permanent failure: pin
    /// Attempts at the cap so the sweep never re-examines the row again, rather than
    /// re-attempting (and re-failing) it every run forever.
    local procedure RetryShipLogRow(Setup: Record "AL Perf Ship Setup"; var ShipLog: Record "AL Perf Ship Log"): Boolean
    var
        PerfProfile: Record "Performance Profiles";
    begin
        PerfProfile.SetRange("Activity ID", ShipLog."Activity ID");
        if PerfProfile.FindFirst() then
            exit(ShipOne(Setup, PerfProfile));

        ShipLog.Status := ShipLog.Status::Failed;
        ShipLog."Error Message" := 'Source profile is no longer available — permanently failed, will not retry.';
        ShipLog.Attempts := MaxRetryAttempts();
        ShipLog.Modify();
        LogShipFailure(ShipLog);
        exit(false);
    end;

    local procedure MaxRetryAttempts(): Integer
    begin
        exit(5);
    end;

    local procedure ShipOne(Setup: Record "AL Perf Ship Setup"; var PerfProfile: Record "Performance Profiles"): Boolean
    var
        ShipLog: Record "AL Perf Ship Log";
        ManifestJson: JsonObject;
        ProfileInStream: InStream;
    begin
        if not InitShipLog(ShipLog, PerfProfile) then
            exit(false);

        PerfProfile.CalcFields(Profile);
        if not PerfProfile.Profile.HasValue() then begin
            // An empty blob on a still-existing Performance Profiles record doesn't
            // resolve itself on a later retry — same permanent-failure treatment as a
            // deleted/never-persisted source record (RetryShipLogRow), and for the same
            // reason: without this, the age-independent sweep would re-select this row
            // every run forever (Attempts never reaches the cap because this branch
            // returns before ever reaching ShipProfile, the only place Attempts
            // increments).
            ShipLog.Status := ShipLog.Status::Failed;
            ShipLog."Error Message" := 'Profile blob empty — permanently failed, will not retry.';
            ShipLog.Attempts := MaxRetryAttempts();
            ShipLog.Modify();
            LogShipFailure(ShipLog);
            exit(false);
        end;

        ManifestJson := BuildSchedulerManifest(PerfProfile);
        PerfProfile.Profile.CreateInStream(ProfileInStream);
        exit(ShipProfile(Setup, ShipLog, ManifestJson, ProfileInStream));
    end;

    local procedure BuildSchedulerManifest(var PerfProfile: Record "Performance Profiles") ManifestObj: JsonObject
    var
        PerfSched: Record "Performance Profile Scheduler";
    begin
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

    /// Transport core shared by the scheduler path (ShipOne), the canary
    /// (codeunit "AL Perf Canary"), and the D2 retry sweep/manual retry
    /// (RetryShipLogRow/RetryOne). ShipLog must already be inserted; its
    /// "Activity ID" drives the idempotency header and must match
    /// ManifestJson.activityId. Never clears "Error Message" on success.
    /// The single chokepoint every ship path (first try, sweep, manual) runs
    /// through, so Attempts is incremented here — once per call, success or fail.
    internal procedure ShipProfile(Setup: Record "AL Perf Ship Setup"; var ShipLog: Record "AL Perf Ship Log"; ManifestJson: JsonObject; ProfileInStream: InStream): Boolean
    var
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
        ShipLog.Attempts += 1;
        BuildMultipartBody(ManifestJson, ProfileInStream, BodyTempBlob, ContentType);
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
        Headers.Add('Authorization', 'Bearer ' + GetAuthBearer());
        Headers.Add('X-Tenant-Id', Setup."Tenant Code");
        Headers.Add('X-Idempotency-Key', LowerCase(DelChr(Format(ShipLog."Activity ID"), '=', '{}')));

        Client.Timeout(120000);
        if not Client.Send(RequestMsg, ResponseMsg) then begin
            ShipLog.Status := ShipLog.Status::Failed;
            ShipLog."Error Message" := CopyStr(StrSubstNo('Connection failed to %1', Url), 1, 500);
            ShipLog.Modify();
            LogShipFailure(ShipLog);
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
            LogShipSuccess(ShipLog);
            exit(true);
        end;

        ShipLog.Status := ShipLog.Status::Failed;
        ShipLog."Error Message" := CopyStr(ResponseText, 1, 500);
        ShipLog.Modify();
        LogShipFailure(ShipLog);
        exit(false);
    end;

    local procedure LogShipSuccess(ShipLog: Record "AL Perf Ship Log")
    var
        Dimensions: Dictionary of [Text, Text];
    begin
        Dimensions.Add('ActivityId', LowerCase(DelChr(Format(ShipLog."Activity ID"), '=', '{}')));
        Dimensions.Add('ActivityDescription', ShipLog."Activity Description");
        if ShipLog."HTTP Status" <> 0 then
            Dimensions.Add('HttpStatus', Format(ShipLog."HTTP Status"));
        Session.LogMessage('ALP0002', ShipSucceededTelemetryMsg, Verbosity::Normal, DataClassification::SystemMetadata, TelemetryScope::ExtensionPublisher, Dimensions);
    end;

    local procedure LogShipFailure(ShipLog: Record "AL Perf Ship Log")
    var
        Dimensions: Dictionary of [Text, Text];
    begin
        Dimensions.Add('ActivityId', LowerCase(DelChr(Format(ShipLog."Activity ID"), '=', '{}')));
        Dimensions.Add('ActivityDescription', ShipLog."Activity Description");
        if ShipLog."HTTP Status" <> 0 then
            Dimensions.Add('HttpStatus', Format(ShipLog."HTTP Status"));
        Dimensions.Add('Attempts', Format(ShipLog.Attempts));
        Session.LogMessage('ALP0003', ShipFailedTelemetryMsg, Verbosity::Normal, DataClassification::SystemMetadata, TelemetryScope::ExtensionPublisher, Dimensions);
    end;

    local procedure BuildMultipartBody(ManifestJson: JsonObject; ProfileInStream: InStream; var TempBlob: Codeunit "Temp Blob"; var ContentType: Text)
    var
        OutStr: OutStream;
        Boundary: Text;
        BoundaryGuid: Guid;
        ManifestText: Text;
    begin
        InitCrLf();
        BoundaryGuid := CreateGuid();
        Boundary := DelChr(Format(BoundaryGuid), '=', '{}');
        TempBlob.CreateOutStream(OutStr, TextEncoding::UTF8);

        ManifestJson.WriteTo(ManifestText);

        OutStr.WriteText('--' + Boundary + CrLf);
        OutStr.WriteText('Content-Disposition: form-data; name="manifest"; filename="manifest.json"' + CrLf);
        OutStr.WriteText('Content-Type: application/json' + CrLf);
        OutStr.WriteText(CrLf);
        OutStr.WriteText(ManifestText);

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
            Error('Registration secret is not set. Configure it via the AL Perf Ship Setup card.');
        exit(Secret);
    end;

    /// Per-tenant token issued once by /api/tenants/register; stored on registration.
    procedure SetTenantToken(NewToken: Text)
    begin
        IsolatedStorage.Set(TenantTokenKeyTok, NewToken, DataScope::Module);
    end;

    procedure HasTenantToken(): Boolean
    var
        Token: Text;
    begin
        exit(IsolatedStorage.Get(TenantTokenKeyTok, DataScope::Module, Token));
    end;

    /// Bearer for ingest and profile downloads: the per-tenant token. Falls back
    /// to the legacy shared secret only when no token is stored — the server then
    /// needs AL_PERF_ALLOW_SHARED_SECRET=1 or the call is rejected with 401.
    procedure GetAuthBearer(): Text
    var
        Token: Text;
    begin
        if IsolatedStorage.Get(TenantTokenKeyTok, DataScope::Module, Token) then
            exit(Token);
        exit(GetBearerSecret());
    end;

    /// Phase B: download plaintext profile and pipe to Performance Profiler page (v0).
    /// Phase E: switch to encrypted-bundle decrypt path.
    procedure OpenProfile(ShipLog: Record "AL Perf Ship Log")
    var
        Setup: Record "AL Perf Ship Setup";
        Crypto: Codeunit "AL Perf Crypto";
        SamplingProfiler: Codeunit "Sampling Performance Profiler";
        ProfilerPage: Page "Performance Profiler";
        Client: HttpClient;
        RequestMsg: HttpRequestMessage;
        ResponseMsg: HttpResponseMessage;
        Headers: HttpHeaders;
        ResponseText: Text;
        StatusCode: Integer;
        Url: Text;
        ActivityIdText: Text;
        Json: JsonObject;
        TokenValue: JsonToken;
        ManifestBase64: Text;
        WrappedBase64: Text;
        BlobIv, BlobTag, BlobCipher: Text;
        ResIv, ResTag, ResCipher: Text;
        Base64: Codeunit "Base64 Convert";
        WrappedTempBlob, ManifestTempBlob, BlobCipherTempBlob, ResultCipherTempBlob: Codeunit "Temp Blob";
        WrappedOut, ManifestOut, BlobCipherOut, ResultCipherOut: OutStream;
        WrappedIn, ManifestIn, BlobCipherIn, ResultCipherIn: InStream;
        PlainBlobTempBlob, PlainResultTempBlob: Codeunit "Temp Blob";
        PlainBlobOut, PlainResultOut: OutStream;
        PlainBlobIn: InStream;
    begin
        Setup := Setup.GetOrCreate();
        ActivityIdText := LowerCase(DelChr(Format(ShipLog."Activity ID"), '=', '{}'));
        Url := Setup."Server URL Base" + '/api/profiles/' + ActivityIdText + '?tenant=' + Setup."Tenant Code";
        RequestMsg.Method('GET');
        RequestMsg.SetRequestUri(Url);
        RequestMsg.GetHeaders(Headers);
        Headers.Add('Authorization', 'Bearer ' + GetAuthBearer());

        if not Client.Send(RequestMsg, ResponseMsg) then
            Error('Connection failed.');
        StatusCode := ResponseMsg.HttpStatusCode();
        ResponseMsg.Content().ReadAs(ResponseText);
        if (StatusCode < 200) or (StatusCode >= 300) then
            Error('Server returned HTTP %1.', StatusCode);

        if not Json.ReadFrom(ResponseText) then
            Error('Server response is not JSON.');

        Json.Get('manifest', TokenValue); ManifestBase64 := TokenValue.AsValue().AsText();
        Json.Get('wrapped', TokenValue); WrappedBase64 := TokenValue.AsValue().AsText();
        Json.Get('blob', TokenValue); ExtractIvTagCipher(TokenValue.AsObject(), BlobIv, BlobTag, BlobCipher);
        Json.Get('result', TokenValue); ExtractIvTagCipher(TokenValue.AsObject(), ResIv, ResTag, ResCipher);

        // Decode binaries to InStreams
        WrappedTempBlob.CreateOutStream(WrappedOut); Base64.FromBase64(WrappedBase64, WrappedOut); WrappedTempBlob.CreateInStream(WrappedIn);
        ManifestTempBlob.CreateOutStream(ManifestOut); Base64.FromBase64(ManifestBase64, ManifestOut); ManifestTempBlob.CreateInStream(ManifestIn);
        BlobCipherTempBlob.CreateOutStream(BlobCipherOut); Base64.FromBase64(BlobCipher, BlobCipherOut); BlobCipherTempBlob.CreateInStream(BlobCipherIn);
        ResultCipherTempBlob.CreateOutStream(ResultCipherOut); Base64.FromBase64(ResCipher, ResultCipherOut); ResultCipherTempBlob.CreateInStream(ResultCipherIn);

        PlainBlobTempBlob.CreateOutStream(PlainBlobOut);
        PlainResultTempBlob.CreateOutStream(PlainResultOut);

        if not Crypto.DecryptBundle(
            WrappedIn, ManifestIn,
            BlobIv, BlobTag, BlobCipherIn,
            ResIv, ResTag, ResultCipherIn,
            PlainBlobOut, PlainResultOut)
        then begin
            ShipLog.Status := ShipLog.Status::Failed;
            ShipLog."Error Message" := 'HMAC mismatch — tampered or wrong key';
            ShipLog.Modify();
            Error('Decryption failed: HMAC mismatch.');
        end;

        PlainBlobTempBlob.CreateInStream(PlainBlobIn);
        SamplingProfiler.SetData(PlainBlobIn);
        ProfilerPage.SetData(PlainBlobIn);
        ProfilerPage.Run();
    end;

    local procedure ExtractIvTagCipher(Obj: JsonObject; var Iv: Text; var Tag: Text; var Cipher: Text)
    var
        T: JsonToken;
    begin
        Obj.Get('iv', T); Iv := T.AsValue().AsText();
        Obj.Get('tag', T); Tag := T.AsValue().AsText();
        Obj.Get('ciphertext', T); Cipher := T.AsValue().AsText();
    end;
}
