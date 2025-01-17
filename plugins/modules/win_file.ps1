#!powershell

# Copyright: (c) 2017, Ansible Project
# GNU General Public License v3.0+ (see COPYING or https://www.gnu.org/licenses/gpl-3.0.txt)

#Requires -Module Ansible.ModuleUtils.Legacy
#AnsibleRequires -PowerShell Ansible.ModuleUtils.AddType

$ErrorActionPreference = "Stop"

$params = Parse-Args $args -supports_check_mode $true

$check_mode = Get-AnsibleParam -obj $params -name "_ansible_check_mode" -default $false
$_remote_tmp = Get-AnsibleParam $params "_ansible_remote_tmp" -type "path" -default $env:TMP

$path = Get-AnsibleParam -obj $params -name "path" -type "path" -failifempty $true -aliases "dest", "name"
$src = Get-AnsibleParam -obj $params -name "src" -type "path" -failifempty ($state -in @("hard", "link", "junction"))
$state = Get-AnsibleParam -obj $params -name "state" -type "str" -validateset "absent", "directory", "file", "touch", "hard", "link", "junction"

# used in template/copy when dest is the path to a dir and source is a file
$original_basename = Get-AnsibleParam -obj $params -name "_original_basename" -type "str"
if ((Test-Path -LiteralPath $path -PathType Container) -and ($null -ne $original_basename)) {
    $path = Join-Path -Path $path -ChildPath $original_basename
}

$result = @{
    changed = $false
}

# Used to delete symlinks as powershell cannot delete broken symlinks
Add-CSharpType -TempPath $_remote_tmp -References @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Ansible.Command {
    public class SymLinkHelper {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        public static extern bool DeleteFileW(string lpFileName);

        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        public static extern bool RemoveDirectoryW(string lpPathName);

        public static void DeleteDirectory(string path) {
            if (!RemoveDirectoryW(path))
                throw new Exception(String.Format("RemoveDirectoryW({0}) failed: {1}", path, new Win32Exception(Marshal.GetLastWin32Error()).Message));
        }

        public static void DeleteFile(string path) {
            if (!DeleteFileW(path))
                throw new Exception(String.Format("DeleteFileW({0}) failed: {1}", path, new Win32Exception(Marshal.GetLastWin32Error()).Message));
        }
    }
}
'@

# Used to delete directories and files with logic on handling symbolic links
function Remove-File($file, $checkmode) {
    try {
        if ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            # Bug with powershell, if you try and delete a symbolic link that is pointing
            # to an invalid path it will fail, using Win32 API to do this instead
            if ($file.PSIsContainer) {
                if (-not $checkmode) {
                    [Ansible.Command.SymLinkHelper]::DeleteDirectory($file.FullName)
                }
            }
            else {
                if (-not $checkmode) {
                    [Ansible.Command.SymlinkHelper]::DeleteFile($file.FullName)
                }
            }
        }
        elseif ($file.PSIsContainer) {
            Remove-Directory -directory $file -checkmode $checkmode
        }
        else {
            Remove-Item -LiteralPath $file.FullName -Force -WhatIf:$checkmode
        }
    }
    catch [Exception] {
        Fail-Json $result "Failed to delete $($file.FullName): $($_.Exception.Message)"
    }
}

function Remove-Directory($directory, $checkmode) {
    foreach ($file in Get-ChildItem -LiteralPath $directory.FullName) {
        Remove-File -file $file -checkmode $checkmode
    }
    Remove-Item -LiteralPath $directory.FullName -Force -Recurse -WhatIf:$checkmode
}

# If state is not supplied, test the $path to see if it looks like
# a file or a folder and set state to file or folder
if ($null -eq $state) {
    $basename = Split-Path -Path $path -Leaf
    if ($basename.length -gt 0) {
        $state = "file"
    }
    else {
        $state = "directory"
    }
}

if ($state -eq "touch") {
    if (Test-Path -LiteralPath $path) {
        if (-not $check_mode) {
            (Get-ChildItem -LiteralPath $path).LastWriteTime = Get-Date
        }
        $result.changed = $true
    }
    else {
        Write-Output $null | Out-File -LiteralPath $path -Encoding ASCII -WhatIf:$check_mode
        $result.changed = $true
    }
}
elseif ($state -in @("hard", "link", "junction")) {
    if (Test-Path -LiteralPath $path) {
        $fileinfo = Get-Item -LiteralPath $path -Force
        if ($state -eq "hard" -and -not $fileinfo.LinkType -eq "HardLink") {
            Fail-Json $result "path $path is not a HardLink"
        }

        if ($state -eq "link" -and -not $fileinfo.LinkType -eq "SymbolicLink") {
            Fail-Json $result "path $path is not a SymbolicLink"
        }

        if ($state -eq "junction" -and -not $fileinfo.LinkType -eq "Junction") {
            Fail-Json $result "path $path is not a Junction"
        }

        if (($src -replace "^\\\\", "UNC\") -in $fileinfo.Target) {
            Exit-Json $result
        }
    }
    if (Test-Path -LiteralPath $src) {
        try {
            if ($state -eq "hard") {
                New-Item -Path $path -Target $src -ItemType HardLink -Force -WhatIf:$check_mode | Out-Null
            }
            elseif ($state -eq "link") {
                New-Item -Path $path -Target $src -ItemType SymbolicLink -Force -WhatIf:$check_mode | Out-Null
            }
            elseif ($state -eq "hard") {
                New-Item -Path $path -Target $src -ItemType Junction -Force -WhatIf:$check_mode | Out-Null
            }
        }
        catch {
            Fail-Json $result $_.Exception.Message
        }
        $result.changed = $true
    }
    else {
        Fail-Json $result "target $src does not exist"
    }
}
elseif ($state -eq "absent") {
    if (Test-Path -LiteralPath $path) {
        $fileinfo = Get-Item -LiteralPath $path -Force
        Remove-File -file $fileinfo -checkmode $check_mode
        $result.changed = $true
    }
}
elseif ($state -eq "directory") {
    if (Test-Path -LiteralPath $path) {
        $fileinfo = Get-Item -LiteralPath $path -Force
        if (-not $fileinfo.PsIsContainer) {
            Fail-Json $result "path $path is not a directory"
        }
    }
    else {
        try {
            New-Item -Path $path -ItemType Directory -WhatIf:$check_mode | Out-Null
        }
        catch {
            if ($_.CategoryInfo.Category -eq "ResourceExists") {
                $fileinfo = Get-Item -LiteralPath $_.CategoryInfo.TargetName
                if ($state -eq "directory" -and -not $fileinfo.PsIsContainer) {
                    Fail-Json $result "path $path is not a directory"
                }
            }
            else {
                Fail-Json $result $_.Exception.Message
            }
        }
        $result.changed = $true
    }
}
elseif ($state -eq "file") {
    if (Test-Path -LiteralPath $path) {
        $fileinfo = Get-Item -LiteralPath $path -Force
        if ($fileinfo.PsIsContainer) {
            Fail-Json $result "path $path is not a file"
        }
    }
    else {
        Fail-Json $result "path $path will not be created"
    }
}

Exit-Json $result
