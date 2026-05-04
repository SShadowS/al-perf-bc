page 70504 "AL Perf Ship Log List"
{
    Caption = 'AL Perf Ship Log';
    PageType = List;
    SourceTable = "AL Perf Ship Log";
    UsageCategory = Lists;
    ApplicationArea = All;
    Editable = false;
    SourceTableView = sorting("Starting Date-Time") order(descending);

    layout
    {
        area(Content)
        {
            repeater(Logs)
            {
                field("Starting Date-Time"; Rec."Starting Date-Time") { ApplicationArea = All; }
                field("Activity Description"; Rec."Activity Description") { ApplicationArea = All; }
                field(Status; Rec.Status) { ApplicationArea = All; StyleExpr = StatusStyleExpr; }
                field("Shipped At"; Rec."Shipped At") { ApplicationArea = All; }
                field("HTTP Status"; Rec."HTTP Status") { ApplicationArea = All; }
                field("Error Message"; Rec."Error Message") { ApplicationArea = All; }
                field("Profile Size (bytes)"; Rec."Profile Size (bytes)") { ApplicationArea = All; }
                field("Activity ID"; Rec."Activity ID") { ApplicationArea = All; Visible = false; }
                field("Schedule ID"; Rec."Schedule ID") { ApplicationArea = All; Visible = false; }
            }
        }
    }

    actions
    {
        area(Processing)
        {
            action(OpenProfile)
            {
                Caption = 'Open Profile';
                ApplicationArea = All;
                Image = View;
                Promoted = true;
                PromotedCategory = Process;
                PromotedIsBig = true;

                trigger OnAction()
                var
                    AutoShip: Codeunit "AL Perf Auto Ship";
                begin
                    AutoShip.OpenProfile(Rec);
                end;
            }
        }
    }

    trigger OnAfterGetRecord()
    begin
        case Rec.Status of
            Rec.Status::Failed:
                StatusStyleExpr := 'Unfavorable';
            Rec.Status::Shipped:
                StatusStyleExpr := 'Favorable';
            else
                StatusStyleExpr := 'Standard';
        end;
    end;

    var
        StatusStyleExpr: Text;
}
