page 70503 "AL Perf Ship Setup Card"
{
    Caption = 'AL Perf Ship Setup';
    PageType = Card;
    SourceTable = "AL Perf Ship Setup";
    UsageCategory = Administration;
    ApplicationArea = All;
    InsertAllowed = false;
    DeleteAllowed = false;

    layout
    {
        area(Content)
        {
            group(General)
            {
                Caption = 'General';
                field(Enabled; Rec.Enabled) { ApplicationArea = All; ToolTip = 'Master switch for the auto-ship Job Queue.'; }
                field("Tenant Code"; Rec."Tenant Code") { ApplicationArea = All; ToolTip = 'Identifier registered with al-perf service. Must match the tenantCode used at registration.'; }
                field("Server URL Base"; Rec."Server URL Base") { ApplicationArea = All; ToolTip = 'Base URL of the al-perf web server, e.g. https://alperf.example.com'; }
                field("Bearer Secret (write-only)"; Rec."Bearer Secret (write-only)")
                {
                    ApplicationArea = All;
                    ToolTip = 'Registration secret for /api/tenants/register. Stored to IsolatedStorage; the field is cleared on save. Ingest authenticates with the per-tenant token captured at registration, not this secret.';
                    ExtendedDatatype = Masked;
                }
            }
            group(Status)
            {
                Caption = 'Status';
                field("Last Run DateTime"; Rec."Last Run DateTime") { ApplicationArea = All; }
                field("Last Error"; Rec."Last Error") { ApplicationArea = All; }
                field("Public Key Fingerprint"; Rec."Public Key Fingerprint") { ApplicationArea = All; ToolTip = 'Fingerprint of the current public key registered with the server. Set when keypair is generated (v1).'; }
                field(TenantTokenStored; TenantTokenStored)
                {
                    ApplicationArea = All;
                    Caption = 'Tenant Token Stored';
                    Editable = false;
                    ToolTip = 'True when the per-tenant token issued at registration is stored. Without it, auto-ship falls back to the registration secret, which the server rejects unless AL_PERF_ALLOW_SHARED_SECRET=1.';
                }
            }
        }
    }

    actions
    {
        area(Processing)
        {
            action(Register)
            {
                Caption = 'Register Tenant';
                ApplicationArea = All;
                Image = SendApprovalRequest;

                trigger OnAction()
                begin
                    PocRegister(Rec);
                end;
            }

            action(ShipNow)
            {
                Caption = 'Ship Now';
                ApplicationArea = All;
                Image = SendTo;

                trigger OnAction()
                var
                    AutoShip: Codeunit "AL Perf Auto Ship";
                begin
                    AutoShip.ShipPending();
                    CurrPage.Update();
                    Message('Auto-ship run completed. See AL Perf Ship Log for results.');
                end;
            }

            action(OpenShipLog)
            {
                Caption = 'View Ship Log';
                ApplicationArea = All;
                Image = Log;
                RunObject = page "AL Perf Ship Log List";
            }
        }
    }

    var
        TenantTokenStored: Boolean;

    trigger OnOpenPage()
    var
        Setup: Record "AL Perf Ship Setup";
        AutoShip: Codeunit "AL Perf Auto Ship";
    begin
        Setup := Setup.GetOrCreate();
        Rec := Setup;
        TenantTokenStored := AutoShip.HasTenantToken();
    end;

    local procedure PocRegister(SetupRec: Record "AL Perf Ship Setup")
    var
        Crypto: Codeunit "AL Perf Crypto";
        AutoShip: Codeunit "AL Perf Auto Ship";
        Client: HttpClient;
        RequestMsg: HttpRequestMessage;
        ResponseMsg: HttpResponseMessage;
        Content: HttpContent;
        Headers: HttpHeaders;
        Body: JsonObject;
        ResponseJson: JsonObject;
        TokenValue: JsonToken;
        BodyText: Text;
        StatusCode: Integer;
        ResponseText: Text;
        PublicKeyXml: Text;
    begin
        if SetupRec."Tenant Code" = '' then
            Error('Tenant Code is required.');
        if SetupRec."Server URL Base" = '' then
            Error('Server URL Base is required.');

        if not Crypto.HasKeypair() then
            Crypto.GenerateKeypair();
        PublicKeyXml := Crypto.GetCurrentPublicKeyXml();

        Body.Add('tenantCode', SetupRec."Tenant Code");
        Body.Add('sharedSecret', AutoShip.GetBearerSecret());
        Body.Add('publicKeyXml', PublicKeyXml);
        Body.WriteTo(BodyText);

        Content.WriteFrom(BodyText);
        Content.GetHeaders(Headers);
        if Headers.Contains('Content-Type') then
            Headers.Remove('Content-Type');
        Headers.Add('Content-Type', 'application/json');

        RequestMsg.Method('POST');
        RequestMsg.SetRequestUri(SetupRec."Server URL Base" + '/api/tenants/register');
        RequestMsg.Content(Content);

        if not Client.Send(RequestMsg, ResponseMsg) then
            Error('Connection failed.');

        StatusCode := ResponseMsg.HttpStatusCode();
        ResponseMsg.Content().ReadAs(ResponseText);
        if (StatusCode < 200) or (StatusCode >= 300) then
            Error('Server returned HTTP %1: %2', StatusCode, ResponseText);

        SetupRec."Public Key Fingerprint" := CopyStr(Crypto.ComputeFingerprint(PublicKeyXml), 1, 80);
        SetupRec.Modify();

        // The per-tenant token is issued exactly once, in this response. Store it —
        // all ingest and profile-download calls authenticate with it from now on.
        if ResponseJson.ReadFrom(ResponseText) and ResponseJson.Get('tenantToken', TokenValue) then begin
            AutoShip.SetTenantToken(TokenValue.AsValue().AsText());
            TenantTokenStored := true;
            Message('Tenant registered. Per-tenant token stored — auto-ship authenticates with it.');
        end else
            Message('Tenant registered, but the server returned no tenant token. Auto-ship will fall back to the registration secret; the server rejects that unless AL_PERF_ALLOW_SHARED_SECRET=1.');
    end;
}
