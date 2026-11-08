<#
.SYNOPSIS
Runs Build.ps1 in a container, on the oldest PowerShell the module supports and on a recent one.

.DESCRIPTION
Build.ps1 tests the module on the PowerShell of the machine it runs on, and the manifest promises 7.4 and later.
For each version below, this script builds an image from the Containerfile beside it (Ubuntu 24.04, as the
ubuntu-latest of the CI, with Pester and PSScriptAnalyzer at the versions of .github/workflows/publish.yml) and runs
Build.ps1 in it:
- as a user that is not root, since root reads and deletes files whatever their modes, and the tests that take a
  permission away would not test what they mean to;
- without network, with the repository mounted read-only and copied inside, so that nothing the build or the tests
  do reaches this machine. Each run starts from the image as it was built.

Needs Podman or Docker. With rootless Podman the user of the container is a subordinate user of this machine, which
reads the repository only if others can read its files, as git checks them out unless the umask says otherwise.
The images stay, as elektomailposh-test:<version>, so the next run starts at once; remove them with
"podman rmi" (or "docker rmi").

.PARAMETER Version
The versions of PowerShell to run on, of those listed in this script. Default: all of them.

.EXAMPLE
./Tests/Container/Invoke-ContainerBuild.ps1

.EXAMPLE
./Tests/Container/Invoke-ContainerBuild.ps1 -Version 7.4.22
#>
param (
    [string[]]$Version
)

$ErrorActionPreference = 'Stop'

# Each version with the SHA-256 of its linux-x64 tarball, as GitHub lists it with the release
$releases = [ordered]@{
    '7.4.22' = '9de443bef974f219c98a33b0f4096aace7f30b42188f37a1b14c5da7e82c8a6a'  # 7.4: the oldest the manifest takes
    '7.6.9'  = '1da6d6d6035d651f20e70ddee7c4c15ac6ab8b9fb40ee92240d91263f28a884b'
}
if (-not $Version) { $Version = @($releases.Keys) }
$unknown = @($Version | Where-Object { -not $releases.Contains($_) })
if ($unknown) { throw "No SHA-256 for PowerShell $($unknown -join ', '): add the version to `$releases in $PSCommandPath." }

$engine = @('podman', 'docker' | Where-Object { Get-Command $_ -CommandType Application -ErrorAction Ignore })[0]
if (-not $engine) { throw 'Needs Podman or Docker.' }
$repository = Split-Path (Split-Path $PSScriptRoot)

$failed = [System.Collections.Generic.List[string]]::new()
foreach ($each in $Version) {
    $image = "elektomailposh-test:$each"
    Write-Host "Building $image with $engine..."
    & $engine build --quiet --tag $image --build-arg "PWSH_VERSION=$each" --build-arg "PWSH_SHA256=$($releases[$each])" $PSScriptRoot | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not build $image." }

    Write-Host "Running Build.ps1 on PowerShell $each..."
    & $engine run --rm --network none --volume "${repository}:/src:ro" $image pwsh -NoProfile -NonInteractive -Command 'Copy-Item -Path /src -Destination ~/work -Recurse; Set-Location ~/work; ./Build.ps1' | Out-Host
    if ($LASTEXITCODE -ne 0) { $failed.Add($each) }
}
if ($failed) { throw "Build.ps1 failed on PowerShell $($failed -join ', ')." }
Write-Host "Build.ps1 passed on PowerShell $($Version -join ', ')."
