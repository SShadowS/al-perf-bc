codeunit 70507 "AL Perf Upgrade"
{
    Subtype = Upgrade;

    trigger OnUpgradePerCompany()
    begin
        UpgradeCanaryJitterDefault();
    end;

    /// "Canary Jitter (max minutes)" field(110) got InitValue = 10, but that only
    /// applies to newly-Init'd setup records. Existing installs already have a setup
    /// row (AL Perf Ship Setup.GetOrCreate inserts one on first use), so on upgrade
    /// they land jitter = 0 — silently OFF for exactly the deployed fleet this
    /// hardening exists to desynchronize. Backfill it once; gated by an upgrade tag
    /// so a tenant that deliberately disables jitter afterwards (sets it back to 0)
    /// doesn't get it silently reset to 10 again on the next upgrade.
    local procedure UpgradeCanaryJitterDefault()
    var
        Setup: Record "AL Perf Ship Setup";
        UpgradeTag: Codeunit "Upgrade Tag";
    begin
        if UpgradeTag.HasUpgradeTag(CanaryJitterDefaultUpgradeTag()) then
            exit;

        if Setup.Get('') then
            if Setup."Canary Jitter (max minutes)" = 0 then begin
                Setup."Canary Jitter (max minutes)" := 10;
                Setup.Modify();
            end;

        UpgradeTag.SetUpgradeTag(CanaryJitterDefaultUpgradeTag());
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"Upgrade Tag", 'OnGetPerCompanyUpgradeTags', '', false, false)]
    local procedure RegisterPerCompanyUpgradeTags(var PerCompanyUpgradeTags: List of [Code[250]])
    begin
        // New companies (and new installs) start from InitValue = 10 already, so the
        // backfill logic above does not apply to them — registering the tag here
        // marks it pre-applied for newly-created companies.
        PerCompanyUpgradeTags.Add(CanaryJitterDefaultUpgradeTag());
    end;

    local procedure CanaryJitterDefaultUpgradeTag(): Code[250]
    begin
        exit('SShadowS-ALPerf-CanaryJitterDefault-20260712');
    end;
}
