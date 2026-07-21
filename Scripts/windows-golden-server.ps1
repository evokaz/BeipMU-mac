param(
    [string]$TracePath = "C:\Temp\beipmu-v331-session.trace"
)

$ErrorActionPreference = "Stop"
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 45678)
$events = [System.Collections.Generic.List[object]]::new()

function Add-Trace([string]$direction, [byte[]]$bytes, [string]$label) {
    $events.Add([ordered]@{
        direction = $direction
        label = $label
        hex = ([BitConverter]::ToString($bytes) -replace "-", "").ToLowerInvariant()
    })
}

function Send-Bytes([System.Net.Sockets.NetworkStream]$stream, [byte[]]$bytes, [string]$label) {
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
    Add-Trace "server-to-client" $bytes $label
}

try {
    $listener.Start()
    $client = $listener.AcceptTcpClient()
    $client.ReceiveTimeout = 5000
    $stream = $client.GetStream()

    Send-Bytes $stream ([byte[]](0xff, 0xfb)) "fragmented WILL EOR part 1"
    Start-Sleep -Milliseconds 20
    Send-Bytes $stream ([byte[]](0x19)) "fragmented WILL EOR part 2"

    $buffer = [byte[]]::new(4096)
    $count = $stream.Read($buffer, 0, $buffer.Length)
    $received = [byte[]]::new($count)
    [Array]::Copy($buffer, $received, $count)
    Add-Trace "client-to-server" $received "EOR negotiation and connect text"

    $prompt = [Text.Encoding]::UTF8.GetBytes("Golden prompt> ") + [byte[]](0xff, 0xf9)
    Send-Bytes $stream $prompt "prompt terminated by GA"
    Start-Sleep -Milliseconds 20
    $line = [byte[]](0x1b) + [Text.Encoding]::UTF8.GetBytes("[32mGolden room") + [byte[]](0x1b) + [Text.Encoding]::UTF8.GetBytes("[0m`r`n")
    Send-Bytes $stream $line "ANSI rendered line"
    Start-Sleep -Milliseconds 250

    $stream.Close()
    $client.Close()
    $events.Add([ordered]@{ direction = "server"; label = "disconnect"; hex = "" })
}
finally {
    $listener.Stop()
    [ordered]@{
        schemaVersion = 1
        reference = "BeipMU v331 ARM64"
        endpoint = "127.0.0.1:45678"
        events = $events
    } | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 $TracePath
}
