pageextension 70500 "Perf Profiler AL Perf Ext" extends "Performance Profiler"
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
            action(AnalyzeWithAlPerf)
            {
                ApplicationArea = All;
                Caption = 'Analyze with AL Perf';
                ToolTip = 'Send the recorded profile to the AL Perf Analyzer service for AI-powered performance analysis.';
                Image = LineDescription;
                Promoted = true;
                PromotedCategory = Process;
                PromotedIsBig = true;
                Enabled = HasProfileData;

                trigger OnAction()
                var
                    AlPerfAnalyzer: Codeunit "Al Perf Analyzer";
                    SamplingPerfProfiler: Codeunit "Sampling Performance Profiler";
                    ProfileInStream: InStream;
                    ProgressDialog: Dialog;
                    AnalyzingMsg: Label 'Analyzing profile...\This may take up to 30 seconds for AI-powered insights.';
                    NoDataMsg: Label 'No profile data available. Please record a profiling session and stop it before analyzing.';
                begin
                    if not TryGetProfileData(SamplingPerfProfiler) then begin
                        Message(NoDataMsg);
                        exit;
                    end;
                    ProfileInStream := SamplingPerfProfiler.GetData();

                    ProgressDialog.Open(AnalyzingMsg);

                    if AlPerfAnalyzer.AnalyzeProfile(ProfileInStream, HtmlContent) then begin
                        ProgressDialog.Close();
                        ShowResults := true;
                        if IsControlReady then
                            CurrPage.AnalysisResults.SetContent(HtmlContent);
                        CurrPage.Update(false);
                    end;
                end;
            }

            action(DownloadAnalysis)
            {
                ApplicationArea = All;
                Caption = 'Download Analysis';
                ToolTip = 'Download the AI analysis report as an HTML file.';
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
                    FileName := 'AL-Perf-Analysis.html';
                    DownloadFromStream(InStr, 'Download Analysis Report', '', 'HTML Files (*.html)|*.html', FileName);
                end;
            }

            action(ViewInBrowser)
            {
                ApplicationArea = All;
                Caption = 'View in Browser';
                ToolTip = 'Open the AL Perf Analyzer web app in your browser to upload and analyze profiles with the full web experience.';
                Image = Web;

                trigger OnAction()
                begin
                    HyperLink('https://alperf.sshadows.dk');
                end;
            }
        }
    }

    trigger OnAfterGetCurrRecord()
    var
        SamplingPerfProfiler: Codeunit "Sampling Performance Profiler";
    begin
        HasProfileData := TryGetProfileData(SamplingPerfProfiler);
    end;

    var
        HtmlContent: Text;
        ShowResults: Boolean;
        IsControlReady: Boolean;
        HasProfileData: Boolean;

    [TryFunction]
    local procedure TryGetProfileData(var SamplingPerfProfiler: Codeunit "Sampling Performance Profiler")
    begin
        SamplingPerfProfiler.GetData();
    end;
}
