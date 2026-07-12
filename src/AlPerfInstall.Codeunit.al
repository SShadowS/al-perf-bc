codeunit 70508 "AL Perf Install"
{
    Subtype = Install;

    trigger OnInstallAppPerCompany()
    var
        Info: ModuleInfo;
        UpgradeTag: Codeunit "Upgrade Tag";
    begin
        NavApp.GetCurrentModuleInfo(Info);
        // A genuinely fresh install (DataVersion 0.0.0.0 — no prior data for this app
        // in this company) starts from every field's InitValue already, so none of the
        // per-company backfills in AL Perf Upgrade apply — pre-mark them all applied.
        // Without this, OnGetPerCompanyUpgradeTags only pre-seeds tags for a NEWLY
        // CREATED company; installing this app fresh into an EXISTING company (the
        // common case) would otherwise leave the tag unset, so the next real upgrade
        // would run AL Perf Upgrade's backfill and clobber a jitter value the tenant
        // deliberately set to 0.
        if Info.DataVersion() = Version.Create(0, 0, 0, 0) then
            UpgradeTag.SetAllUpgradeTags();
    end;
}
