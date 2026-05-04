codeunit 70504 "AL Perf Crypto"
{
    Access = Public;

    var
        PublicKeyKeyTok: Label 'al-perf-public-key', Locked = true;
        PrivateKeyKeyTok: Label 'al-perf-private-key', Locked = true;

    procedure HasKeypair(): Boolean
    var
        Dummy: SecretText;
    begin
        exit(IsolatedStorage.Get(PrivateKeyKeyTok, DataScope::Module, Dummy));
    end;

    procedure GenerateKeypair()
    var
        RsaCu: Codeunit System.Security.Encryption."RSA";
        PublicKeyXml: SecretText;
        PrivateKeyXml: SecretText;
    begin
        RsaCu.InitializeRSA(3072);
        PublicKeyXml := RsaCu.ToSecretXmlString(false);
        PrivateKeyXml := RsaCu.ToSecretXmlString(true);
        IsolatedStorage.Set(PublicKeyKeyTok, SecretStrSubstNo('%1', PublicKeyXml), DataScope::Module);
        IsolatedStorage.Set(PrivateKeyKeyTok, PrivateKeyXml, DataScope::Module);
    end;

    procedure GetCurrentPublicKeyXml(): Text
    var
        Pub: SecretText;
    begin
        if not IsolatedStorage.Get(PublicKeyKeyTok, DataScope::Module, Pub) then
            Error('Public key not generated. Call GenerateKeypair first.');
        exit(Pub.Unwrap());
    end;

    /// Stub: return SHA-256 prefix of the public key XML.
    procedure ComputeFingerprint(PublicKeyXml: Text): Text
    var
        CryptoMgmt: Codeunit "Cryptography Management";
        FullHash: Text;
    begin
        FullHash := CryptoMgmt.GenerateHash(PublicKeyXml, 3); // 3 = SHA256
        if StrLen(FullHash) >= 24 then
            exit('SHA256:' + CopyStr(FullHash, 1, 24))
        else
            exit('SHA256:' + FullHash);
    end;
}
