<?php
session_start();
date_default_timezone_set('UTC');
define('APP_DIR', __DIR__);
define('DATA_DIR', __DIR__.'/data');
define('DB_PATH', __DIR__.'/data/vpn.sqlite');
define('DOWNLOAD_DIR', __DIR__.'/downloads');
function db(){ static $db=null; if($db===null){ $db=new SQLite3(DB_PATH); $db->busyTimeout(5000); } return $db; }
function esc($v){ return htmlspecialchars((string)$v, ENT_QUOTES, 'UTF-8'); }
function require_login(){ if(empty($_SESSION['admin_user'])){ header('Location: login.php'); exit; } }
function admin_login($u,$p){ $st=db()->prepare('SELECT username,password_hash FROM admins WHERE username=:u LIMIT 1'); $st->bindValue(':u',$u,SQLITE3_TEXT); $r=$st->execute(); $row=$r?$r->fetchArray(SQLITE3_ASSOC):false; return $row && password_verify($p,$row['password_hash']); }
function cli($cmd){ exec($cmd.' 2>&1',$out,$code); return [$code, implode("\n",$out)]; }
function human_bytes($bytes){ $bytes=(float)$bytes; $units=['B','KB','MB','GB','TB']; $i=0; while($bytes>=1024 && $i<count($units)-1){$bytes/=1024;$i++;} return ($i===0?(string)(int)$bytes:number_format($bytes,2)).' '.$units[$i]; }
function bw_total($row){ return (int)($row['rx'] ?? 0) + (int)($row['tx'] ?? 0); }
function vps_bandwidth(){
    $out = shell_exec('vnstat --json 2>/dev/null');
    if(!$out) return ['today'=>0,'month'=>0,'total'=>0,'ready'=>false];
    $data = json_decode($out, true);
    $iface = $data['interfaces'][0] ?? null;
    if(!$iface) return ['today'=>0,'month'=>0,'total'=>0,'ready'=>false];
    $traffic = $iface['traffic'] ?? [];
    $days = $traffic['day'] ?? [];
    $months = $traffic['month'] ?? [];
    $today = $days ? bw_total(end($days)) : 0;
    $month = $months ? bw_total(end($months)) : 0;
    $total = bw_total($traffic['total'] ?? []);
    return ['today'=>$today,'month'=>$month,'total'=>$total,'ready'=>true];
}
function vpn_conf(){ $f='/etc/vpn-protocols.conf'; return is_file($f) ? parse_ini_file($f) : []; }
function proto_enabled($k){ $c=vpn_conf(); return !empty($c[$k]) && (string)$c[$k] !== '0'; }
function cfgv($k,$d=''){ $c=vpn_conf(); return isset($c[$k]) ? $c[$k] : $d; }
function render_header($title='VPN Panel'){
$brand=$title ?: 'VPN Panel';
?>
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title><?=esc($brand)?></title><link rel="stylesheet" href="style.css"></head>
<body><div class="shell"><header class="site-header"><div class="brand-wrap"><button class="menu-btn" type="button" onclick="document.body.classList.toggle('menu-open')">☰</button><div><div class="brand"><?=esc($brand)?></div><div class="sub">Logged in as <?=esc($_SESSION['admin_user'] ?? '')?></div></div></div><a class="refresh-btn" href="<?=esc(basename($_SERVER['PHP_SELF']).(!empty($_SERVER['QUERY_STRING'])?'?'.$_SERVER['QUERY_STRING']:''))?>">Refresh</a></header><div class="layout"><aside class="sidebar"><nav class="menu">
<a href="index.php">Dashboard</a>
<?php if(proto_enabled('OPENVPN')): ?><a href="openvpn.php">OpenVPN Panel</a><?php endif; ?>
<?php if(proto_enabled('OPENCONNECT')): ?><a href="openconnect.php">OpenConnect Panel</a><?php endif; ?>
<?php if(proto_enabled('V2RAY')): ?><a href="v2ray.php">V2Ray Panel</a><?php endif; ?>
<a href="change_password.php">Change Admin Password</a><a href="logout.php">Logout</a>
</nav></aside><main class="content">
<?php }
function render_footer(){ ?>
</main></div></div><div id="toast" class="toast">Copied!</div><script>
function showToast(msg){var t=document.getElementById('toast'); if(!t)return; t.textContent=msg||'Copied!'; t.classList.add('show'); setTimeout(function(){t.classList.remove('show')},1600)}
function copyText(txt){ if(navigator.clipboard){navigator.clipboard.writeText(txt).then(function(){showToast('Copied!')}).catch(function(){fallbackCopy(txt)})} else fallbackCopy(txt); }
function fallbackCopy(txt){var x=document.createElement('textarea'); x.value=txt; document.body.appendChild(x); x.select(); try{document.execCommand('copy');showToast('Copied!')}catch(e){showToast('Copy failed')} document.body.removeChild(x)}
document.addEventListener('click',function(e){if(document.body.classList.contains('menu-open')&&!e.target.closest('.sidebar')&&!e.target.closest('.menu-btn'))document.body.classList.remove('menu-open'); var b=e.target.closest('[data-copy]'); if(b){e.preventDefault(); copyText(b.getAttribute('data-copy')||'');}});
</script></body></html>
<?php }
