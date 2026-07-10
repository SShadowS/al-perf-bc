table 70503 "AL Perf Ship Setup"
{
    Caption = 'AL Perf Ship Setup';
    DataClassification = SystemMetadata;

    fields
    {
        field(1; "Primary Key"; Code[10])
        {
            Caption = 'Primary Key';
            DataClassification = SystemMetadata;
        }
        field(10; Enabled; Boolean)
        {
            Caption = 'Enabled';
            DataClassification = SystemMetadata;
        }
        field(20; "Tenant Code"; Code[40])
        {
            Caption = 'Tenant Code';
            DataClassification = SystemMetadata;
        }
        field(30; "Server URL Base"; Text[250])
        {
            Caption = 'Server URL Base';
            ExtendedDatatype = URL;
            DataClassification = SystemMetadata;
        }
        field(40; "Last Run DateTime"; DateTime)
        {
            Caption = 'Last Run';
            Editable = false;
            DataClassification = SystemMetadata;
        }
        field(50; "Last Error"; Text[500])
        {
            Caption = 'Last Error';
            Editable = false;
            DataClassification = SystemMetadata;
        }
        field(60; "Public Key Fingerprint"; Text[80])
        {
            Caption = 'Public Key Fingerprint';
            Editable = false;
            DataClassification = SystemMetadata;
        }
        field(70; "Bearer Secret (write-only)"; Text[200])
        {
            Caption = 'Registration Secret (write-only)';
            DataClassification = CustomerContent;

            trigger OnValidate()
            var
                AutoShip: Codeunit "AL Perf Auto Ship";
            begin
                if "Bearer Secret (write-only)" = '' then
                    exit;
                AutoShip.SetBearerSecret("Bearer Secret (write-only)");
                Clear("Bearer Secret (write-only)");
                Modify();
            end;
        }
        field(80; "Canary Enabled"; Boolean)
        {
            Caption = 'Canary Enabled';
            DataClassification = SystemMetadata;
        }
        field(90; "Canary Workload Codeunit ID"; Integer)
        {
            Caption = 'Canary Workload Codeunit ID';
            DataClassification = SystemMetadata;
            TableRelation = AllObjWithCaption."Object ID" where("Object Type" = const(Codeunit));
            BlankZero = true;
        }
        field(100; "Canary Description"; Text[250])
        {
            Caption = 'Canary Description';
            DataClassification = SystemMetadata;
        }
    }

    keys
    {
        key(PK; "Primary Key") { Clustered = true; }
    }

    procedure GetOrCreate(): Record "AL Perf Ship Setup"
    var
        Setup: Record "AL Perf Ship Setup";
    begin
        if not Setup.Get('') then begin
            Setup.Init();
            Setup."Primary Key" := '';
            Setup.Insert();
        end;
        exit(Setup);
    end;
}
