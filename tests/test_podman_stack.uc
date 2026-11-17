'use strict';
import * as fs from 'fs';
const root = trim(fs.popen('pwd').read('all'));
const tmp = fs.mkdtemp('/tmp/podman-test-XXXXXX');
const defs = tmp + '/defs', bin = tmp + '/bin', statefile = tmp + '/state.json';
function check(ok, message) { if (!ok) die(message + '\n'); }
check(system(['mkdir', '-p', defs, bin]) == 0, 'mkdir failed');
let ucode = getenv('UCODE_BIN') ?? 'ucode', lib = getenv('UCODE_LIB');
fs.writefile(bin + '/podman', `#!/bin/sh\nexec '${ucode}' ${lib ? "-L '" + lib + "'" : ''} '${root}/tests/mock_podman.uc' "$@"\n`);
fs.writefile(bin + '/logger', '#!/bin/sh\necho "$*" >> "$MOCK_LOG"\n');
system(['chmod', '+x', bin + '/podman', bin + '/logger']);
let script = fs.readfile(root + '/files/usr/bin/podman-stack');
script = replace(script, 'DEFS_DIR=/etc/podman-stack.d', 'DEFS_DIR=' + defs);
script = replace(script, 'LOCK_DIR=/var/run/podman-stack.lock', 'LOCK_DIR=' + tmp + '/lock');
script = replace(script, 'RETRY_DIR=/var/run/podman-stack-retry', 'RETRY_DIR=' + tmp + '/retry');
fs.writefile(tmp + '/podman-stack', script); system(['chmod', '+x', tmp + '/podman-stack']);
fs.writefile(defs + '/app.conf', 'NAME=app\nIMAGE=example:latest\ncreate() { podman create "$NAME" "$IMAGE"; }\n');
function write(s) { fs.writefile(statefile, sprintf('%J', s)); }
function read() { return json(fs.readfile(statefile)); }
function reset(extra) { write({ containers: { app: { image: 'old', running: true } }, ...extra }); }
function run(arg, ok) {
 let rc = system(`PATH='${bin}':"$PATH" MOCK_STATE='${statefile}' MOCK_LOG='${tmp}/log' '${tmp}/podman-stack' '${arg}' >/dev/null 2>&1`);
 check((rc == 0) == ok, `unexpected ${arg} exit ${rc}`); return read();
}
reset({}); let updated = run('update', true).containers.app; check(updated.image == 'new' && updated.running, 'update failed');
for (let flag in ['fail_create', 'fail_new_start']) {
 reset({ [flag]: true }); let app = run('update', false).containers.app;
 check(app.image == 'old' && app.running, 'rollback failed: ' + flag);
}
check(index(fs.readfile(tmp + '/log'), 'start diagnostic') >= 0, 'missing start diagnostic');
reset({}); let s = read(); s.containers.app.running = false; write(s); check(!run('update', true).containers.app.running, 'started stopped container');
reset({ fail_start: true }); fs.unlink(defs + '/app.conf'); s = read(); s.containers.app.health = true; write(s);
check(!run('watchdog', false).containers.app.running, 'watchdog failure'); s = read(); s.fail_start = false; s.containers.app.health = false; write(s); check(run('watchdog', true).containers.app.running, 'watchdog retry');
reset({ fail_start: true }); s = read(); s.containers.app.health = true; write(s); run('watchdog', false); s = read(); s.fail_start = false; s.containers.app.stopped_by_user = true; write(s); check(!run('watchdog', true).containers.app.running, 'manual stop ignored');
for (let test in [['always', false, true], ['unless-stopped', false, true], ['always', true, false], ['no', false, false], ['on-failure', false, false]]) {
 reset({}); s = read(); s.containers.app.running = false; s.containers.app.policy = test[0]; s.containers.app.stopped_by_user = test[1]; write(s);
 check(run('watchdog', true).containers.app.running == test[2], 'wrong recovery policy');
}
reset({ unknown_stopped: true }); s = read(); s.containers.app.running = false; s.containers.app.policy = 'always'; write(s); check(!run('watchdog', false).containers.app.running, 'unknown stop state');
reset({}); s = read(); s.containers.app.running = false; s.containers.app.status = 'created'; s.containers.app.policy = 'always'; write(s); check(!run('watchdog', true).containers.app.running, 'started created container');
reset({ fail_service_stop: true }); s = read(); s.containers.app.health = true; write(s); check(run('watchdog', false).containers.app.running, 'unsupported stop');
check(index(fs.readfile(tmp + '/log'), 'unsupported service stop') >= 0, 'missing service stop diagnostic');
fs.writefile(defs + '/app.conf', 'NAME=app\nIMAGE=example:latest\ncreate() { podman create "$NAME" "$IMAGE"; }\n');
for (let mode in ['remove', 'tagged', 'used']) {
 fs.unlink(defs + '/.state/app.previous-image'); reset({}); run('update', true); s = read(); s.next_image = 'newer';
 if (mode == 'tagged') s.tags['localhost/other:keep'] = 'old';
 if (mode == 'used') s.containers.other = { image: 'old', running: true };
 write(s); s = run('update', true);
 check(index(values(s.tags), 'new') >= 0, 'previous image not retained');
 check(index(s.removed_images ?? [], 'old') >= 0 == (mode == 'remove'), 'older image cleanup: ' + mode);
}
reset({}); s = read(); s.containers['app-podman-stack-backup'] = { image: 'old', running: false }; write(s); check(run('update', false).containers.app.image == 'old', 'backup failed to block update');
system(['rm', '-rf', tmp]); print('Podman stack tests passed.\n');
