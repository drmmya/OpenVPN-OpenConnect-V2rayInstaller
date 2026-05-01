<?php
require __DIR__.'/config.php'; require_login();
function svc_on($p){ exec('sudo /usr/local/bin/vpn-control.sh status '.escapeshellarg($p).' >/dev/null 2>&1',$o,$c); return $c===0; }
function run_control($args){ return cli('sudo /usr/local/bin/vpn-control.sh '.$args); }
$msg='';$err='';
if($_SERVER['REQUEST_METHOD']==='POST'){
  $action=$_POST['action']??''; $proto=$_POST['proto']??'';
  if(in_array($action,['start','stop','restart'],true) && in_array($proto,['openvpn','openconnect','v2ray'],true)){ [$c,$o]=run_control($action.' '.escapeshellarg($proto)); $c===0?$msg=$o:$err=$o; }
  if($action==='quick_install' && in_array($proto,['openvpn','openconnect','v2ray'],true)){
    if($proto==='openvpn') [$c,$o]=run_control('install openvpn '.(int)($_POST['udp_port']??1194).' '.(int)($_POST['tcp_port']??8443));
    elseif($proto==='openconnect') [$c,$o]=run_control('install openconnect '.(int)($_POST['port']??443));
    else [$c,$o]=run_control('install v2ray '.(int)($_POST['port']??4443));
    $c===0?$msg=$o:$err=$o;
  }
}
$bw=vps_bandwidth();
$cards=[['OPENVPN','openvpn','OpenVPN'],['OPENCONNECT','openconnect','OpenConnect'],['V2RAY','v2ray','V2Ray/Xray']];
render_header('VPN Panel'); ?>
<?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?><?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?>
<div class="hero-grid">
<?php foreach($cards as $c): $installed=proto_enabled($c[0]); $running=svc_on($c[1]); ?>
  <div class="card gradient-card"><div class="toolbar"><div><div class="muted"><?=esc($c[2])?></div><div class="kpi <?=$installed?'status-on':'status-off'?>"><?=$installed?'ON':'OFF'?></div></div><span class="badge <?=$running?'green':'red'?>"><?=$running?'RUNNING':'STOPPED'?></span></div><form method="post" class="actions"><input type="hidden" name="proto" value="<?=esc($c[1])?>"><button class="btn green" name="action" value="start">Start</button><button class="btn yellow" name="action" value="restart">Restart</button><button class="btn red" name="action" value="stop">Stop</button></form><?php if(!$installed): ?><br><a class="btn" href="system_control.php">Install / Set Port</a><?php endif; ?></div>
<?php endforeach; ?>
</div>
<div class="card bandwidth-card" style="margin-top:18px"><div class="toolbar"><div><h2 class="section-title" style="margin-bottom:6px">Total VPS Bandwidth</h2><div class="small">System bandwidth from vnStat.</div></div><span class="badge green"><?= $bw['ready']?'Tracking ON':'Waiting for data'?></span></div><div class="grid"><div class="card"><div class="muted">Today</div><div class="kpi small-kpi"><?=esc(human_bytes($bw['today']))?></div></div><div class="card"><div class="muted">This Month</div><div class="kpi small-kpi"><?=esc(human_bytes($bw['month']))?></div></div><div class="card"><div class="muted">All Time</div><div class="kpi small-kpi"><?=esc(human_bytes($bw['total']))?></div></div></div></div>
<div class="card" style="margin-top:18px"><div class="toolbar"><div><h2 class="section-title" style="margin-bottom:6px">Installed Ports</h2><div class="small">Vertical cards for clean pro view.</div></div><a class="btn" href="system_control.php">System Control</a></div><div class="port-list"><?php if(proto_enabled('OPENVPN')): ?><div class="port-item"><strong>OpenVPN UDP</strong><span class="port-value"><?=esc(cfgv('OVPN_UDP_PORT','1194'))?></span></div><div class="port-item"><strong>OpenVPN TCP</strong><span class="port-value"><?=esc(cfgv('OVPN_TCP_PORT','8443'))?></span></div><?php else: ?><div class="port-item"><strong>OpenVPN</strong><a class="btn green" href="system_control.php">Install</a></div><?php endif; ?><?php if(proto_enabled('OPENCONNECT')): ?><div class="port-item"><strong>OpenConnect</strong><span class="port-value"><?=esc(cfgv('OC_PORT','443'))?></span></div><?php else: ?><div class="port-item"><strong>OpenConnect</strong><a class="btn green" href="system_control.php">Install</a></div><?php endif; ?><?php if(proto_enabled('V2RAY')): ?><div class="port-item"><strong>V2Ray/Xray</strong><span class="port-value"><?=esc(cfgv('V2_PORT','4443'))?></span></div><?php else: ?><div class="port-item"><strong>V2Ray/Xray</strong><a class="btn green" href="system_control.php">Install</a></div><?php endif; ?></div></div>
<?php render_footer(); ?>
