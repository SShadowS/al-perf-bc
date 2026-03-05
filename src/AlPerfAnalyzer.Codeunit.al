codeunit 70500 "Al Perf Analyzer"
{
    Access = Public;

    var
        ApiBaseUrl: Label 'https://alperf.sshadows.dk', Locked = true;
        ApiPath: Label '/api/analyze?format=html', Locked = true;
        CrLf: Text[2];
        NoProfileDataErr: Label 'No profile data available. Please record a profiling session first.';
        ConnectionErr: Label 'Could not connect to the AL Perf Analyzer service at %1. Please check your network connection and try again.', Comment = '%1 = API URL';
        HttpErrorErr: Label 'The AL Perf Analyzer service returned an error (HTTP %1).\n\n%2', Comment = '%1 = HTTP status code, %2 = response excerpt';
        TimeoutErr: Label 'The request to the AL Perf Analyzer service timed out. The analysis can take up to 30 seconds for AI-powered insights. Please try again.';
        ApiBatchPath: Label '/api/analyze-batch?format=html', Locked = true;
        LargeBatchConfirmQst: Label 'You are about to analyze %1 profiles. This may take several minutes.\Do you want to continue?', Comment = '%1 = number of profiles';
        NoProfilesErr: Label 'No profiles with data were found. Make sure the selected profiles contain profiling data.';

    trigger OnRun()
    begin
    end;

    procedure AnalyzeProfile(ProfileInStream: InStream; var HtmlResult: Text): Boolean
    var
        Client: HttpClient;
        RequestMsg: HttpRequestMessage;
        ResponseMsg: HttpResponseMessage;
        Content: HttpContent;
        Headers: HttpHeaders;
        BodyTempBlob: Codeunit "Temp Blob";
        BodyInStream: InStream;
        ContentType: Text;
        ResponseText: Text;
        StatusCode: Integer;
    begin
        CrLf[1] := 13;
        CrLf[2] := 10;

        BuildMultipartBody(ProfileInStream, BodyTempBlob, ContentType);
        BodyTempBlob.CreateInStream(BodyInStream);

        Content.WriteFrom(BodyInStream);
        Content.GetHeaders(Headers);
        if Headers.Contains('Content-Type') then
            Headers.Remove('Content-Type');
        Headers.Add('Content-Type', ContentType);

        RequestMsg.Method('POST');
        RequestMsg.SetRequestUri(ApiBaseUrl + ApiPath);
        RequestMsg.Content(Content);

        Client.Timeout(120000);

        if not Client.Send(RequestMsg, ResponseMsg) then
            Error(ConnectionErr, ApiBaseUrl);

        StatusCode := ResponseMsg.HttpStatusCode();
        ResponseMsg.Content().ReadAs(ResponseText);

        if (StatusCode < 200) or (StatusCode >= 300) then begin
            if StrLen(ResponseText) > 500 then
                ResponseText := CopyStr(ResponseText, 1, 500) + '...';
            Error(HttpErrorErr, StatusCode, ResponseText);
        end;

        HtmlResult := ResponseText;
        exit(true);
    end;

    local procedure BuildMultipartBody(ProfileInStream: InStream; var TempBlob: Codeunit "Temp Blob"; var ContentType: Text)
    var
        OutStr: OutStream;
        Boundary: Text;
        BoundaryGuid: Guid;
    begin
        BoundaryGuid := CreateGuid();
        Boundary := DelChr(Format(BoundaryGuid), '=', '{}');

        TempBlob.CreateOutStream(OutStr, TextEncoding::UTF8);
        OutStr.WriteText('--' + Boundary + CrLf);
        OutStr.WriteText('Content-Disposition: form-data; name="profile"; filename="profile.alcpuprofile"' + CrLf);
        OutStr.WriteText('Content-Type: application/octet-stream' + CrLf);
        OutStr.WriteText(CrLf);
        CopyStream(OutStr, ProfileInStream);
        OutStr.WriteText(CrLf + '--' + Boundary + '--' + CrLf);

        ContentType := 'multipart/form-data; boundary=' + Boundary;
    end;

    procedure AnalyzeBatch(var PerfProfile: Record "Performance Profiles"; var HtmlResult: Text): Boolean
    var
        Client: HttpClient;
        RequestMsg: HttpRequestMessage;
        ResponseMsg: HttpResponseMessage;
        Content: HttpContent;
        Headers: HttpHeaders;
        BodyTempBlob: Codeunit "Temp Blob";
        BodyInStream: InStream;
        ContentType: Text;
        ResponseText: Text;
        StatusCode: Integer;
        ValidProfileCount: Integer;
    begin
        CrLf[1] := 13;
        CrLf[2] := 10;

        if PerfProfile.Count() > 20 then
            if not Confirm(LargeBatchConfirmQst, false, PerfProfile.Count()) then
                exit(false);

        BuildBatchMultipartBody(PerfProfile, BodyTempBlob, ContentType, ValidProfileCount);

        if ValidProfileCount = 0 then
            Error(NoProfilesErr);

        BodyTempBlob.CreateInStream(BodyInStream);

        Content.WriteFrom(BodyInStream);
        Content.GetHeaders(Headers);
        if Headers.Contains('Content-Type') then
            Headers.Remove('Content-Type');
        Headers.Add('Content-Type', ContentType);

        RequestMsg.Method('POST');
        RequestMsg.SetRequestUri(ApiBaseUrl + ApiBatchPath);
        RequestMsg.Content(Content);

        Client.Timeout(300000);

        if not Client.Send(RequestMsg, ResponseMsg) then
            Error(ConnectionErr, ApiBaseUrl);

        StatusCode := ResponseMsg.HttpStatusCode();
        ResponseMsg.Content().ReadAs(ResponseText);

        if (StatusCode < 200) or (StatusCode >= 300) then begin
            if StrLen(ResponseText) > 500 then
                ResponseText := CopyStr(ResponseText, 1, 500) + '...';
            Error(HttpErrorErr, StatusCode, ResponseText);
        end;

        HtmlResult := ResponseText;
        exit(true);
    end;

    local procedure BuildBatchMultipartBody(var PerfProfile: Record "Performance Profiles"; var TempBlob: Codeunit "Temp Blob"; var ContentType: Text; var ValidProfileCount: Integer)
    var
        PerfProfilerSchedule: Record "Perf. Profiler Schedule";
        OutStr: OutStream;
        ProfileInStream: InStream;
        Boundary: Text;
        BoundaryGuid: Guid;
        ManifestArray: JsonArray;
        MetadataObj: JsonObject;
        ManifestText: Text;
        ProfileIndex: Integer;
    begin
        CrLf[1] := 13;
        CrLf[2] := 10;
        BoundaryGuid := CreateGuid();
        Boundary := DelChr(Format(BoundaryGuid), '=', '{}');
        ValidProfileCount := 0;

        // Pass 1: Build manifest JSON array from profiles with data
        if PerfProfile.FindSet() then
            repeat
                if PerfProfile.Profile.HasValue() then begin
                    ValidProfileCount += 1;

                    Clear(MetadataObj);
                    PerfProfile.CalcFields("User Name");
                    MetadataObj.Add('activityId', PerfProfile."Activity ID");
                    MetadataObj.Add('activityType', MapClientType(PerfProfile."Client Type"));
                    MetadataObj.Add('activityDescription', PerfProfile."Activity Description");
                    MetadataObj.Add('startTime', FormatDateTimeIso8601(PerfProfile."Starting Date-Time"));
                    MetadataObj.Add('activityDuration', PerfProfile."Activity Duration");
                    MetadataObj.Add('alExecutionDuration', PerfProfile.Duration);
                    MetadataObj.Add('sqlCallDuration', PerfProfile."Sql Call Duration");
                    MetadataObj.Add('sqlCallCount', PerfProfile."Sql Statement Number");
                    MetadataObj.Add('httpCallDuration', PerfProfile."Http Call Duration");
                    MetadataObj.Add('httpCallCount', PerfProfile."Http Call Number");
                    MetadataObj.Add('userName', PerfProfile."User Name");
                    MetadataObj.Add('clientSessionId', PerfProfile."Client Session ID");

                    if PerfProfile."Schedule ID" <> '' then begin
                        if PerfProfilerSchedule.Get(PerfProfile."Schedule ID") then
                            MetadataObj.Add('scheduleDescription', PerfProfilerSchedule.Description);
                    end;

                    ManifestArray.Add(MetadataObj);
                end;
            until PerfProfile.Next() = 0;

        if ValidProfileCount = 0 then
            exit;

        ManifestArray.WriteTo(ManifestText);

        // Write multipart body
        TempBlob.CreateOutStream(OutStr, TextEncoding::UTF8);

        // Manifest part
        OutStr.WriteText('--' + Boundary + CrLf);
        OutStr.WriteText('Content-Disposition: form-data; name="manifest"' + CrLf);
        OutStr.WriteText('Content-Type: application/json' + CrLf);
        OutStr.WriteText(CrLf);
        OutStr.WriteText(ManifestText);

        // Pass 2: Write profile binary parts
        ProfileIndex := 0;
        if PerfProfile.FindSet() then
            repeat
                if PerfProfile.Profile.HasValue() then begin
                    ProfileIndex += 1;
                    PerfProfile.Profile.CreateInStream(ProfileInStream);

                    OutStr.WriteText(CrLf + '--' + Boundary + CrLf);
                    OutStr.WriteText('Content-Disposition: form-data; name="profiles[]"; filename="profile-' + Format(ProfileIndex) + '.alcpuprofile"' + CrLf);
                    OutStr.WriteText('Content-Type: application/octet-stream' + CrLf);
                    OutStr.WriteText(CrLf);
                    CopyStream(OutStr, ProfileInStream);
                end;
            until PerfProfile.Next() = 0;

        OutStr.WriteText(CrLf + '--' + Boundary + '--' + CrLf);

        ContentType := 'multipart/form-data; boundary=' + Boundary;
    end;

    local procedure MapClientType(ClientType: Option): Text
    begin
        case ClientType of
            0: // Windows Client
                exit('WebClient');
            1: // Web Client
                exit('WebClient');
            2: // Web Service
                exit('WebServiceAPI');
            3: // Background
                exit('Background');
            else
                exit('WebClient');
        end;
    end;

    local procedure FormatDateTimeIso8601(Value: DateTime): Text
    begin
        exit(Format(Value, 0, 9));
    end;
}
