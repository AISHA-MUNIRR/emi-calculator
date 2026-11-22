param($log = "loop.txt")
$body = '{"principal":500000,"rate":12,"months":24}'
$total = 0; $failed = 0
try {
  while ($true) {
    try {
      $r = Invoke-WebRequest -Method Post -Uri http://emi.local:8080/api/emi -ContentType "application/json" -Body $body -UseBasicParsing -TimeoutSec 3
      $code = [int]$r.StatusCode
    } catch {
      if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } else { $code = 0 }
    }
    $total++
    if ($code -ne 200) { $failed++ }
    $line = "$(Get-Date -Format HH:mm:ss) $code"
    Write-Host $line
    try { Add-Content -Path $log -Value $line -ErrorAction Stop } catch {}
    Start-Sleep -Milliseconds 500
  }
} finally {
  Write-Host "total requests: $total  failed: $failed"
}
