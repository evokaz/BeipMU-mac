param(
    [int] $Port = 48740,
    [int] $PhaseOneWaitSeconds = 150,
    [int] $PhaseTwoWaitSeconds = 8,
    [string] $TracePath = 'C:\M5Audit\windows-replay-trace.json'
)

# Milestone 5 release-wide replay stimulus. One deterministic loopback session
# exercises rendering (fragmented ANSI), trigger gag/spawn/send, alias
# expansion, plain and HTML logging, and a /@ SetOnReceive script hook against
# the v331 reference binary. Every byte in both directions is recorded.
$ErrorActionPreference = 'Stop'
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
$events = [Collections.Generic.List[object]]::new()

function Add-Trace([string] $direction, [byte[]] $bytes, [string] $label) {
    $events.Add([ordered]@{
        at = [DateTimeOffset]::Now.ToString('o')
        direction = $direction
        label = $label
        ascii = -join ($bytes | ForEach-Object {
            if ($_ -ge 0x20 -and $_ -le 0x7e) { [char]$_ } else { '.' }
        })
        hex = ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
    })
}

function Send-Bytes([Net.Sockets.NetworkStream] $stream, [byte[]] $bytes, [string] $label) {
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
    Add-Trace 'server-to-client' $bytes $label
}

function Send-Text([Net.Sockets.NetworkStream] $stream, [string] $text, [string] $label) {
    Send-Bytes $stream ([Text.Encoding]::ASCII.GetBytes($text)) $label
}

function Read-Available(
    [Net.Sockets.NetworkStream] $stream,
    [int] $seconds,
    [string] $label,
    [string] $untilASCII
) {
    $deadline = [DateTimeOffset]::Now.AddSeconds($seconds)
    $buffer = [byte[]]::new(8192)
    $received = [Collections.Generic.List[byte]]::new()
    while ([DateTimeOffset]::Now -lt $deadline) {
        try {
            $count = $stream.Read($buffer, 0, $buffer.Length)
        }
        catch [IO.IOException] {
            continue # Receive timeout; keep waiting until the deadline.
        }
        if ($count -eq 0) { break }
        for ($index = 0; $index -lt $count; $index++) {
            $received.Add($buffer[$index])
        }
        if ($untilASCII) {
            $soFar = -join ($received | ForEach-Object {
                if ($_ -ge 0x20 -and $_ -le 0x7e) { [char]$_ } else { '.' }
            })
            if ($soFar.Contains($untilASCII)) { break }
        }
    }
    if ($received.Count -gt 0) {
        Add-Trace 'client-to-server' $received.ToArray() $label
    }
}

$startedAt = [DateTimeOffset]::Now
try {
    $listener.Start()
    $client = $listener.AcceptTcpClient()
    $client.ReceiveTimeout = 2000
    $stream = $client.GetStream()

    Send-Text $stream "M5 replay audit server`r`n" 'banner'
    Send-Bytes $stream ([byte[]](0x1b, 0x5b, 0x33)) 'fragmented ANSI SGR part 1 (ESC [ 3)'
    Start-Sleep -Milliseconds 40
    $ansiTail = [Text.Encoding]::ASCII.GetBytes('1mRed replay line') +
        [byte[]](0x1b, 0x5b, 0x30, 0x6d, 0x0d, 0x0a)
    Send-Bytes $stream $ansiTail 'fragmented ANSI SGR part 2 (1m text ESC [0m CR LF)'
    Send-Text $stream "TRIGGER-GAG: hidden line`r`n" 'line for the gag trigger'
    Send-Text $stream "TRIGGER-SPAWN: routed spawn line`r`n" 'line for the spawn trigger'
    Send-Text $stream "TRIGGER-SEND: provoke response`r`n" 'line for the send trigger'
    $prompt = [Text.Encoding]::ASCII.GetBytes('Replay prompt> ') + [byte[]](0xff, 0xf9)
    Send-Bytes $stream $prompt 'prompt terminated by IAC GA'

    Read-Available $stream $PhaseOneWaitSeconds 'phase 1: negotiation, trigger send, script registration, alias expansion' 'Hail'

    Send-Text $stream "SCRIPT-TARGET: callback line`r`n" 'line for the SetOnReceive script hook'
    Read-Available $stream $PhaseTwoWaitSeconds 'phase 2: bytes after the script hook line' $null
    Send-Text $stream "Replay complete`r`n" 'closing marker line'
    Start-Sleep -Milliseconds 250

    $stream.Close()
    $client.Close()
    $events.Add([ordered]@{ at = [DateTimeOffset]::Now.ToString('o'); direction = 'server'; label = 'disconnect'; ascii = ''; hex = '' })
}
finally {
    $listener.Stop()
    [ordered]@{
        schemaVersion = 1
        reference = 'BeipMU v4.331 ARM64'
        endpoint = "127.0.0.1:$Port"
        startedAt = $startedAt.ToString('o')
        finishedAt = [DateTimeOffset]::Now.ToString('o')
        events = $events
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $TracePath -Encoding UTF8
}
