table 70504 "AL Perf Ship Log"
{
    Caption = 'AL Perf Ship Log';
    DataClassification = SystemMetadata;
    LookupPageId = "AL Perf Ship Log List";
    DrillDownPageId = "AL Perf Ship Log List";

    fields
    {
        field(1; "Activity ID"; Guid)
        {
            Caption = 'Activity ID';
            NotBlank = true;
            DataClassification = SystemMetadata;
        }
        field(10; "Schedule ID"; Guid)
        {
            Caption = 'Schedule ID';
            DataClassification = SystemMetadata;
        }
        field(20; "Activity Description"; Text[250])
        {
            Caption = 'Activity Description';
            DataClassification = SystemMetadata;
        }
        field(30; "Starting Date-Time"; DateTime)
        {
            Caption = 'Starting Date-Time';
            DataClassification = SystemMetadata;
        }
        field(40; Status; Enum "AL Perf Ship Status")
        {
            Caption = 'Status';
            DataClassification = SystemMetadata;
        }
        field(50; "Shipped At"; DateTime)
        {
            Caption = 'Shipped At';
            DataClassification = SystemMetadata;
        }
        field(60; "HTTP Status"; Integer)
        {
            Caption = 'HTTP Status';
            DataClassification = SystemMetadata;
        }
        field(70; "Error Message"; Text[500])
        {
            Caption = 'Error Message';
            DataClassification = SystemMetadata;
        }
        field(80; "Profile Size (bytes)"; BigInteger)
        {
            Caption = 'Profile Size (bytes)';
            DataClassification = SystemMetadata;
        }
        field(90; "Server Profile ID"; Text[100])
        {
            Caption = 'Server Profile ID';
            DataClassification = SystemMetadata;
        }
        field(100; Canary; Boolean)
        {
            Caption = 'Canary';
            DataClassification = SystemMetadata;
        }
        field(110; Attempts; Integer)
        {
            Caption = 'Attempts';
            Editable = false;
            DataClassification = SystemMetadata;
        }
    }

    keys
    {
        key(PK; "Activity ID") { Clustered = true; }
        key(BySchedStart; "Schedule ID", "Starting Date-Time") { }
        key(ByStatus; Status) { }
    }

    fieldgroups
    {
        fieldgroup(DropDown; "Activity ID", Status, "Activity Description") { }
    }
}
