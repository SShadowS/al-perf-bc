pageextension 70501 "Perf Profile List AL Perf Ext" extends "Performance Profile List"
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
            action(AnalyzeSelectedWithAlPerf)
            {
                ApplicationArea = All;
                Caption = 'Analyze Selected with AL Perf';
                ToolTip = 'Send the selected profiles to the AL Perf Analyzer service for batch performance analysis.';
                Image = AnalysisView;
                Promoted = true;
                PromotedCategory = Process;
                PromotedIsBig = true;

                trigger OnAction()
                var
                    AlPerfAnalyzer: Codeunit "Al Perf Analyzer";
                    PerfProfile: Record "Performance Profiles";
                    ProgressDialog: Dialog;
                    AnalyzingMsg: Label 'Analyzing %1 selected profiles...\This may take several minutes for AI-powered insights.', Comment = '%1 = number of profiles';
                begin
                    CurrPage.SetSelectionFilter(PerfProfile);
                    ProgressDialog.Open(StrSubstNo(AnalyzingMsg, PerfProfile.Count()));
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

            action(AnalyzeAllFromSchedule)
            {
                ApplicationArea = All;
                Caption = 'Analyze All (Filtered) with AL Perf';
                ToolTip = 'Send all filtered profiles on this page to the AL Perf Analyzer service for batch performance analysis.';
                Image = AllLines;
                Promoted = true;
                PromotedCategory = Process;

                trigger OnAction()
                var
                    AlPerfAnalyzer: Codeunit "Al Perf Analyzer";
                    PerfProfile: Record "Performance Profiles";
                    ProgressDialog: Dialog;
                    AnalyzingMsg: Label 'Analyzing %1 profiles...\This may take several minutes for AI-powered insights.', Comment = '%1 = number of profiles';
                begin
                    PerfProfile.CopyFilters(Rec);
                    ProgressDialog.Open(StrSubstNo(AnalyzingMsg, PerfProfile.Count()));
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

            action(DownloadBatchAnalysis)
            {
                ApplicationArea = All;
                Caption = 'Download Analysis';
                ToolTip = 'Download the batch analysis report as an HTML file.';
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
                    FileName := 'AL-Perf-Batch-Analysis.html';
                    DownloadFromStream(InStr, 'Download Batch Analysis Report', '', 'HTML Files (*.html)|*.html', FileName);
                end;
            }
        }
    }

    var
        HtmlContent: Text;
        ShowResults: Boolean;
        IsControlReady: Boolean;
}
