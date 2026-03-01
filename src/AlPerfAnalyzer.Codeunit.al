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
}
