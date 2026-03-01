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

                usercontrol(AnalysisResults; "Microsoft.Dynamics.Nav.Client.WebPageViewer")
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
                Image = Analyze;
                Promoted = true;
                PromotedCategory = Process;
                PromotedIsBig = true;

                trigger OnAction()
                var
                    AlPerfAnalyzer: Codeunit "Al Perf Analyzer";
                    SamplingPerfProfiler: Codeunit "Sampling Performance Profiler";
                    ProfileInStream: InStream;
                    ProgressDialog: Dialog;
                    AnalyzingMsg: Label 'Analyzing profile...\This may take up to 30 seconds for AI-powered insights.';
                    NoDataMsg: Label 'No profile data available. Please record a profiling session and stop it before analyzing.';
                    SuccessMsg: Label 'Analysis complete. Results are displayed below.';
                begin
                    if not TryGetProfileData(SamplingPerfProfiler, ProfileInStream) then begin
                        Message(NoDataMsg);
                        exit;
                    end;

                    ProgressDialog.Open(AnalyzingMsg);

                    if AlPerfAnalyzer.AnalyzeProfile(ProfileInStream, HtmlContent) then begin
                        ShowResults := true;
                        ProgressDialog.Close();
                        if IsControlReady then
                            CurrPage.AnalysisResults.SetContent(HtmlContent);
                        CurrPage.Update(false);
                        Message(SuccessMsg);
                    end;
                end;
            }

            action(ViewInBrowser)
            {
                ApplicationArea = All;
                Caption = 'View in Browser';
                ToolTip = 'Open the AL Perf Analyzer web app in your browser to upload and analyze profiles with the full web experience.';
                Image = Web;
                Visible = ShowResults;

                trigger OnAction()
                begin
                    HyperLink('https://alperf.sshadows.dk');
                end;
            }
        }
    }

    var
        HtmlContent: Text;
        ShowResults: Boolean;
        IsControlReady: Boolean;

    [TryFunction]
    local procedure TryGetProfileData(var SamplingPerfProfiler: Codeunit "Sampling Performance Profiler"; var ProfileInStream: InStream)
    begin
        SamplingPerfProfiler.GetData(ProfileInStream);
    end;
}
