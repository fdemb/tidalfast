# Drives TIDALfast's System Media Transport Controls from outside, as the
# media overlay does: finds its session through
# GlobalSystemMediaTransportControlsSessionManager, prints what it shows,
# reads its thumbnail as the overlay would, then pauses it, seeks to 10 s
# and skips to the next track. The media
# workflow checks the app's log for the commands. Needs Windows PowerShell
# 5.1, which projects WinRT types.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1

function Await($operation, [type]$type) {
    $task = $asTask.MakeGenericMethod($type).Invoke($null, @($operation))
    if (-not $task.Wait(10000)) { throw 'timed out' }
    $task.Result
}

$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$manager = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
$sessions = @($manager.GetSessions())
foreach ($s in $sessions) { "session: $($s.SourceAppUserModelId)" }
$session = $sessions | Where-Object { $_.SourceAppUserModelId -like '*tidalfast*' } | Select-Object -First 1
if (-not $session) { throw 'no TIDALfast session' }

$props = Await ($session.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
"title: $($props.Title)"
"artist: $($props.Artist)"
"album: $($props.AlbumTitle)"
if (-not $props.Thumbnail) { throw 'no thumbnail' }
$null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
$thumbnail = Await ($props.Thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
"thumbnail: $($thumbnail.Size) bytes, $($thumbnail.ContentType)"
if ($thumbnail.Size -eq 0) { throw 'empty thumbnail' }
"status: $($session.GetPlaybackInfo().PlaybackStatus)"
"end: $($session.GetTimelineProperties().EndTime)"

if (-not (Await ($session.TryPauseAsync()) ([bool]))) { throw 'pause refused' }
Start-Sleep -Seconds 2
"status after pause: $($session.GetPlaybackInfo().PlaybackStatus)"
# 10 s, in 100 ns units.
if (-not (Await ($session.TryChangePlaybackPositionAsync(100000000)) ([bool]))) { throw 'seek refused' }
Start-Sleep -Seconds 1
if (-not (Await ($session.TrySkipNextAsync()) ([bool]))) { throw 'next refused' }
Start-Sleep -Seconds 1
