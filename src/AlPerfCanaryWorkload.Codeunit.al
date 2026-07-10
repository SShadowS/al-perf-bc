codeunit 70506 "AL Perf Canary Workload"
{
    Access = Public;

    trigger OnRun()
    begin
        RunQueryLoop();
    end;

    /// Harmless, representative synthetic load: repeated filtered reads against
    /// the extension's own ship log plus JSON build/parse work. No writes.
    /// Sized to run roughly 1-3 seconds so 50 ms sampling collects enough samples.
    local procedure RunQueryLoop()
    var
        ShipLog: Record "AL Perf Ship Log";
        Payload: JsonObject;
        Parsed: JsonObject;
        PayloadText: Text;
        StartTime: DateTime;
        TargetDurationMs: Integer;
        MaxIterations: Integer;
        i: Integer;
        Total: Integer;
    begin
        // Duration-bound rather than iteration-bound: iteration cost depends on live
        // "AL Perf Ship Log" row counts, so a fixed iteration count can finish in well
        // under a second on a fresh environment, defeating the 1-3 s sampling window.
        TargetDurationMs := 2000;
        // Hard safety cap so a clock anomaly (e.g. system clock jump) can never spin forever.
        MaxIterations := 1000000;

        StartTime := CurrentDateTime;
        repeat
            i += 1;

            ShipLog.Reset();
            ShipLog.SetRange(Status, ShipLog.Status::Shipped);
            Total += ShipLog.Count();

            Clear(Payload);
            Payload.Add('iteration', i);
            Payload.Add('shippedCount', Total);
            Payload.Add('timestamp', Format(CurrentDateTime, 0, 9));
            Payload.WriteTo(PayloadText);
            if Parsed.ReadFrom(PayloadText) then;
        until ((CurrentDateTime - StartTime) >= TargetDurationMs) or (i >= MaxIterations);
    end;
}
