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
        i: Integer;
        Total: Integer;
    begin
        for i := 1 to 1000 do begin
            ShipLog.Reset();
            ShipLog.SetRange(Status, ShipLog.Status::Shipped);
            Total += ShipLog.Count();

            Clear(Payload);
            Payload.Add('iteration', i);
            Payload.Add('shippedCount', Total);
            Payload.Add('timestamp', Format(CurrentDateTime, 0, 9));
            Payload.WriteTo(PayloadText);
            if Parsed.ReadFrom(PayloadText) then;
        end;
    end;
}
