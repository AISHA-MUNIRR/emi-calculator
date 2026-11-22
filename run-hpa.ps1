param([switch]$Quick, [int]$Cooldown = 300)
$root = "C:\Users\hp\emi-calculator"
Set-Location $root
$dir = "$root\results\hpa"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$ip = (minikube ip).Trim()

if ($Quick) { $phases = @(@{rate=10;secs=10}, @{rate=10;secs=10}); $Cooldown = 15 }
else { $phases = @(@{rate=10;secs=120}, @{rate=100;secs=300}, @{rate=10;secs=180}) }

$r = New-Object System.Random
$out = New-Object System.Collections.Generic.List[string]
1..40 | ForEach-Object {
  $p = $r.Next(10000, 5000001); $rt = $r.Next(5, 31); $m = $r.Next(6, 121)
  $out.Add('/api/emi method=POST contents=''{"principal":' + $p + ',"rate":' + $rt + ',"months":' + $m + '}''')
  $out.Add('')
}
[IO.File]::WriteAllText("$root\loadtest\sessions.txt", ($out -join "`n") + "`n")

$hpaFile = "$dir\hpa-replicas.csv"; $rawFile = "$dir\hpa-raw.txt"
$topFile = "$dir\hpa-pods.csv"; $hostFile = "$dir\hpa-host.csv"; $phaseFile = "$dir\hpa-phases.csv"
Remove-Item $hpaFile,$rawFile,$topFile,$hostFile,$phaseFile -ErrorAction SilentlyContinue

$hpaJob = Start-Job -ArgumentList $hpaFile,$rawFile -ScriptBlock {
  param($f,$raw)
  "timestamp,current_replicas,desired_replicas,avg_cpu_percent" | Out-File -Encoding ascii $f
  while ($true) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $v = kubectl get hpa emi-web -n emi -o jsonpath="{.status.currentReplicas},{.status.desiredReplicas},{.status.currentMetrics[0].resource.current.averageUtilization}" 2>$null
    "$ts,$v" | Out-File -Append -Encoding ascii $f
    "[$ts]" | Out-File -Append -Encoding ascii $raw
    kubectl get hpa emi-web -n emi 2>$null | Out-File -Append -Encoding ascii $raw
    Start-Sleep -Seconds 15
  }
}
$topJob = Start-Job -ArgumentList $topFile -ScriptBlock {
  param($f)
  "timestamp,pod,cpu_millicores,memory_Mi" | Out-File -Encoding ascii $f
  while ($true) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $lines = kubectl top pods -n emi --no-headers 2>$null
    foreach ($l in $lines) {
      $q = $l.Trim() -split '\s+'
      if ($q.Count -ge 3) { "$ts,$($q[0]),$($q[1] -replace 'm',''),$($q[2] -replace 'Mi','')" | Out-File -Append -Encoding ascii $f }
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
  $a = (Get-Content $hpaFile -ErrorAction SilentlyContinue | Measure-Object).Count
  $b = (Get-Content $topFile -ErrorAction SilentlyContinue | Measure-Object).Count
  $c = (Get-Content $hostFile -ErrorAction SilentlyContinue | Measure-Object).Count
  if ($a -ge 2 -and $b -ge 2 -and $c -ge 2) { break }
  Start-Sleep -Milliseconds 500
}

"phase,rate_req_s,start,end" | Out-File -Encoding ascii $phaseFile
$i = 0
foreach ($ph in $phases) {
  $i++; $rate = $ph.rate; $secs = $ph.secs
  $start = Get-Date
  Write-Host "--- phase $i : $rate req/s for $secs s, started $($start.ToString('HH:mm:ss')) ---"
  $text = docker run --rm --network minikube --add-host "emi.local:$ip" -v "${root}\loadtest:/work" emi-httperf $rate $secs 2>&1 | Out-String
  $end = Get-Date
  "$i,$rate,$($start.ToString('yyyy-MM-dd HH:mm:ss')),$($end.ToString('yyyy-MM-dd HH:mm:ss'))" | Out-File -Append -Encoding ascii $phaseFile
  $text | Out-File -Encoding ascii "$dir\httperf-phase$i.txt"
  $avg = [regex]::Match($text, 'Reply time \[ms\]: response ([\d\.]+)').Groups[1].Value
  $ok  = [regex]::Match($text, '2xx=(\d+)').Groups[1].Value
  $err = [regex]::Match($text, 'Errors: total (\d+)').Groups[1].Value
  Write-Host "    avg response: $avg ms, 2xx: $ok, errors: $err"
  Write-Host "    $(kubectl get hpa emi-web -n emi --no-headers)"
}
Write-Host "Test finished. Watching the replicas for $Cooldown more seconds..."
Start-Sleep -Seconds $Cooldown
Stop-Job $hpaJob,$topJob,$hostJob
Remove-Job $hpaJob,$topJob,$hostJob -Force
kubectl get hpa emi-web -n emi
Write-Host "ALL DONE at $(Get-Date -Format HH:mm:ss)"