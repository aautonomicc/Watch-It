[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Url,

    [string] $OutputDirectory = (Join-Path $HOME 'Downloads\Watch-Media-Intake'),

    [ValidateSet('private', 'public')]
    [string] $Visibility = 'private',

    [switch] $RightsAttested,

    [switch] $IncludeSubtitles,

    [string] $Language = 'lv',

    [string] $Creator = '',

    [ValidateRange(0, 1000)]
    [int] $MaxItems = 250
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RightsAttested) {
    throw 'Stop: pass -RightsAttested only when you own the media or have permission to download and upload it.'
}

$source = [Uri]::new($Url)
if ($source.Scheme -notin @('http', 'https') -or
    $source.Host -notin @('youtube.com', 'www.youtube.com', 'm.youtube.com', 'youtu.be')) {
    throw 'Url must be a YouTube video or playlist URL.'
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ytCandidates = @(
    (Join-Path $scriptDir 'yt-dlp.exe'),
    (Join-Path $HOME 'Downloads\Watch-Media-Intake\tools\yt-dlp.exe'),
    'yt-dlp.exe',
    'yt-dlp'
)
$yt = $null
foreach ($candidate in $ytCandidates) {
    if ($candidate -like '*\*' -or $candidate -like '*/*') {
        if (Test-Path -LiteralPath $candidate) {
            $yt = (Resolve-Path -LiteralPath $candidate).Path
            break
        }
    } else {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            $yt = $command.Source
            break
        }
    }
}
if ($null -eq $yt) {
    throw 'yt-dlp was not found. Put yt-dlp.exe beside this script or on PATH.'
}

$ffmpeg = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$target = Join-Path $OutputDirectory ("youtube-$stamp")
New-Item -ItemType Directory -Force -Path $target | Out-Null

$isPlaylist = $source.Query -match '(?:^|[?&])list='
$template = if ($isPlaylist) { '%(playlist_index)03d-%(id)s.%(ext)s' } else { '%(id)s.%(ext)s' }
$limitArgs = @()
if ($isPlaylist -and $MaxItems -gt 0) {
    $limitArgs = @('--playlist-end', [string]$MaxItems)
}

$args = @(
    '--no-warnings',
    '--no-overwrites',
    '--write-info-json',
    '--write-description',
    '--write-thumbnail',
    '--convert-thumbnails', 'jpg',
    '--no-abort-on-error',
    '--merge-output-format', 'mp4',
    '--output', (Join-Path $target $template)
)
if ($null -ne $ffmpeg) {
    $args += @('--ffmpeg-location', (Split-Path -Parent $ffmpeg.Source))
}
if ($IncludeSubtitles) {
    $args += @('--write-subs', '--sub-langs', $Language, '--sub-format', 'vtt')
}
$args += $limitArgs
$args += '--yes-playlist'
$args += $Url

Write-Host ('Importing {0} into {1}' -f $(if ($isPlaylist) { 'playlist' } else { 'video' }), $target)
Write-Host 'Private-by-default: this helper never publishes to an Autonomi channel.'
& $yt @args
if ($LASTEXITCODE -ne 0) {
    throw "yt-dlp failed with exit code $LASTEXITCODE"
}

$manifest = [ordered]@{
    schema = 1
    sourceUrl = $Url
    sourceKind = if ($isPlaylist) { 'youtube-playlist' } else { 'youtube-video' }
    downloadedAt = (Get-Date).ToUniversalTime().ToString('o')
    visibility = $Visibility
    privateUploadDefault = $true
    rightsAttested = $true
    creator = $Creator
    language = $Language
    subtitlesIncluded = [bool]$IncludeSubtitles
    maxItems = $MaxItems
    nextStep = 'Review each file in W@tch Add to W@tch, confirm creator/source/licence, then upload privately. Use Channels to make a deliberate public publication.'
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $target 'w@tch-import.json')
Write-Host ('Import complete. Review the files in W@tch before upload: {0}' -f $target)
