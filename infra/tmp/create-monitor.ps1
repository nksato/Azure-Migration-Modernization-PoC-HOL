$html = @'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Cutover Monitor</title>
<style>
body { font-family: Consolas, monospace; margin: 20px; background: #1e1e1e; color: #d4d4d4; }
h1 { color: #569cd6; }
#status { font-size: 24px; font-weight: bold; padding: 15px; margin: 10px 0; border-radius: 5px; }
.onprem { background: #d32f2f; color: white; }
.cloud { background: #2e7d32; color: white; }
.down { background: #ff9800; color: white; }
#log { background: #252526; padding: 10px; border-radius: 5px; max-height: 400px; overflow-y: auto; font-size: 14px; }
.log-entry { margin: 2px 0; }
iframe { width: 100%; height: 500px; border: 2px solid #569cd6; margin-top: 10px; }
</style>
</head><body>
<h1>Cutover Monitor - APP01.lab.local</h1>
<div id="status" class="down">Checking...</div>
<div id="log"></div>
<iframe id="appframe" src="http://APP01.lab.local/"></iframe>
<script>
var logDiv = document.getElementById("log");
var statusDiv = document.getElementById("status");
var frame = document.getElementById("appframe");
function check() {
  var ts = new Date().toLocaleTimeString();
  var xhr = new XMLHttpRequest();
  xhr.open("GET", "http://APP01.lab.local/", true);
  xhr.timeout = 5000;
  xhr.onload = function() {
    var isCloud = xhr.responseText.indexOf("CLOUD") !== -1;
    var isOnprem = xhr.responseText.indexOf("ONPREM") !== -1;
    var env = isCloud ? "CLOUD" : (isOnprem ? "ONPREM" : "UNKNOWN");
    var cls = isCloud ? "cloud" : (isOnprem ? "onprem" : "down");
    statusDiv.className = cls;
    statusDiv.textContent = ts + " - " + env + " (HTTP " + xhr.status + ")";
    addLog(ts, env, xhr.status);
  };
  xhr.onerror = function() {
    statusDiv.className = "down";
    statusDiv.textContent = ts + " - DOWN";
    addLog(ts, "DOWN", "ERR");
  };
  xhr.ontimeout = function() {
    statusDiv.className = "down";
    statusDiv.textContent = ts + " - TIMEOUT";
    addLog(ts, "TIMEOUT", "---");
  };
  xhr.send();
  frame.src = "http://APP01.lab.local/?t=" + Date.now();
}
function addLog(ts, env, code) {
  var e = document.createElement("div");
  e.className = "log-entry";
  e.textContent = ts + "  " + env + "  HTTP=" + code;
  logDiv.insertBefore(e, logDiv.firstChild);
  if (logDiv.children.length > 100) logDiv.removeChild(logDiv.lastChild);
}
setInterval(check, 5000);
check();
</script></body></html>
'@

Set-Content -Path 'C:\Users\Public\Desktop\cutover-monitor.html' -Value $html -Encoding UTF8
Write-Output 'Monitor page created at C:\Users\Public\Desktop\cutover-monitor.html'
