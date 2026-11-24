# Phase 5 read-only SCM status extension. Owner: @DNPMBHC.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('before','after','diagnostic')][string]$Stage,
    [Parameter(Mandatory)][string]$StateFile,
    [string[]]$InstallRoot = @(),
    [string]$OutputFile,
    [ValidateRange(1,10000)][int]$MaxRootDriverFiles = 1000,
    [ValidateRange(1,10000)][int]$MaxRootDirectories = 2000,
    [ValidateRange(1,5000)][int]$MaxEvents = 500,
    [switch]$FullSignatureInventory,
    [switch]$AllowOnlineSignatureChecks
)

# Run only inside the isolated Guest. No driver/service paths, names, addresses,
# accounts, certificate serials or thumbprints are exported. StateFile contains
# DPAPI-protected random correlation material and opaque identity hashes only;
# it is Guest-local comparison state, not an evidence attachment.
# Baseline/after sampling proves only what the sampled stages actually exposed.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Notes = [Collections.Generic.List[string]]::new()
$script:Diagnostics = [Collections.Generic.List[object]]::new()

function Write-PrivateFile([string]$Path,[string]$Content,[switch]$Append) {
    if(Test-Path -LiteralPath $Path) {
        if(((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'A private state file cannot be a reparse point.' }
    } else { [IO.File]::WriteAllText($Path,'',[Text.UTF8Encoding]::new($false)) }
    $security=[Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true,$false)
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $security.SetOwner($owner)
    foreach($sid in @($owner,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))
    }
    Set-Acl -LiteralPath $Path -AclObject $security -ErrorAction Stop
    if($Append) { [IO.File]::AppendAllText($Path,$Content,[Text.UTF8Encoding]::new($false)) }
    else { [IO.File]::WriteAllText($Path,$Content,[Text.UTF8Encoding]::new($false)) }
}
function Save-PrivateException([string]$Scope,$ErrorRecord) {
    $type=$ErrorRecord.Exception.GetType().FullName
    if($type -notmatch '^(?:System|Microsoft)\.[A-Za-z0-9_.+`]+$') { $type='unclassified' }
    $line=if($null -ne $ErrorRecord.InvocationInfo) { [int]$ErrorRecord.InvocationInfo.ScriptLineNumber } else { 0 }
    $public=[pscustomobject]@{scope=$Scope; exception_type=$type; script_line=$line}
    $script:Diagnostics.Add($public)
    try {
        $private=[ordered]@{captured_at=[DateTimeOffset]::UtcNow.ToString('o'); scope=$Scope; exception=$ErrorRecord.Exception.ToString(); error_record=($ErrorRecord|Format-List * -Force|Out-String); script_stack=$ErrorRecord.ScriptStackTrace}
        Write-PrivateFile ($StateFile+'.private-errors.jsonl') (($private|ConvertTo-Json -Depth 8 -Compress)+[Environment]::NewLine) -Append
    } catch { $script:Notes.Add('A private diagnostic file could not be saved; public exception location is still available.') }
    return $public
}

$nativeSource = @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public sealed class B2LoadedImages {
    public string Status = "unknown";
    public int Error;
    public int NeededCount;
    public int NullEntries;
    public int UnresolvedNames;
    public bool Truncated;
    public string[] Names = new string[0];
}
public sealed class B2CatalogResult {
    public string Status = "unknown";
    public int Error;
    public bool EnumerationTruncated;
    public List<B2CatalogMatch> Matches = new List<B2CatalogMatch>();
}
public sealed class B2CatalogMatch {
    public string RuntimePath;
    public string Algorithm;
    public uint TrustCode;
}
public static class B2NativeInventory {
    [DllImport("psapi.dll", SetLastError=true)] static extern bool EnumDeviceDrivers([Out] IntPtr[] bases, uint bytes, out uint needed);
    [DllImport("psapi.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetDeviceDriverFileNameW(IntPtr imageBase, StringBuilder name, uint count);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern uint QueryDosDevice(string device, StringBuilder target, uint size);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr value);
    [DllImport("kernel32.dll", EntryPoint="SetLastError")] static extern void SetNativeLastError(uint error);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool LookupPrivilegeValue(string system, string name, out LUID luid);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES state, uint length, IntPtr previous, IntPtr returned);
    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct TOKEN_PRIVILEGES { public uint Count; public LUID Luid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)] struct FILE_INFO { public uint Size; public IntPtr Path; public IntPtr File; public IntPtr Subject; }
    [StructLayout(LayoutKind.Sequential)] struct TRUST_DATA {
        public uint Size; public IntPtr Policy; public IntPtr Sip; public uint Ui; public uint Revocation;
        public uint Choice; public IntPtr Info; public uint StateAction; public IntPtr State; public IntPtr Url;
        public uint Flags; public uint Context; public IntPtr SignatureSettings;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct CATALOG_INFO {
        public uint Size; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string Path;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct CATALOG_TRUST_INFO {
        public uint Size; public uint Version;
        [MarshalAs(UnmanagedType.LPWStr)] public string CatalogPath;
        [MarshalAs(UnmanagedType.LPWStr)] public string MemberTag;
        [MarshalAs(UnmanagedType.LPWStr)] public string MemberPath;
        public IntPtr MemberFile; public IntPtr Hash; public uint HashLength; public IntPtr Context; public IntPtr Admin;
    }
    [DllImport("wintrust.dll", ExactSpelling=true)] static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TRUST_DATA data);
    [DllImport("wintrust.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CryptCATAdminAcquireContext2(out IntPtr admin, IntPtr subsystem, string algorithm, IntPtr policy, uint flags);
    [DllImport("wintrust.dll", SetLastError=true)] static extern bool CryptCATAdminCalcHashFromFileHandle2(IntPtr admin, IntPtr file, ref uint size, byte[] hash, uint flags);
    [DllImport("wintrust.dll", SetLastError=true)] static extern IntPtr CryptCATAdminEnumCatalogFromHash(IntPtr admin, byte[] hash, uint size, uint flags, ref IntPtr previous);
    [DllImport("wintrust.dll", EntryPoint="CryptCATAdminEnumCatalogFromHash", ExactSpelling=true, SetLastError=true)] static extern IntPtr CryptCATAdminEnumCatalogFromHashFirst(IntPtr admin, byte[] hash, uint size, uint flags, IntPtr previous);
    [DllImport("wintrust.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CryptCATCatalogInfoFromContext(IntPtr catalog, ref CATALOG_INFO info, uint flags);
    [DllImport("wintrust.dll", SetLastError=true)] static extern bool CryptCATAdminReleaseCatalogContext(IntPtr admin, IntPtr catalog, uint flags);
    [DllImport("wintrust.dll", SetLastError=true)] static extern bool CryptCATAdminReleaseContext(IntPtr admin, uint flags);
    static Guid GenericTrustAction() { return new Guid(unchecked((int)0x00AAC56B), unchecked((short)0xCD44), 0x11D0, 0x8C, 0xC2, 0, 0xC0, 0x4F, 0xC2, 0x95, 0xEE); }
    static uint VerifyInfo(IntPtr info, uint choice, bool online) {
        var data = new TRUST_DATA { Size=(uint)Marshal.SizeOf(typeof(TRUST_DATA)), Ui=2, Choice=choice, Info=info, StateAction=1, Flags=online ? 0x80U : 0x1010U };
        Guid action=GenericTrustAction(); uint result=unchecked((uint)WinVerifyTrust(new IntPtr(-1),ref action,ref data));
        data.StateAction=2; WinVerifyTrust(new IntPtr(-1),ref action,ref data); return result;
    }
    public static ushort NativeMachine() {
        ushort process,native; return IsWow64Process2(GetCurrentProcess(),out process,out native) ? native : (ushort)0;
    }
    public static int EnableDebugPrivilege() {
        IntPtr token; if(!OpenProcessToken(GetCurrentProcess(),0x28,out token)) return Marshal.GetLastWin32Error();
        try { LUID luid; if(!LookupPrivilegeValue(null,"SeDebugPrivilege",out luid)) return Marshal.GetLastWin32Error();
            var state=new TOKEN_PRIVILEGES { Count=1,Luid=luid,Attributes=2 };
            if(!AdjustTokenPrivileges(token,false,ref state,0,IntPtr.Zero,IntPtr.Zero)) return Marshal.GetLastWin32Error();
            return Marshal.GetLastWin32Error();
        } finally { CloseHandle(token); }
    }
    public static B2LoadedImages LoadedImages() {
        var result=new B2LoadedImages(); var buffers=new IntPtr[1024]; uint needed;
        if(!EnumDeviceDrivers(buffers,(uint)(buffers.Length*IntPtr.Size),out needed)) { result.Error=Marshal.GetLastWin32Error(); return result; }
        if(needed>buffers.Length*IntPtr.Size) {
            int count=Math.Min(8192,(int)((needed+(uint)IntPtr.Size-1)/(uint)IntPtr.Size)); buffers=new IntPtr[count];
            if(!EnumDeviceDrivers(buffers,(uint)(buffers.Length*IntPtr.Size),out needed)) { result.Error=Marshal.GetLastWin32Error(); return result; }
        }
        result.NeededCount=(int)(needed/(uint)IntPtr.Size); result.Truncated=result.NeededCount>buffers.Length;
        var names=new List<string>(); int available=Math.Min(buffers.Length,result.NeededCount);
        for(int i=0;i<available;i++) {
            if(buffers[i]==IntPtr.Zero) { result.NullEntries++; continue; }
            var name=new StringBuilder(32768); uint copied=GetDeviceDriverFileNameW(buffers[i],name,(uint)name.Capacity);
            if(copied==0 || copied>=name.Capacity) { result.UnresolvedNames++; continue; }
            names.Add(name.ToString());
        }
        result.Names=names.ToArray();
        result.Status=(available==0 || result.NullEntries==available) ? "unknown" : (result.Truncated || result.UnresolvedNames>0 || result.NullEntries>0 ? "partial" : "available");
        return result;
    }
    public static uint EmbeddedTrust(string path,bool online) {
        IntPtr text=Marshal.StringToCoTaskMemUni(path),info=IntPtr.Zero;
        try { var file=new FILE_INFO { Size=(uint)Marshal.SizeOf(typeof(FILE_INFO)),Path=text }; info=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(FILE_INFO))); Marshal.StructureToPtr(file,info,false); return VerifyInfo(info,1,online); }
        finally { if(info!=IntPtr.Zero) Marshal.FreeHGlobal(info); Marshal.FreeCoTaskMem(text); }
    }
    public static B2CatalogResult CatalogTrust(string path,bool online) {
        var result=new B2CatalogResult(); int hashedAlgorithms=0; bool coverageIncomplete=false;
        foreach(string algorithm in new[]{"SHA256","SHA1"}) {
            IntPtr admin; if(!CryptCATAdminAcquireContext2(out admin,IntPtr.Zero,algorithm,IntPtr.Zero,0)) { result.Error=Marshal.GetLastWin32Error(); coverageIncomplete=true; continue; }
            var contexts=new List<IntPtr>();
            try { using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) {
                IntPtr handle=stream.SafeFileHandle.DangerousGetHandle(); uint size=0;
                if(!CryptCATAdminCalcHashFromFileHandle2(admin,handle,ref size,null,0) || size==0 || size>1048576) { result.Error=Marshal.GetLastWin32Error(); coverageIncomplete=true; continue; }
                byte[] hash=new byte[size];
                if(!CryptCATAdminCalcHashFromFileHandle2(admin,handle,ref size,hash,0)) { result.Error=Marshal.GetLastWin32Error(); coverageIncomplete=true; continue; }
                hashedAlgorithms++; string tag=BitConverter.ToString(hash).Replace("-",""); IntPtr previous=IntPtr.Zero;
                for(int index=0;index<16;index++) {
                    SetNativeLastError(0);
                    IntPtr catalog=index==0
                        ? CryptCATAdminEnumCatalogFromHashFirst(admin,hash,size,0,IntPtr.Zero)
                        : CryptCATAdminEnumCatalogFromHash(admin,hash,size,0,ref previous);
                    if(catalog==IntPtr.Zero) {
                        int enumerationError=Marshal.GetLastWin32Error();
                        if(enumerationError!=0 && enumerationError!=1168) { result.Error=enumerationError; coverageIncomplete=true; }
                        break;
                    }
                    contexts.Add(catalog); previous=catalog;
                    if(index==15) { result.EnumerationTruncated=true; coverageIncomplete=true; }
                    var cat=new CATALOG_INFO { Size=(uint)Marshal.SizeOf(typeof(CATALOG_INFO)),Path="" };
                    if(!CryptCATCatalogInfoFromContext(catalog,ref cat,0) || String.IsNullOrEmpty(cat.Path)) { result.Error=Marshal.GetLastWin32Error(); coverageIncomplete=true; continue; }
                    IntPtr hashMemory=Marshal.AllocHGlobal(hash.Length),trustMemory=IntPtr.Zero;
                    try { Marshal.Copy(hash,0,hashMemory,hash.Length);
                        var trust=new CATALOG_TRUST_INFO { Size=(uint)Marshal.SizeOf(typeof(CATALOG_TRUST_INFO)),CatalogPath=cat.Path,MemberTag=tag,MemberPath=path,MemberFile=handle,Hash=hashMemory,HashLength=size,Admin=admin };
                        trustMemory=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(CATALOG_TRUST_INFO))); Marshal.StructureToPtr(trust,trustMemory,false);
                        result.Matches.Add(new B2CatalogMatch { RuntimePath=cat.Path,Algorithm=algorithm,TrustCode=VerifyInfo(trustMemory,2,online) });
                    } finally { if(trustMemory!=IntPtr.Zero) { Marshal.DestroyStructure(trustMemory,typeof(CATALOG_TRUST_INFO)); Marshal.FreeHGlobal(trustMemory); } Marshal.FreeHGlobal(hashMemory); }
                }
            } } catch { result.Error=5; coverageIncomplete=true; }
            finally { foreach(IntPtr catalog in contexts) CryptCATAdminReleaseCatalogContext(admin,catalog,0); CryptCATAdminReleaseContext(admin,0); }
        }
        bool complete=hashedAlgorithms==2 && !coverageIncomplete && !result.EnumerationTruncated;
        result.Status=result.Matches.Count==0 ? (complete ? "not_found" : "unknown") : (complete ? "available" : "partial"); return result;
    }
}
'@

function Get-Sha256([string]$Path) {
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() }
    catch { return $null }
}
function Get-OpaqueKey([string]$Domain,[string]$Value) {
    $hmac=[Security.Cryptography.HMACSHA256]::new([byte[]]$script:CorrelationKey)
    try { return [BitConverter]::ToString($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Domain+'|'+$Value.ToLowerInvariant()))).Replace('-','').ToLowerInvariant() }
    finally { $hmac.Dispose() }
}
function Get-Alias([string]$Domain,[string]$Identity) {
    $key=Get-OpaqueKey $Domain $Identity
    $map=$script:Aliases[$Domain]
    if(-not $map.ContainsKey($key)) { $script:Counters[$Domain]++; $map[$key]=('{0}-{1:d3}' -f $Domain,$script:Counters[$Domain]) }
    return $map[$key]
}
function Resolve-DriverPath([string]$Value) {
    if([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $value=[Environment]::ExpandEnvironmentVariables($Value.Trim())
    if($value -match '^"([^"\r\n]+\.sys)"') { $value=$Matches[1] }
    elseif($value -match '^(.+?\.sys)(?:\s+|$)') { $value=$Matches[1] }
    if($value.StartsWith('\??\')) { $value=$value.Substring(4) }
    if($value.StartsWith('\\?\')) { $value=$value.Substring(4) }
    if($value.StartsWith('\SystemRoot\',[StringComparison]::OrdinalIgnoreCase)) { $value=Join-Path $env:SystemRoot $value.Substring(12) }
    elseif($value.StartsWith('System32\',[StringComparison]::OrdinalIgnoreCase)) { $value=Join-Path $env:SystemRoot $value }
    elseif($value.StartsWith('\Device\',[StringComparison]::OrdinalIgnoreCase)) {
        foreach($drive in [IO.DriveInfo]::GetDrives()) {
            $letter=$drive.Name.Substring(0,2); $buffer=[Text.StringBuilder]::new(32768)
            if([B2NativeInventory]::QueryDosDevice($letter,$buffer,[uint32]$buffer.Capacity) -gt 0) {
                $target=$buffer.ToString().Split([char]0)[0]
                if($value.StartsWith($target+'\',[StringComparison]::OrdinalIgnoreCase)) { $value=$letter+$value.Substring($target.Length); break }
            }
        }
    }
    if($value -notmatch '^[A-Za-z]:\\') { return $null }
    try { return [IO.Path]::GetFullPath($value) } catch { return $null }
}
function Add-Candidate([string]$Path,[string]$Source) {
    if($null -eq $Path -or [IO.Path]::GetExtension($Path) -ine '.sys') { return }
    if(-not $script:Candidates.ContainsKey($Path)) { $script:Candidates[$Path]=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
    $null=$script:Candidates[$Path].Add($Source)
}
function Get-PublicOrganization($Certificate,[switch]$Issuer) {
    if($null -eq $Certificate) { return $null }
    $dn=if($Issuer) { $Certificate.IssuerName } else { $Certificate.SubjectName }
    $decoded=$dn.Decode([Security.Cryptography.X509Certificates.X500DistinguishedNameFlags]::UseNewLines)
    $allow=@('Microsoft Corporation','Microsoft Windows','Tencent Technology (Shenzhen) Company Limited','DigiCert Inc','DigiCert, Inc.','GlobalSign nv-sa','Sectigo Limited','Entrust, Inc.','Symantec Corporation','VeriSign, Inc.')
    foreach($line in ($decoded -split '[\r\n]+')) {
        if($line -match '^\s*O\s*=\s*(.+?)\s*$') {
            $organization=$Matches[1].Trim('"')
            if($allow -contains $organization) { return $organization }
        }
    }
    return $null
}
function Get-TrustState([uint32]$Code) {
    switch($Code.ToString('x8')) {
        '00000000' { return 'valid' }
        '800b0100' { return 'unsigned' }
        '80096010' { return 'invalid' }
        '800b010c' { return 'invalid' }
        '800b0111' { return 'invalid' }
        '800b0109' { return 'untrusted' }
        '800b010a' { return 'untrusted' }
        '800b0101' { return 'untrusted' }
        '800b0004' { return 'untrusted' }
        default { return 'unknown' }
    }
}
function Get-BinaryEvidence([string]$Path,[string[]]$Sources) {
    $alias=Get-Alias 'driver' $Path; $key=Get-OpaqueKey 'driver' $Path
    $hash=Get-Sha256 $Path
    $new=if($Stage -eq 'before') { $null } else { -not $script:BaselineBinaryHashes.ContainsKey($key) }
    $changed=if($Stage -eq 'before' -or $new) { $null } else { $hash -ne $script:BaselineBinaryHashes[$key] }
    $record=[ordered]@{ binary_alias=$alias; discovered_via=@($Sources); new_since_baseline=$new; changed_since_baseline=$changed; file_available=($null -ne $hash); sha256=$hash; size_bytes=$null; file_version=$null; pe_valid=$null; pe_machine=$null; architecture='unknown'; embedded_signature=[ordered]@{status='not_sampled'; trust_hresult=$null; embedded_certificate_present=$null; public_signer_organization=$null; public_issuer_organization=$null}; catalog_signature=[ordered]@{status='not_sampled'; native_error_code=$null; matches=@(); enumeration_truncated=$false}; powershell_authenticode=[ordered]@{status='not_sampled'; selected_signature_type='unknown'; public_signer_organization=$null; public_issuer_organization=$null}; kernel_load=[ordered]@{status='unknown'; psapi_image_correlated=$null; scm_running_correlated=$null; image_identity_verified=$false} }
    if($null -eq $hash) { return [pscustomobject]$record }
    try {
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        $reader=[IO.BinaryReader]::new($stream)
        try {
            $record.size_bytes=$stream.Length
            $valid=$stream.Length -ge 64 -and $reader.ReadUInt16() -eq 0x5a4d
            if($valid) { $stream.Position=60; $offset=$reader.ReadInt32(); $valid=$offset -ge 64 -and $offset -le ($stream.Length-24) }
            if($valid) { $stream.Position=$offset; $valid=$reader.ReadUInt32() -eq 0x00004550 }
            if($valid) {
                $machine=$reader.ReadUInt16()
                $stream.Position=$offset+20; $optionalSize=$reader.ReadUInt16()
                $optionalEnd=[uint64]$offset+24+[uint64]$optionalSize
                $valid=$optionalSize -ge 2 -and $optionalEnd -le [uint64]$stream.Length
            }
            if($valid) {
                $stream.Position=$offset+24; $magic=$reader.ReadUInt16()
                $directoryOffset=if($magic -eq 0x20b) {112} elseif($magic -eq 0x10b) {96} else {0}
                $valid=$directoryOffset -gt 0 -and $optionalSize -ge $directoryOffset
            }
            if($valid) {
                $stream.Position=$offset+24+$directoryOffset-4; $directoryCount=$reader.ReadUInt32()
                $valid=([uint64]$directoryCount*8) -le ([uint64]$optionalSize-[uint64]$directoryOffset)
            }
            $record.pe_valid=$valid
            if($valid) {
                $record.pe_machine=('0x{0:x4}' -f $machine)
                $record.architecture=switch($machine) { 0xaa64 {'ARM64'} 0x8664 {'AMD64'} 0x014c {'I386'} 0xa641 {'ARM64EC'} default {'other'} }
                if($directoryCount -ge 5) {
                    $stream.Position=$offset+24+$directoryOffset+32; $certificateOffset=$reader.ReadUInt32(); $certificateSize=$reader.ReadUInt32()
                    $record.embedded_signature.embedded_certificate_present=($certificateOffset -gt 0 -and $certificateSize -ge 8 -and ([uint64]$certificateOffset+$certificateSize) -le [uint64]$stream.Length)
                }
                else { $record.embedded_signature.embedded_certificate_present=$false }
            }
        } finally { $reader.Dispose() }
        $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($Path).FileVersion
        if($version -match '^\d+(?:[., ]\s*\d+){1,4}$') { $record.file_version=$version }
    } catch { $null=Save-PrivateException 'binary-metadata' $_; $script:Notes.Add('One candidate could not complete PE or version sampling.') }
    $verify=$FullSignatureInventory -or ($Sources -contains 'install-root') -or ($Stage -ne 'before' -and ($new -or $changed))
    if($verify) {
        try {
            $trust=[B2NativeInventory]::EmbeddedTrust($Path,[bool]$AllowOnlineSignatureChecks)
            $record.embedded_signature.trust_hresult=('0x{0:x8}' -f $trust); $record.embedded_signature.status=Get-TrustState $trust
            if($record.embedded_signature.embedded_certificate_present -eq $false) { $record.embedded_signature.status='unsigned' }
            try {
                $cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new([Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile($Path))
                $record.embedded_signature.public_signer_organization=Get-PublicOrganization $cert
                $record.embedded_signature.public_issuer_organization=Get-PublicOrganization $cert -Issuer
                $cert.Dispose()
            } catch { }
            $catalog=[B2NativeInventory]::CatalogTrust($Path,[bool]$AllowOnlineSignatureChecks)
            $record.catalog_signature.status=$catalog.Status; $record.catalog_signature.native_error_code=$catalog.Error; $record.catalog_signature.enumeration_truncated=$catalog.EnumerationTruncated
            $matches=[Collections.Generic.List[object]]::new()
            foreach($match in $catalog.Matches) {
                $matches.Add([pscustomobject]@{catalog_alias=(Get-Alias 'catalog' $match.RuntimePath); catalog_sha256=(Get-Sha256 $match.RuntimePath); membership_hash_algorithm=$match.Algorithm; membership_verified_by_registered_catalog_lookup=$true; trust_status=(Get-TrustState $match.TrustCode); trust_hresult=('0x{0:x8}' -f $match.TrustCode)})
            }
            $record.catalog_signature.matches=@($matches.ToArray())
            $auth=Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
            $record.powershell_authenticode.status=$auth.Status.ToString()
            if($null -ne $auth.PSObject.Properties['SignatureType']) { $record.powershell_authenticode.selected_signature_type=$auth.SignatureType.ToString() }
            $record.powershell_authenticode.public_signer_organization=Get-PublicOrganization $auth.SignerCertificate
            $record.powershell_authenticode.public_issuer_organization=Get-PublicOrganization $auth.SignerCertificate -Issuer
        } catch { $null=Save-PrivateException 'binary-signature' $_; $script:Notes.Add('One candidate signature check could not complete; its result remains unknown or partial.') }
    }
    $record.kernel_load.psapi_image_correlated=if($script:LoadedEnumeration.Status -eq 'available') { $script:LoadedPaths.Contains($Path) } elseif($script:LoadedPaths.Contains($Path)) { $true } else { $null }
    $record.kernel_load.scm_running_correlated=if($script:ScmAvailable) { $script:RunningServicePaths.Contains($Path) } else {$null}
    $record.kernel_load.image_identity_verified=($record.pe_valid -eq $true -and $null -ne $record.sha256)
    if($record.kernel_load.psapi_image_correlated -eq $true -and $record.kernel_load.image_identity_verified) { $record.kernel_load.status='loaded' }
    elseif($record.kernel_load.psapi_image_correlated -eq $false) { $record.kernel_load.status='not_loaded' }
    if($Stage -eq 'before') { $script:BaselineBinaryHashes[$key]=$hash }
    return [pscustomobject]$record
}

try {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent(); $principal=[Security.Principal.WindowsPrincipal]::new($identity)
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'This collector requires an elevated Guest session.' }
    if($null -eq ('B2NativeInventory' -as [type])) { Add-Type -TypeDefinition $nativeSource -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null }
    Add-Type -AssemblyName System.Security -ErrorAction Stop | Out-Null
    $script:Aliases=@{service=@{}; driver=@{}; catalog=@{}}; $script:Counters=@{service=0; driver=0; catalog=0}; $script:BaselineServices=@{}; $script:BaselineBinaryHashes=@{}
    $entropy=[Text.Encoding]::UTF8.GetBytes('b2-neutral-correlation')
    $baselineTime=$null
    if($Stage -eq 'before') {
        if(Test-Path -LiteralPath $StateFile) { throw 'Baseline state already exists; use a fresh neutral state file.' }
        $script:CorrelationKey=[byte[]]::new(32); $rng=[Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($script:CorrelationKey); $rng.Dispose()
        $protected=[Security.Cryptography.ProtectedData]::Protect($script:CorrelationKey,$entropy,[Security.Cryptography.DataProtectionScope]::LocalMachine)
        $protectedMaterial=[Convert]::ToBase64String($protected)
    } else {
        $saved=Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop | ConvertFrom-Json
        if($saved.schema_version -ne '1.0.0') { throw 'Unsupported opaque correlation state.' }
        $protectedMaterial=$saved.protected_correlation_material
        $script:CorrelationKey=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($protectedMaterial),$entropy,[Security.Cryptography.DataProtectionScope]::LocalMachine)
        $baselineTime=[DateTimeOffset]::Parse($saved.baseline_captured_at)
        foreach($domain in @('service','driver','catalog')) {
            foreach($entry in $saved.aliases.$domain) { $script:Aliases[$domain][$entry.opaque_key]=$entry.alias }
            $script:Counters[$domain]=[int]$saved.counters.$domain
        }
        foreach($entry in $saved.baseline_services) { $script:BaselineServices[$entry.opaque_key]=$true }
        foreach($entry in $saved.baseline_binary_hashes) { $script:BaselineBinaryHashes[$entry.opaque_key]=$entry.sha256 }
    }
    $captured=[DateTimeOffset]::UtcNow; if($null -eq $baselineTime) { $baselineTime=$captured }
    $debugError=[B2NativeInventory]::EnableDebugPrivilege()
    $script:LoadedEnumeration=[B2NativeInventory]::LoadedImages()
    $script:Candidates=@{}; $script:LoadedPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); $script:RunningServicePaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $runtimeResolutionErrors=0
    foreach($runtimePath in $script:LoadedEnumeration.Names) {
        $path=Resolve-DriverPath $runtimePath
        if($null -ne $path) { $null=$script:LoadedPaths.Add($path); Add-Candidate $path 'loaded-image-api' } else {$runtimeResolutionErrors++}
    }
    if($runtimeResolutionErrors -gt 0 -and $script:LoadedEnumeration.Status -eq 'available') {$script:LoadedEnumeration.Status='partial'}
    $serviceRecords=[Collections.Generic.List[object]]::new(); $privateServices=@(); $script:ScmAvailable=$true
    try { $privateServices=@(Get-CimInstance Win32_SystemDriver -ErrorAction Stop)+@(Get-CimInstance Win32_Service -ErrorAction Stop) } catch { $null=Save-PrivateException 'scm-enumeration' $_; $script:ScmAvailable=$false; $script:Notes.Add('SCM driver enumeration was unavailable.') }
    foreach($service in $privateServices) {
        $key=Get-OpaqueKey 'service' $service.Name; $alias=Get-Alias 'service' $service.Name
        $new=if($Stage -eq 'before') {$null} else {-not $script:BaselineServices.ContainsKey($key)}
        $path=Resolve-DriverPath $service.PathName; $driverAlias=$null
        if($null -ne $path -and [IO.Path]::GetExtension($path) -ine '.sys') {$path=$null}
        if($null -ne $path) { Add-Candidate $path 'scm-service'; $driverAlias=Get-Alias 'driver' $path; if($service.State -eq 'Running') { $null=$script:RunningServicePaths.Add($path) } }
        if($Stage -eq 'before') { $script:BaselineServices[$key]=$true }
        $serviceRecords.Add([pscustomobject]@{service_alias=$alias; new_since_baseline=$new; scm_state=$service.State; scm_started=[bool]$service.Started; start_mode=$service.StartMode; win32_exit_code=$service.ExitCode; service_specific_exit_code=$service.ServiceSpecificExitCode; service_inventory_class=$service.CimClass.CimClassName; driver_alias=$driverAlias; binary_path_resolved=($null -ne $path)})
    }
    $rootFiles=0; $rootDirectories=0; $rootErrors=0; $rootTruncated=$false
    foreach($root in $InstallRoot) {
        $queue=[Collections.Generic.Queue[string]]::new(); $queue.Enqueue($root)
        while($queue.Count -gt 0) {
            if($rootDirectories -ge $MaxRootDirectories) {$rootTruncated=$true;break}
            $directory=$queue.Dequeue(); $rootDirectories++; $errors=@()
            $children=@(Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue -ErrorVariable errors); $rootErrors+=$errors.Count
            foreach($child in $children) {
                if(($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if($child.PSIsContainer) { $queue.Enqueue($child.FullName) }
                elseif($child.Extension -ieq '.sys') { $rootFiles++; Add-Candidate $child.FullName 'install-root'; if($rootFiles -ge $MaxRootDriverFiles) {$rootTruncated=$true; break} }
            }
            if($rootTruncated) {break}
        }
        if($rootTruncated) {break}
    }
    $binaries=[Collections.Generic.List[object]]::new()
    foreach($path in @($script:Candidates.Keys | Sort-Object)) { $binaries.Add((Get-BinaryEvidence $path @($script:Candidates[$path]))) }
    $events=[Collections.Generic.List[object]]::new(); $eventErrors=0; $eventCounter=0
    if($Stage -ne 'before') {
        foreach($log in @('System','Microsoft-Windows-CodeIntegrity/Operational')) {
            try {
                $items=@(Get-WinEvent -FilterHashtable @{LogName=$log; StartTime=$baselineTime.UtcDateTime} -MaxEvents $MaxEvents -ErrorAction Stop)
                foreach($event in $items) {
                    try {
                    if($log -eq 'System' -and $event.ProviderName -ne 'Service Control Manager') {continue}
                    $xml=[xml]$event.ToXml(); $values=@($xml.SelectNodes("/*[local-name()='Event']/*[local-name()='EventData']/*[local-name()='Data']") | ForEach-Object { $_.InnerText }); $related=[Collections.Generic.List[string]]::new()
                    foreach($service in $privateServices) { if($values -contains $service.Name -or $values -contains $service.DisplayName) { $related.Add((Get-Alias 'service' $service.Name)) } }
                    foreach($path in $script:Candidates.Keys) { if(@($values | Where-Object {$_ -like ('*'+$path+'*')}).Count -gt 0) { $related.Add((Get-Alias 'driver' $path)) } }
                    if($related.Count -eq 0) {continue}
                    $nativeCodes=[Collections.Generic.List[int]]::new(); $hresults=[Collections.Generic.List[string]]::new()
                    foreach($value in $values) { foreach($m in [regex]::Matches($value,'%%(\d+)')) {$nativeCodes.Add([int]$m.Groups[1].Value)}; foreach($m in [regex]::Matches($value,'\b0x[0-9a-fA-F]{8}\b')) {$hresults.Add($m.Value.ToLowerInvariant())} }
                    $eventCounter++; $events.Add([pscustomobject]@{event_alias=('event-{0:d3}' -f $eventCounter); stage=$Stage; provider_alias=$(if($log -eq 'System') {'scm'} else {'code-integrity'}); event_id=$event.Id; level=$event.Level; captured_at=$event.TimeCreated.ToUniversalTime().ToString('o'); related_aliases=@($related.ToArray()|Select-Object -Unique); native_error_codes=@($nativeCodes.ToArray()); status_codes=@($hresults.ToArray()); message_content_omitted=$true})
                    } catch {$null=Save-PrivateException 'single-event' $_; $eventErrors++}
                }
            } catch {
                if($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
                    $script:Notes.Add('An event query completed with no matching records.')
                } else {$null=Save-PrivateException 'event-log' $_; $eventErrors++}
            }
        }
    }
    $state=[ordered]@{schema_version='1.0.0'; protected_correlation_material=$protectedMaterial; baseline_captured_at=$baselineTime.ToString('o'); counters=$script:Counters; aliases=@{}; baseline_services=@(); baseline_binary_hashes=@()}
    foreach($domain in @('service','driver','catalog')) { $state.aliases[$domain]=@($script:Aliases[$domain].GetEnumerator()|ForEach-Object {[pscustomobject]@{opaque_key=$_.Key; alias=$_.Value}}) }
    $state.baseline_services=@($script:BaselineServices.Keys|ForEach-Object {[pscustomobject]@{opaque_key=$_}})
    $state.baseline_binary_hashes=@($script:BaselineBinaryHashes.GetEnumerator()|ForEach-Object {[pscustomobject]@{opaque_key=$_.Key; sha256=$_.Value}})
    Write-PrivateFile $StateFile ($state|ConvertTo-Json -Depth 8)
    $nativeMachine=[B2NativeInventory]::NativeMachine()
    $report=[ordered]@{schema_version='1.0.0'; report_kind='b2-driver-inventory'; stage=$Stage; captured_at=$captured.ToString('o'); guest_native_machine=('0x{0:x4}' -f $nativeMachine); guest_kernel_architecture=$(switch($nativeMachine) {0xaa64 {'ARM64'} 0x8664 {'AMD64'} default {'unknown'}}); debug_privilege=[ordered]@{attempted=$true; granted=($debugError -eq 0); native_error_code=$debugError}; loaded_image_enumeration=[ordered]@{status=$script:LoadedEnumeration.Status; native_error_code=$script:LoadedEnumeration.Error; reported_image_count=$script:LoadedEnumeration.NeededCount; null_image_entries=$script:LoadedEnumeration.NullEntries; unresolved_names=$script:LoadedEnumeration.UnresolvedNames; runtime_path_resolution_errors=$runtimeResolutionErrors; truncated=$script:LoadedEnumeration.Truncated; addresses_exported=$false}; coverage=[ordered]@{scm_available=$script:ScmAvailable; services_sampled=$privateServices.Count; service_inventory_scope='Win32_SystemDriver and Win32_Service'; system_loaded_images_sampled=$script:LoadedPaths.Count; installation_roots_requested=$InstallRoot.Count; installation_directories_scanned=$rootDirectories; installation_driver_files_found=$rootFiles; root_scan_errors=$rootErrors; root_scan_truncated=$rootTruncated; root_directory_limit=$MaxRootDirectories; root_driver_file_limit=$MaxRootDriverFiles; reparse_directories_skipped=$true; signature_scope=$(if($FullSignatureInventory){'all_candidates'}else{'new_changed_and_install_root_candidates'}); revocation_online_checks_requested=[bool]$AllowOnlineSignatureChecks; event_log_errors=$eventErrors; event_log_sample_limit=$MaxEvents}; services=@($serviceRecords.ToArray()); binaries=@($binaries.ToArray()); events=@($events.ToArray()); notes=@($script:Notes.ToArray())+@('SCM registration or running state alone is not treated as proof of a loaded kernel image.','Unavailable or partial PSAPI enumeration cannot prove that an unmatched driver is unloaded.','Catalog lookup covers registered local SHA256/SHA1 memberships, not every possible publisher package.','Generic Authenticode/catalog trust checks do not establish kernel-signing policy acceptance or publisher VM support.','No observed driver at a sampled installer stage does not prove that the publisher has no ARM64 driver.','Raw event messages are omitted; visible official installer dialogs require separate redacted capture.','File hashes identify on-disk candidates; loaded-image bytes are not read or dumped. Identity confirmation is limited to documented loaded-image path correlation.')}
    $report.diagnostics=@($script:Diagnostics.ToArray())
    $report.private_state_exported=$false
    $report.private_error_text_exported=$false
    $json=$report|ConvertTo-Json -Depth 14
    if($OutputFile) { [IO.File]::WriteAllText($OutputFile,$json,[Text.UTF8Encoding]::new($false)); [pscustomobject]@{status='captured'; stage=$Stage; binary_count=$binaries.Count; service_count=$serviceRecords.Count; loaded_image_status=$script:LoadedEnumeration.Status; privacy='neutral_aliases_only'}|ConvertTo-Json }
    else { $json }
} catch {
    $diagnostic=Save-PrivateException 'collector' $_
    [pscustomobject]@{schema_version='1.0.0'; report_kind='b2-driver-inventory'; stage=$Stage; status='failed'; failure_stage='collector'; reason='Collection failed; private exception text was withheld.'; exception_type=$diagnostic.exception_type; script_line=$diagnostic.script_line; private_state_exported=$false; private_error_text_exported=$false}|ConvertTo-Json
    exit 1
} finally {
    $keyVariable=Get-Variable CorrelationKey -Scope Script -ErrorAction SilentlyContinue
    if($null -ne $keyVariable -and $null -ne $keyVariable.Value) { [Array]::Clear($keyVariable.Value,0,$keyVariable.Value.Length) }
}
