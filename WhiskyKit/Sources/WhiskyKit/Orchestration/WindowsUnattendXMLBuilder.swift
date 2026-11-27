// SPDX-License-Identifier: GPL-3.0-or-later
// Compliant ARM64 Windows 11 autounattend.xml template builder (preserves Secure Boot & TPM 2.0).

import Foundation

enum WindowsUnattendXMLBuilder {
    private static let arm64Attrs = #"processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" "#
        + #"language="neutral" versionScope="nonSxS""#
    private static let wcmAdd = #"wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State""#

    static func generate(config: UnattendedWindowsConfig) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
        \(windowsPEPassXML(config: config))
        \(specializePassXML(config: config))
        \(oobePassXML(config: config))
        </unattend>
        """
    }

    private static func windowsPEPassXML(config: UnattendedWindowsConfig) -> String {
        let setupLang = xmlEscape(config.setupUILanguage)
        return """
          <settings pass="windowsPE">
            <component name="Microsoft-Windows-International-Core-WinPE" \(arm64Attrs)>
              <SetupUILanguage><UILanguage>\(setupLang)</UILanguage></SetupUILanguage>
              <InputLocale>\(setupLang)</InputLocale><SystemLocale>\(setupLang)</SystemLocale>
              <UILanguage>\(setupLang)</UILanguage><UserLocale>\(setupLang)</UserLocale>
            </component>
            <component name="Microsoft-Windows-PnpCustomizationsWinPE" \(arm64Attrs)>
              <DriverPaths>
                <PathAndCredentials \(wcmAdd) wcm:keyValue="1"><Path>D:\\Drivers</Path></PathAndCredentials>
                <PathAndCredentials \(wcmAdd) wcm:keyValue="2"><Path>E:\\Drivers</Path></PathAndCredentials>
                <PathAndCredentials \(wcmAdd) wcm:keyValue="3"><Path>F:\\Drivers</Path></PathAndCredentials>
              </DriverPaths>
            </component>
            <component name="Microsoft-Windows-Setup" \(arm64Attrs)>
              <DiskConfiguration>
                <Disk \(wcmAdd)>
                  <DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>
                  <CreatePartitions>
                    <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
                    <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>128</Size></CreatePartition>
                    <CreatePartition wcm:action="add">
                      <Order>3</Order><Type>Primary</Type><Extend>true</Extend>
                    </CreatePartition>
                  </CreatePartitions>
                  <ModifyPartitions>
                    <ModifyPartition wcm:action="add">
                      <Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label>
                    </ModifyPartition>
                    <ModifyPartition wcm:action="add">
                      <Order>2</Order><PartitionID>3</PartitionID>
                      <Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter>
                    </ModifyPartition>
                  </ModifyPartitions>
                </Disk>
              </DiskConfiguration>
              <ImageInstall><OSImage>
                <InstallFrom>
                  <MetaData \(wcmAdd)><Key>/IMAGE/INDEX</Key><Value>\(config.imageIndex)</Value></MetaData>
                </InstallFrom>
                <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
              </OSImage></ImageInstall>
              <UserData><AcceptEula>true</AcceptEula></UserData>
            </component>
          </settings>
        """
    }

    private static func specializePassXML(config: UnattendedWindowsConfig) -> String {
        let computer = xmlEscape(config.computerName)
        let zone = xmlEscape(config.timeZone)
        let cmd1 = #"cmd.exe /c reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" "#
            + #"/v BypassNRO /t REG_DWORD /d 1 /f"#
        let cmd2 = #"cmd.exe /c reg add "HKLM\SOFTWARE\Microsoft\Windows\Dwm" "#
            + #"/v OverlayTestMode /t REG_DWORD /d 5 /f"#
        let cmd3 = #"cmd.exe /c reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "#
            + #"/v DisableFileSyncNGSC /t REG_DWORD /d 1 /f"#
        return """
          <settings pass="specialize">
            <component name="Microsoft-Windows-Shell-Setup" \(arm64Attrs)>
              <ComputerName>\(computer)</ComputerName><TimeZone>\(zone)</TimeZone>
            </component>
            <component name="Microsoft-Windows-Deployment" \(arm64Attrs)>
              <RunSynchronous>
                <RunSynchronousCommand \(wcmAdd)><Order>1</Order><Path>\(xmlEscape(cmd1))</Path></RunSynchronousCommand>
                <RunSynchronousCommand \(wcmAdd)><Order>2</Order><Path>\(xmlEscape(cmd2))</Path></RunSynchronousCommand>
                <RunSynchronousCommand \(wcmAdd)><Order>3</Order><Path>\(xmlEscape(cmd3))</Path></RunSynchronousCommand>
              </RunSynchronous>
            </component>
          </settings>
        """
    }

    static func startupScript() -> String {
        """
        @echo -off
        for %a in 0 1 2 3 4 5 6
          if exist FS%a:\\efi\\microsoft\\boot\\cdboot_noprompt.efi then
            FS%a:\\efi\\microsoft\\boot\\cdboot_noprompt.efi
          endif
          if exist FS%a:\\efi\\boot\\bootaa64.efi then
            FS%a:\\efi\\boot\\bootaa64.efi
          endif
        endfor
        """
    }

    /// PowerShell first-logon bootstrap script placed at `MALTBOOT:\bootstrap.ps1`
    /// so `autounattend.xml` `<CommandLine>` stays well below Windows SMI's 259-character limit.
    static func bootstrapScript() -> String {
        """
        $ErrorActionPreference = 'Continue'
        $vol = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'MALTBOOT' } | Select-Object -First 1
        if ($vol) {
            $root = $vol.DriveLetter + ':'
            foreach ($dir in @($root + '\\Drivers', $root + '\\PostDrivers')) {
                if (Test-Path $dir) {
                    Get-ChildItem $dir -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue | ForEach-Object {
                        pnputil.exe /add-driver $_.FullName /install | Out-Null
                    }
                }
            }
            $exe = Get-ChildItem $root -Recurse -Filter 'utm-guest-tools*.exe' -EA SilentlyContinue |
                Select-Object -First 1
            if ($exe) { Start-Process $exe.FullName -ArgumentList '/S' -Wait }
            $msi = Get-ChildItem $root -Recurse -Filter 'qemu-ga*.msi' -EA SilentlyContinue |
                Select-Object -First 1
            if ($msi) {
                $msiArg = '"' + $msi.FullName + '"'
                Start-Process msiexec.exe -ArgumentList '/i', $msiArg, '/qn', '/norestart' -Wait
            }
            sc.exe config 'QEMU Guest Agent' start= auto | Out-Null
            Start-Service 'QEMU Guest Agent' -ErrorAction SilentlyContinue
            if (Test-Path ($root + '\\GuestOptimizer')) {
                New-Item -ItemType Directory -Path 'C:\\ProgramData\\Malt\\GuestOptimizer' -Force | Out-Null
                Copy-Item ($root + '\\GuestOptimizer\\*') 'C:\\ProgramData\\Malt\\GuestOptimizer\\' -Force
            }
        }
        New-Item -ItemType Directory -Path 'C:\\ProgramData\\Malt' -Force | Out-Null
        Set-Content -Path 'C:\\ProgramData\\Malt\\bootstrap.done' -Value 'OK' -Encoding ASCII
        """
    }

    private static func oobePassXML(config: UnattendedWindowsConfig) -> String {
        let user = xmlEscape(config.username)
        let setupLang = xmlEscape(config.setupUILanguage)
        let shortCmd = #"cmd.exe /c for %i in (D E F G) do if exist %i:\bootstrap.ps1 "#
            + #"powershell -NoP -EP Bypass -File %i:\bootstrap.ps1"#
        return """
          <settings pass="oobeSystem">
            <component name="Microsoft-Windows-International-Core" \(arm64Attrs)>
              <InputLocale>\(setupLang)</InputLocale><SystemLocale>\(setupLang)</SystemLocale>
              <UILanguage>\(setupLang)</UILanguage><UserLocale>\(setupLang)</UserLocale>
            </component>
            <component name="Microsoft-Windows-Shell-Setup" \(arm64Attrs)>
              <OOBE>
                <HideEULAPage>true</HideEULAPage><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation><ProtectYourPC>3</ProtectYourPC>
                <VMModeOptimizations><SkipWinREInitialization>true</SkipWinREInitialization></VMModeOptimizations>
              </OOBE>
              <UserAccounts><LocalAccounts>
                <LocalAccount \(wcmAdd)>
                  <DisplayName>\(user)</DisplayName><Name>\(user)</Name><Group>Administrators</Group>
                  <Password><Value></Value><PlainText>true</PlainText></Password>
                </LocalAccount>
              </LocalAccounts></UserAccounts>
              <AutoLogon>
                <Enabled>true</Enabled><Username>\(user)</Username>
                <Password><Value></Value><PlainText>true</PlainText></Password><LogonCount>2</LogonCount>
              </AutoLogon>
              <FirstLogonCommands>
                <SynchronousCommand \(wcmAdd)>
                  <Order>1</Order><CommandLine>\(xmlEscape(shortCmd))</CommandLine>
                </SynchronousCommand>
              </FirstLogonCommands>
            </component>
          </settings>
        """
    }

    private static func xmlEscape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
