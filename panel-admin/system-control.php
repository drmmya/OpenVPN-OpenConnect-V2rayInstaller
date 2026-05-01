<?php
require __DIR__.'/config.php'; require_login();
set_time_limit(0); ini_set('max_execution_time','0');
function run_control($args){ return cli('sudo -n /usr/local/bin/vpn-control.sh '.$args); }
function run_bg_control($args,$proto){
  $safe=preg_replace('/[^a-z0-9_-]/i','',$proto);
  $log='/var/log/vpn-panel-install-'.$safe.'.log';
  if((file_exists($log)&&!is_writable($log))||(!file_exists($log)&&!is_writable(dirname($log)))) $log=DATA_DIR.'/vpn-panel-install-'.$safe.'.log';
  $cmd='nohup sudo -n /usr/local/bin/vpn-control.sh '.$args.' > '.escapeshellarg($log).' 2>&1 < /dev/null & echo $!';
  exec($cmd,$out,$code);
  return [$code, trim($out[0]??''), $log];
}
function svc_on($p){ exec('sudo -n /usr/local/bin/vpn-control.sh status '.escapeshellarg($p).' >/dev/null 2>&1',$o,$c); return $c===0; }
function installed($key){ return proto_enabled($key); }
function valid_port($p){ return is_numeric($p) && (int)$p>=1 && (int)$p<=65535; }
$msg=''; $err='';
if($_SERVER['REQUEST_METHOD']==='POST'){
  $action=$_POST['action']??''; $proto=$_POST['proto']??'';
  if(in_array($proto,['openvpn','openconnect','v2ray'],true)){
    if(in_array($action,['start','stop','restart'],true)){ [$c,$o]=run_control($action.' '.escapeshellarg($proto)); $c===0?$msg=$o:$err=$o; }
    if($action==='install'){
      if($proto==='openvpn'){
        $udp=$_POST['udp_port']??1194; $tcp=$_POST['tcp_port']??8443;
        if(!valid_port($udp)||!valid_port($tcp)||((int)$udp===(int)$tcp)) $err='Invalid OpenVPN ports. Use 1-65535 and UDP/TCP must be different.';
        else { $udp=(int)$udp; $tcp=(int)$tcp; [$c,$pid,$log]=run_bg_control('install openvpn '.$udp.' '.$tcp,'openvpn'); }
      } elseif($proto==='openconnect'){
        $port=$_POST['port']??443; if(!valid_port($port)) $err='Invalid OpenConnect port.'; else { $port=(int)$port; [$c,$pid,$log]=run_bg_control('install openconnect '.$port,'openconnect'); }
      } else {
        $port=$_POST['port']??4443; if(!valid_port($port)) $err='Invalid V2Ray port.'; else { $port=(int)$port; [$c,$pid,$log]=run_bg_control('install v2ray '.$port,'v2ray'); }
      }
      if(!$err) $c===0?$msg='Install started in background'.($pid?' (PID '.$pid.')':'').'. Check log: '.$log.'. Refresh this page after it finishes.':$err='Failed to start install job. Check sudo permission and Apache error log.';
    }
    if($action==='change_port'){
      if($proto==='openvpn'){
        $udp=$_POST['udp_port']??cfgv('OVPN_UDP_PORT','1194'); $tcp=$_POST['tcp_port']??cfgv('OVPN_TCP_PORT','8443');
        if(!valid_port($udp)||!valid_port($tcp)||((int)$udp===(int)$tcp)) $err='Invalid OpenVPN ports. Use 1-65535 and UDP/TCP must be different.';
        else { $udp=(int)$udp; $tcp=(int)$tcp; [$c,$o]=run_control('change-port openvpn '.$udp.' '.$tcp); }
      } elseif($proto==='openconnect'){
        $port=$_POST['port']??cfgv('OC_PORT','443'); if(!valid_port($port)) $err='Invalid OpenConnect port.'; else { $port=(int)$port; [$c,$o]=run_control('change-port openconnect '.$port); }
      } else {
        $port=$_POST['port']??cfgv('V2_PORT','4443'); if(!valid_port($port)) $err='Invalid V2Ray port.'; else { $port=(int)$port; [$c,$o]=run_control('change-port v2ray '.$port); }
      }
      if(!$err) $c===0?$msg=$o:$err=$o;
    }
  }
}
$items=[
 ['key'=>'OPENVPN','proto'=>'openvpn','name'=>'OpenVPN','ports'=>'UDP '.cfgv('OVPN_UDP_PORT','1194').' / TCP '.cfgv('OVPN_TCP_PORT','8443')],
 ['key'=>'OPENCONNECT','proto'=>'openconnect','name'=>'OpenConnect','ports'=>cfgv('OC_PORT','443')],
 ['key'=>'V2RAY','proto'=>'v2ray','name'=>'V2Ray/Xray','ports'=>cfgv('V2_PORT','4443')],
];
render_header('System Control'); ?>
<?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?><?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?>
<div class="grid">
<?php foreach($items as $it): $is=installed($it['key']); $running=svc_on($it['proto']); ?>
  <div class="card gradient-card">
    <div class="toolbar"><h2 class="section-title"><?=esc($it['name'])?></h2><span class="badge <?=$running?'green':'red'?>"><?=$running?'RUNNING':'STOPPED'?></span></div>
    <div class="small">Installed: <strong><?=$is?'YES':'NO'?></strong></div>
    <div class="small">Port: <strong><?=esc($it['ports'])?></strong></div><br>
    <form method="post" class="actions">
      <input type="hidden" name="proto" value="<?=esc($it['proto'])?>"><button class="btn green" name="action" value="start">Start</button><button class="btn yellow" name="action" value="restart">Restart</button><button class="btn red" name="action" value="stop">Stop</button>
    </form><br>
    <form method="post">
      <input type="hidden" name="proto" value="<?=esc($it['proto'])?>">
      <?php if($it['proto']==='openvpn'): ?>
        <label>UDP Port</label><input name="udp_port" value="<?=esc(cfgv('OVPN_UDP_PORT','1194'))?>"><br><br><label>TCP Port</label><input name="tcp_port" value="<?=esc(cfgv('OVPN_TCP_PORT','8443'))?>">
      <?php else: ?>
        <label>Port</label><input name="port" value="<?=esc($it['proto']==='openconnect'?cfgv('OC_PORT','443'):cfgv('V2_PORT','4443'))?>">
      <?php endif; ?><br><br>
      <?php if(!$is): ?><button class="btn green" name="action" value="install">Install <?=esc($it['name'])?></button><?php else: ?><button class="btn" name="action" value="change_port">Change Port</button><?php endif; ?>
    </form>
  </div>
<?php endforeach; ?>
</div>
<div class="card" style="margin-top:18px"><h2 class="section-title">Install log</h2><div class="small">Protocol install runs in background so Apache/PHP will not close the browser request. In PuTTY use: <code>tail -f /var/log/vpn-panel-install-openvpn.log</code>, <code>tail -f /var/log/vpn-panel-install-openconnect.log</code>, or <code>tail -f /var/log/vpn-panel-install-v2ray.log</code>.</div></div>
<?php render_footer(); ?>
