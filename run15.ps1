param(
  [int]$Seconds = 60,
  [int[]]$Replicas = @(1,2,3),
  [int[]]$Rates = @(10,25,50,100,200)
)
$root = "C:\Users\hp\emi-calculator"
Set-Location $root
New-Item -ItemType Directory -Force -Path "$root\results" | Out-Null
$ip = (minikube ip).Trim()
$summary = "$root\results\summary.csv"
if (-not (Test-Path $summary)) {
  "replicas,rate_req_s,seconds,avg_response_ms,replies_2xx,errors_total,request_rate" | Out-File -Encoding ascii $summary
}

function New-Sessions {
  $r = New-Object System.Random
  $out = New-Object System.Collections.Generic.List[string]
  1..40 | ForEach-Object {
    $p = $r.Next(10000, 5000001); $rt = $r.Next(5, 31); $m = $r.Next(6, 121)
    $out.Add('/api/emi method=POST contents=''{"principal":' + $p + ',"rate":' + $rt + ',"months":' + $m + '}''')
    $out.Add('')
  }
  [IO.File]::WriteAllText("$root\loadtest\sessions.txt", ($out -join "`n") + "`n")
}

foreach ($rep in $Replicas) {
  Write-Host "=== $rep replica(s): scaling ==="
  kubectl scale deployment emi-web --replicas=$rep -n emi | Out-Null
  kubectl rollout status deployment/emi-web -n emi --timeout=300s | Out-Null
  Start-Sleep -Seconds 20
  foreach ($rate in $Rates) {
    $tag = "r$rep-rate$rate"
    Write-Host "--- $rep replica(s), $rate req/s, $Seconds s, started $(Get-Date -Format HH:mm:ss) ---"
    New-Sessions
    $topFile = "$root\results\$tag-pods.csv"
    $hostFile = "$root\results\$tag-host.csv"

    $topJob = Start-Job -ArgumentList $topFile -ScriptBlock {
      param($f)
      "timestamp,pod,cpu_millicores,memory_Mi" | Out-File -Encoding ascii $f
      while ($true) {
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $lines = kubectl top pods -n emi --no-headers 2>$null
        foreach ($l in $lines) {
          $p = $l.Trim() -split '\s+'
          if ($p.Count -ge 3) {
            "$ts,$($p[0]),$($p[1] -replace 'm',''),$($p[2] -replace 'Mi','')" | Out-File -Append -Encoding ascii $f
          }
        }
        Start-Sleep -Seconds 15
      }
    }
    $hostJob = Start-Job -ArgumentList $hostFile -ScriptBlock {
      param($f)
      "timestamp,host_cpu_percent" | Out-File -Encoding ascii $f
      while ($true) {
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $v = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
        "$ts,$v" | Out-File -Append -Encoding ascii $f
        Start-Sleep -Milliseconds 800
      }
    }
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
      $okTop  = (Test-Path $topFile)  -and ((Get-Content $topFile  -ErrorAction SilentlyContinue | Measure-Object).Count -ge 2)
      $okHost = (Test-Path $hostFile) -and ((Get-Content $hostFile -ErrorAction SilentlyContinue | Measure-Object).Count -ge 2)
      if ($okTop -and $okHost) { break }
      Start-Sleep -Milliseconds 500
    }

    $text = docker run --rm --network minikube --add-host "emi.local:$ip" -v "${root}\loadtest:/work" emi-httperf $rate $Seconds 2>&1 | Out-String

    Stop-Job $topJob, $hostJob
    Remove-Job $topJob, $hostJob -Force
    $text | Out-File -Encoding ascii "$root\results\$tag-httperf.txt"

    $avg = [regex]::Match($text, 'Reply time \[ms\]: response ([\d\.]+)').Groups[1].Value
    $ok  = [regex]::Match($text, '2xx=(\d+)').Groups[1].Value
    $err = [regex]::Match($text, 'Errors: total (\d+)').Groups[1].Value
    $rr  = [regex]::Match($text, 'Request rate: ([\d\.]+)').Groups[1].Value
    "$rep,$rate,$Seconds,$avg,$ok,$err,$rr" | Out-File -Append -Encoding ascii $summary
    Write-Host "    avg response: $avg ms, 2xx: $ok, errors: $err"
    Start-Sleep -Seconds 20
  }
}
Write-Host "ALL DONE at $(Get-Date -Format HH:mm:ss)"