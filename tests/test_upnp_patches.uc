'use strict';
import * as fs from 'fs';

// Run from the repository root. The fixture is the upstream LuCI rpcd plugin.
const root = trim(fs.popen('pwd').read('all'));
const tmp = fs.mkdtemp('/tmp/upnp-test-XXXXXX');
const status = 'feeds/luci/applications/luci-app-upnp/root/usr/share/rpcd/ucode/luci.upnp';
function check(ok, message) { if (!ok) die(message + '\n'); }
function write(path, data) {
	check(system(['mkdir', '-p', fs.dirname(tmp + '/' + path)]) == 0, 'mkdir failed');
	check(fs.writefile(tmp + '/' + path, data) != null, 'write failed: ' + path);
}
function apply() { return system(`cd '${tmp}' && bash '${root}/scripts/apply-upnp-patches.sh' >/dev/null 2>&1`); }
write('feeds/packages/net/miniupnpd/files/miniupnpd.init', '\t\tupnpd_write_bool use_stun 0 ext_perform_stun\n');
write('feeds/packages/net/miniupnpd/Makefile', '# fixture\n');
write('feeds/packages/net/miniupnpd/files/nftables.d/chain-post/dstnat/20-miniupnpd.nft', 'jump upnp_prerouting comment "miniupnpd"\n');
write('feeds/luci/applications/luci-app-upnp/htdocs/luci-static/resources/view/upnp/upnp.js', "\t\to = s.taboption('advanced', form.Value, 'stun_host', _('STUN host'));\n");
write(status, fs.readfile(root + '/tests/fixtures/luci.upnp'));
check(apply() == 0, 'initial patch failed');
for (let name in ['100-nat-loopback.patch', '110-stun-input.patch', '120-internal-client-fallback.patch', '130-ipv6-pinhole-client-fallback.patch']) {
	let installed = tmp + '/feeds/packages/net/miniupnpd/patches/' + name;
	check(fs.readfile(installed) == fs.readfile(root + '/patches/' + name), 'patch differs: ' + name);
}
let patched = fs.readfile(tmp + '/' + status);
check(apply() == 0 && fs.readfile(tmp + '/' + status) == patched, 'patch not idempotent');
fs.unlink(tmp + '/feeds/packages/net/miniupnpd/patches/100-nat-loopback.patch');
check(apply() == 0 && fs.readfile(tmp + '/feeds/packages/net/miniupnpd/patches/100-nat-loopback.patch') == fs.readfile(root + '/patches/100-nat-loopback.patch'), 'patch not restored');

// Inject only the external rpcd dependencies; execute the actual patched handler.
let source = replace(patched, /import \{ access, open, popen \} from 'fs';/, '');
source = replace(source, /import \{ connect \} from 'ubus';/, '');
source = replace(source, /import \{ cursor \} from 'uci';/, '');
let prefix = `
let reply;
function connect() { return { defer: (obj, method, args, cb) => cb(0, {}) }; }
function cursor() { return { get: () => '/nonexistent' }; }
function open() { return null; }
function popen(cmd) {
 let lines = index(cmd, 'nft ') == 0 ? split(TEST_LINES, '\\n') : [];
 let i = 0;
 return { read: () => lines[i++], close: () => null };
}
function iptoarr(ip) { return ip; }
function arrtoip(ip) { return ip; }
`;
let lines = [], expected = [];
for (let iface in ['', 'iif "pppoe-wan" ', 'iifname "eth0" '])
 for (let counter in ['', 'counter packets 12 bytes 1024 '])
  for (let spec in [['@nh,72,8 0x6', 'th', 'TCP'], ['@nh,72,8 0x11', 'th', 'UDP'], ['ip protocol tcp', 'tcp', 'TCP'], ['meta l4proto udp', 'udp', 'UDP']]) {
   push(lines, `\t\t${iface}${spec[0]} ${spec[1]} dport 12345 ${counter}dnat ip to 192.168.0.2:54321 comment "test" # handle 8`);
   push(expected, spec[2]);
  }
push(lines, 'chain upnp_prerouting {', 'counter packets 1 bytes 2 accept', '@nh,72,8 0x1 th dport 12345 dnat ip to 192.168.0.2:54321');
// Global value is read by the mock popen implementation in the compiled handler.
global.TEST_LINES = join('\n', lines);
let plugin = loadstring(prefix + source)();
let result;
plugin['luci.upnp'].get_status.call({ reply: (data) => result = data });
check(length(result.rules) == length(expected), 'wrong mapping count: ' + length(result.rules));
for (let i = 0; i < length(expected); i++) {
 let rule = result.rules[i];
 check(rule.proto == expected[i] && rule.extport == 12345 && rule.intaddr == '192.168.0.2' && rule.intport == 54321, 'wrong mapping: ' + sprintf('%J', rule));
}
let init = tmp + '/feeds/packages/net/miniupnpd/files/miniupnpd.init';
fs.writefile(init, '\t\tupnpd_write_bool use_stun 0 ext_perform_stun\n');
let before = fs.readfile(init);
write(status, '// changed upstream\n');
check(apply() != 0 && fs.readfile(init) == before, 'changed anchor was not rejected');
write(status, fs.readfile(root + '/tests/fixtures/luci.upnp'));
write('feeds/packages/net/miniupnpd/files/nftables.d/chain-post/dstnat/20-miniupnpd.nft', 'unexpected upstream content\n');
fs.unlink(tmp + '/feeds/packages/net/miniupnpd/patches/100-nat-loopback.patch');
check(apply() != 0 && !fs.stat(tmp + '/feeds/packages/net/miniupnpd/patches/100-nat-loopback.patch'), 'missing guard was not rejected');
system(['rm', '-rf', tmp]);
print('UPnP patch tests passed (24 mappings).\n');
