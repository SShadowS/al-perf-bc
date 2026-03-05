pageextension 70502 "Perf Schedules AL Perf Ext" extends "Perf. Profiler Schedules List"
{
    layout
    {
        addlast(content)
        {
            group(AnalysisResultsGroup)
            {
                Caption = 'AI Analysis Results';
                Visible = ShowResults;

                usercontrol(AnalysisResults; WebPageViewer)
                {
                    ApplicationArea = All;

                    trigger ControlAddInReady(callbackUrl: Text)
                    begin
                        IsControlReady := true;
                        if HtmlContent <> '' then
                            CurrPage.AnalysisResults.SetContent(HtmlContent);
                    end;

                    trigger Refresh(callbackUrl: Text)
                    begin
                        if HtmlContent <> '' then
                            CurrPage.AnalysisResults.SetContent(HtmlContent);
                    end;
                }
            }
        }
    }

    actions
    {
        addlast(Processing)
        {
            action(AnalyzeScheduleWithAlPerf)
            {
                ApplicationArea = All;
                Caption = 'Analyze with AL Perf';
                ToolTip = 'Send all profiles for this schedule to the AL Perf Analyzer service for batch performance analysis.';
                Image = AnalysisView;
                Promoted = true;
                PromotedCategory = Process;
                PromotedIsBig = true;

                trigger OnAction()
                var
                    AlPerfAnalyzer: Codeunit "Al Perf Analyzer";
                    PerfProfile: Record "Performance Profiles";
                    ProgressDialog: Dialog;
                    AnalyzingMsg: Label 'Analyzing profiles for schedule "%1"...\This may take several minutes for AI-powered insights.', Comment = '%1 = schedule description';
                begin
                    PerfProfile.SetRange("Schedule ID", Rec."Schedule ID");
                    ProgressDialog.Open(StrSubstNo(AnalyzingMsg, Rec.Description));
                    if AlPerfAnalyzer.AnalyzeBatch(PerfProfile, HtmlContent) then begin
                        ProgressDialog.Close();
                        ShowResults := true;
                        if IsControlReady then
                            CurrPage.AnalysisResults.SetContent(HtmlContent);
                        CurrPage.Update(false);
                    end else
                        ProgressDialog.Close();
                end;
            }

            action(DownloadScheduleAnalysis)
            {
                ApplicationArea = All;
                Caption = 'Download Analysis';
                ToolTip = 'Download the schedule analysis report as an HTML file.';
                Image = ExportFile;
                Enabled = ShowResults;

                trigger OnAction()
                var
                    TempBlob: Codeunit "Temp Blob";
                    OutStr: OutStream;
                    InStr: InStream;
                    FileName: Text;
                begin
                    TempBlob.CreateOutStream(OutStr, TextEncoding::UTF8);
                    OutStr.WriteText(HtmlContent);
                    TempBlob.CreateInStream(InStr);
                    FileName := 'AL-Perf-Schedule-Analysis.html';
                    DownloadFromStream(InStr, 'Download Schedule Analysis Report', '', 'HTML Files (*.html)|*.html', FileName);
                end;
            }
        }
    }

    var
        HtmlContent: Text;
        ShowResults: Boolean;
        IsControlReady: Boolean;
}
