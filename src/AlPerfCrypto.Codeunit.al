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
        IsolatedStorage.Set(PublicKeyKeyTok, PublicKeyXml.Unwrap(), DataScope::Module);
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

    procedure GetPrivateKeyXml(var KeyXml: SecretText): Boolean
    begin
        exit(IsolatedStorage.Get(PrivateKeyKeyTok, DataScope::Module, KeyXml));
    end;

    procedure ComputeFingerprint(PublicKeyXml: Text): Text
    var
        CryptoMgmt: Codeunit "Cryptography Management";
        FullHash: Text;
    begin
        FullHash := CryptoMgmt.GenerateHash(PublicKeyXml, 3); // SHA256
        exit('SHA256:' + CopyStr(FullHash, 1, 24));
    end;

    /// Decrypt the bundle returned from /api/profiles/{id}.
    /// Inputs (all Base64-decoded by caller into TempBlob InStreams or Base64 text):
    ///   WrappedInStream     — RSA-OAEP-SHA1(K_enc || K_mac)
    ///   ManifestInStream    — manifest bytes (will be SHA-256 hashed for HMAC binding)
    ///   IvBlobBase64, TagBlobBase64 — Base64 strings (16 + 32 bytes)
    ///   CipherBlobInStream  — ciphertext bytes (binary, AES-CBC output)
    ///   Same for result.
    /// Outputs:
    ///   PlaintextBlobOutStream, PlaintextResultOutStream — written by decrypt.
    /// Returns false on tag mismatch (do NOT call Error in that case so caller can mark TamperedOnRead).
    procedure DecryptBundle(
        WrappedInStream: InStream;
        ManifestInStream: InStream;
        IvBlobBase64: Text;
        TagBlobBase64: Text;
        CipherBlobInStream: InStream;
        IvResultBase64: Text;
        TagResultBase64: Text;
        CipherResultInStream: InStream;
        var PlaintextBlobOutStream: OutStream;
        var PlaintextResultOutStream: OutStream): Boolean
    var
        RsaCu: Codeunit System.Security.Encryption."RSA";
        Rijndael: Codeunit "Rijndael Cryptography";
        CryptoMgmt: Codeunit "Cryptography Management";
        PrivateKeyXml: SecretText;
        KeyOutTempBlob: Codeunit "Temp Blob";
        KeyOutStream: OutStream;
        KeyInStream: InStream;
        KeyBytesBase64: Text;
        KEncBase64: Text;
        KMacBase64: Text;
        ManifestUtf8TempBlob: Codeunit "Temp Blob";
        ManifestOutStr: OutStream;
        ManifestUtf8InStr: InStream;
        ManifestText: Text;
        ManifestHashB64: Text;
        CipherBlobBase64: Text;
        CipherResultBase64: Text;
        ExpectedTagBlob: Text;
        ExpectedTagResult: Text;
        BlobInputBuilder: TextBuilder;
        ResultInputBuilder: TextBuilder;
        Base64: Codeunit "Base64 Convert";
    begin
        if not GetPrivateKeyXml(PrivateKeyXml) then
            Error('Private key missing.');

        // 1. Unwrap K_enc || K_mac via RSA-OAEP
        KeyOutTempBlob.CreateOutStream(KeyOutStream);
        RsaCu.Decrypt(PrivateKeyXml, WrappedInStream, true, KeyOutStream);
        KeyOutTempBlob.CreateInStream(KeyInStream);
        KeyBytesBase64 := Base64.ToBase64(KeyInStream);
        // KeyBytesBase64 contains 64 raw bytes encoded → 88 chars Base64 (no padding offset issue)
        // Split: first 32 bytes = K_enc, next 32 = K_mac.
        // Convert via Base64Convert helpers.
        SplitKeys(KeyBytesBase64, KEncBase64, KMacBase64);

        // Buffer ciphertext streams as Base64 text so BuildHmacInput and DecryptToOutStream can each use them.
        CipherBlobBase64 := Base64.ToBase64(CipherBlobInStream);
        CipherResultBase64 := Base64.ToBase64(CipherResultInStream);

        // 2. Hash manifest bytes
        // Buffer manifest InStream and re-read as UTF-8 Text so we can use the
        // (Text, HashAlgorithmType) overload — there is no (InStream, ...) overload.
        ManifestUtf8TempBlob.CreateOutStream(ManifestOutStr);
        CopyStream(ManifestOutStr, ManifestInStream);
        ManifestUtf8TempBlob.CreateInStream(ManifestUtf8InStr, TextEncoding::UTF8);
        ManifestUtf8InStr.ReadText(ManifestText);
        ManifestHashB64 := CryptoMgmt.GenerateHashAsBase64String(ManifestText, 3); // SHA256

        // 3. Build HMAC inputs:  IV || manifestHash || ciphertext  (raw bytes)
        BuildHmacInput(IvBlobBase64, ManifestHashB64, CipherBlobBase64, BlobInputBuilder);
        ExpectedTagBlob := CryptoMgmt.GenerateHashAsBase64String(BlobInputBuilder.ToText(), KMacBase64, 3); // HMACSHA256
        if not StringsEqualFixedLength(ExpectedTagBlob, TagBlobBase64) then
            exit(false);

        BuildHmacInput(IvResultBase64, ManifestHashB64, CipherResultBase64, ResultInputBuilder);
        ExpectedTagResult := CryptoMgmt.GenerateHashAsBase64String(ResultInputBuilder.ToText(), KMacBase64, 3);
        if not StringsEqualFixedLength(ExpectedTagResult, TagResultBase64) then
            exit(false);

        // 4. Decrypt blob
        Rijndael.SetEncryptionData(KEncBase64, IvBlobBase64);
        DecryptToOutStream(Rijndael, CipherBlobBase64, PlaintextBlobOutStream);

        // 5. Decrypt result
        Rijndael.SetEncryptionData(KEncBase64, IvResultBase64);
        DecryptToOutStream(Rijndael, CipherResultBase64, PlaintextResultOutStream);

        exit(true);
    end;

    local procedure SplitKeys(KeyBytesBase64: Text; var KEncBase64: Text; var KMacBase64: Text)
    var
        Base64: Codeunit "Base64 Convert";
        Bytes: List of [Byte];
        EncBytes: List of [Byte];
        MacBytes: List of [Byte];
        I: Integer;
        TempBlob: Codeunit "Temp Blob";
        OutStr: OutStream;
        InStr: InStream;
    begin
        // Decode the 64-byte concatenation, then re-encode each 32-byte half.
        TempBlob.CreateOutStream(OutStr);
        Base64.FromBase64(KeyBytesBase64, OutStr);
        TempBlob.CreateInStream(InStr);
        // Read 32 bytes for K_enc, then remainder for K_mac
        ReadFixedAndEncode(InStr, 32, KEncBase64);
        ReadFixedAndEncode(InStr, 32, KMacBase64);
    end;

    local procedure ReadFixedAndEncode(var SourceInStream: InStream; ByteCount: Integer; var TargetBase64: Text)
    var
        Base64: Codeunit "Base64 Convert";
        SegBlob: Codeunit "Temp Blob";
        SegOut: OutStream;
        SegIn: InStream;
        Buf: Char;
        I: Integer;
    begin
        SegBlob.CreateOutStream(SegOut);
        for I := 1 to ByteCount do begin
            SourceInStream.Read(Buf, 1);
            SegOut.Write(Buf);
        end;
        SegBlob.CreateInStream(SegIn);
        TargetBase64 := Base64.ToBase64(SegIn);
    end;

    local procedure BuildHmacInput(IvBase64: Text; ManifestHashBase64: Text; CipherBase64: Text; var Builder: TextBuilder)
    var
        Base64: Codeunit "Base64 Convert";
        TempBlob: Codeunit "Temp Blob";
        OutStr: OutStream;
        InStr: InStream;
        AllBase64: Text;
    begin
        // Concatenate IV bytes || manifestHash bytes || ciphertext bytes, re-encode whole thing as Base64 text.
        // We then HMAC over the Base64 text, matching server side which does the same (Strategy B).
        TempBlob.CreateOutStream(OutStr);
        Base64.FromBase64(IvBase64, OutStr);
        Base64.FromBase64(ManifestHashBase64, OutStr);
        Base64.FromBase64(CipherBase64, OutStr);
        TempBlob.CreateInStream(InStr);
        AllBase64 := Base64.ToBase64(InStr);
        Builder.Append(AllBase64);
    end;

    local procedure DecryptToOutStream(var Rijndael: Codeunit "Rijndael Cryptography"; CipherBase64: Text; var PlainOutStream: OutStream)
    var
        Base64: Codeunit "Base64 Convert";
        PlainBase64: Text;
    begin
        PlainBase64 := Rijndael.DecryptBinaryData(CipherBase64);
        Base64.FromBase64(PlainBase64, PlainOutStream);
    end;

    local procedure StringsEqualFixedLength(A: Text; B: Text): Boolean
    begin
        // Both Base64 of fixed-length 32-byte tags → both 44 chars. Simple compare.
        if StrLen(A) <> StrLen(B) then
            exit(false);
        exit(A = B);
    end;
}
