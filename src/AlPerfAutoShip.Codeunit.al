codeunit 70503 "AL Perf Auto Ship"
{
    Access = Public;
    TableNo = "Job Queue Entry";

    var
        CrLf: Text[2];
        BearerSecretKeyTok: Label 'al-perf-poc-bearer-secret', Locked = true;
        TenantTokenKeyTok: Label 'al-perf-tenant-token', Locked = true;

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
        Headers.Add('Authorization', 'Bearer ' + GetAuthBearer());
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
