[CmdletBinding()]
Param(
    [Parameter(Position=1)]
    [String] $Target = "build",
    [String] $AdditionalArgs = '',
    [String] $Build = '',
    [String] $RemotingVersion = '4.3',
    [String] $BuildNumber = "6",
    [switch] $PushVersions = $false
)

$Repository = 'agent'
$Organization = 'jenkins'

Get-Content env.props | ForEach-Object {
    $items = $_.Split("=")
    if($items.Length -eq 2) {
        $name = $items[0].Trim()
        $value = $items[1].Trim()
        Set-Item -Path "env:$($name)" -Value $value
    }
}

if(![String]::IsNullOrWhiteSpace($env:DOCKERHUB_REPO)) {
    $Repository = $env:DOCKERHUB_REPO
}

if(![String]::IsNullOrWhiteSpace($env:DOCKERHUB_ORGANISATION)) {
    $Organization = $env:DOCKERHUB_ORGANISATION
}

if(![String]::IsNullOrWhiteSpace($env:REMOTING_VERSION)) {
    $RemotingVersion = $env:REMOTING_VERSION
}

$builds = @{
    'jdk8' = @{
        'Folder' = '8\windows\windowsservercore-1809';
        'Tags' = @( "windowsservercore-1809", "jdk8-windowsservercore-1809" )
    };
    'jdk11' = @{
        'Folder' = '11\windows\windowsservercore-1809';
        'Tags' = @( "jdk11-windowsservercore-1809" )
    };
    'nanoserver' = @{
        'Folder' = '8\windows\nanoserver-1809';
        'Tags' = @( "nanoserver-1809", "jdk8-nanoserver-1809" )
    };
    'nanoserver-jdk11' = @{
        'Folder' = '11\windows\nanoserver-1809';
        'Tags' = @( "jdk11-nanoserver-1809" )
    };

# this is the jdk version that will be used for the 'bare tag' images, e.g., jdk8-windowsservercore-1809 -> windowsserver-1809
$defaultBuild = '8'
$builds = @{}

Get-ChildItem -Recurse -Include windows -Directory | ForEach-Object {
    Get-ChildItem -Directory -Path $_ | Where-Object { Test-Path (Join-Path $_.FullName "Dockerfile") } | ForEach-Object {
        $dir = $_.FullName.Replace((Get-Location), "").TrimStart("\")
        $items = $dir.Split("\")
        $jdkVersion = $items[0]
        $baseImage = $items[2]
        $basicTag = "jdk${jdkVersion}-${baseImage}"
        $tags = @( $basicTag )
        if($jdkVersion -eq $defaultBuild) {
            $tags += $baseImage
        }

        $builds[$basicTag] = @{
            'Folder' = $dir;
            'Tags' = $tags;
        }
    }
}

if(![System.String]::IsNullOrWhiteSpace($Build) -and $builds.ContainsKey($Build)) {
    foreach($tag in $builds[$Build]['Tags']) {
        Write-Host "Building $Build => tag=$tag"
        $cmd = "docker build --build-arg VERSION='$RemotingVersion' -t {0}/{1}:{2} {3} {4}" -f $Organization, $Repository, $tag, $AdditionalArgs, $builds[$Build]['Folder']
        Invoke-Expression $cmd

        if($PushVersions) {
            $buildTag = "$RemotingVersion-$BuildNumber-$tag"
            if($tag -eq 'latest') {
                $buildTag = "$RemotingVersion-$BuildNumber"
            }
            Write-Host "Building $Build => tag=$buildTag"
            $cmd = "docker build --build-arg VERSION='$RemotingVersion' -t {0}/{1}:{2} {3} {4}" -f $Organization, $Repository, $buildTag, $AdditionalArgs, $builds[$Build]['Folder']
            Invoke-Expression $cmd
        }
    }
} else {
    foreach($b in $builds.Keys) {
        foreach($tag in $builds[$b]['Tags']) {
            Write-Host "Building $b => tag=$tag"
            $cmd = "docker build --build-arg VERSION='$RemotingVersion' -t {0}/{1}:{2} {3} {4}" -f $Organization, $Repository, $tag, $AdditionalArgs, $builds[$b]['Folder']
            Invoke-Expression $cmd

            if($PushVersions) {
                $buildTag = "$RemotingVersion-$BuildNumber-$tag"
                if($tag -eq 'latest') {
                    $buildTag = "$RemotingVersion-$BuildNumber"
                }
                Write-Host "Building $Build => tag=$buildTag"
                $cmd = "docker build --build-arg VERSION='$RemotingVersion' -t {0}/{1}:{2} {3} {4}" -f $Organization, $Repository, $buildTag, $AdditionalArgs, $builds[$b]['Folder']
                Invoke-Expression $cmd
            }
        }
    }
}

if($lastExitCode -ne 0) {
    exit $lastExitCode
}

if($target -eq "test") {
    $mod = Get-InstalledModule -Name Pester -MinimumVersion 4.9.0 -MaximumVersion 4.99.99 -ErrorAction SilentlyContinue
    if($null -eq $mod) {
        $module = "c:\Program Files\WindowsPowerShell\Modules\Pester"
        if(Test-Path $module) {
            takeown /F $module /A /R
            icacls $module /reset
            icacls $module /grant Administrators:'F' /inheritance:d /T
            Remove-Item -Path $module -Recurse -Force -Confirm:$false
        }
        Install-Module -Force -Name Pester -MaximumVersion 4.99.99
    }

    if(![System.String]::IsNullOrWhiteSpace($Build) -and $builds.ContainsKey($Build)) {
        $env:FOLDER = $builds[$Build]['Folder']
        $env:VERSION = "$RemotingVersion-$BuildNumber"
        Invoke-Pester -Path tests -EnableExit
        Remove-Item env:\FOLDER
        Remove-Item env:\VERSION
    } else {
        foreach($b in $builds.Keys) {
            $env:FOLDER = $builds[$b]['Folder']
            $env:VERSION = "$RemotingVersion-$BuildNumber"
            Invoke-Pester -Path tests -EnableExit
            Remove-Item env:\FOLDER
            Remove-Item env:\VERSION
        }
    }
}

if($target -eq "publish") {
    if(![System.String]::IsNullOrWhiteSpace($Build) -and $builds.ContainsKey($Build)) {
        foreach($tag in $Builds[$Build]['Tags']) {
            Write-Host "Publishing $Build => tag=$tag"
            $cmd = "docker push {0}/{1}:{2}" -f $Organization, $Repository, $tag
            Invoke-Expression $cmd

            if($PushVersions) {
                $buildTag = "$RemotingVersion-$BuildNumber-$tag"
                if($tag -eq 'latest') {
                    $buildTag = "$RemotingVersion-$BuildNumber"
                }
                Write-Host "Publishing $Build => tag=$buildTag"
                $cmd = "docker push {0}/{1}:{2}" -f $Organization, $Repository, $buildTag
                Invoke-Expression $cmd
            }
        }
    } else {
        foreach($b in $builds.Keys) {
            foreach($tag in $Builds[$b]['Tags']) {
                Write-Host "Publishing $b => tag=$tag"
                $cmd = "docker push {0}/{1}:{2}" -f $Organization, $Repository, $tag
                Invoke-Expression $cmd

                if($PushVersions) {
                    $buildTag = "$RemotingVersion-$BuildNumber-$tag"
                    if($tag -eq 'latest') {
                        $buildTag = "$RemotingVersion-$BuildNumber"
                    }
                    Write-Host "Publishing $Build => tag=$buildTag"
                    $cmd = "docker push {0}/{1}:{2}" -f $Organization, $Repository, $buildTag
                    Invoke-Expression $cmd
                }
            }
        }
    }
}

if($lastExitCode -ne 0) {
    Write-Error "Build failed!"
} else {
    Write-Host "Build finished successfully"
}
exit $lastExitCode
