from pathlib import Path
import hashlib, os, subprocess, tarfile, tempfile

installer=Path(__file__).resolve().parents[1] / 'config/platform/m2/install-external.sh'
ids=[n*8+'-'+n*4+'-'+n*4+'-'+n*4+'-'+n*12 for n in '123']
with tempfile.TemporaryDirectory(prefix='ordo-external-check-') as directory:
    base=Path(directory)
    for sub in ('dev','tree/chosen','bin','kernel','work'):
        (base/sub).mkdir(parents=True)
    (base/'tree/compatible').write_bytes(b'apple,j413\0')
    (base/'tree/chosen/asahi,efi-system-partition').write_bytes(ids[2].encode()+b'\0')
    for value in ids:
        (base/'dev'/value).touch()
    for name in ('vmlinuz-7.0.9-asahi-2','system-asahi.img','vmlinuz-asahi.EFI','modules.tar.gz','hostid'):
        (base/'kernel'/name).write_bytes(b'test')
    for n in range(4):
        (base/f'rootfs.tar.gz.part{n:02}').write_bytes(b'test')
    text=installer.read_text().replace('/proc/device-tree',str(base/'tree')).replace('/dev/disk/by-partuuid/',str(base/'dev')+'/').replace('[ -b "$device" ]','[ -f "$device" ]').replace('/mnt/ordo-external.',str(base/'work/ordo-external.'))
    digest = hashlib.sha256(b'test').hexdigest()
    minimum = (installer.parent / 'minimum-root-bytes').read_text().strip()
    text = text.replace('PAYLOAD=/mnt/payload', 'PAYLOAD=' + str(base)).replace('@DIRECT_SHA@', digest).replace('@UKI_SHA@', digest).replace('@SYSTEM_SHA@', digest).replace('@BUNDLE_SHA@', digest).replace('@MIN_ROOT_BYTES@', minimum).replace('@BAREFILES_SHA@', digest).replace('@KERNEL_RELEASE@', '7.0.9-asahi-2').replace('@KERNEL_SHA@', digest)
    (base/'installer').write_text(text.replace('@NATIVE_SHA@', ''))
    fake=base/'bin/fixture'
    fake.write_text(r'''#!/bin/sh
name=${0##*/}
for arg do last=$arg; done
printf '%s %s\n' "$name" "$*" >> "$LOG"
case "$name" in
id) echo 0 ;;
findmnt)
    case "$*" in
        *MAJ:MIN*) echo "${PAYLOAD_NUMBER:-8:1}";;
        *OPTIONS*) echo "${PAYLOAD_OPTIONS:-ro}";;
    esac ;;
lsblk)
    case "$*" in
        *PKNAME*33333333*) echo nvme0n1 ;;
        *PKNAME*22222222*) echo "${ROOT_PARENT:-sda}" ;;
        *PKNAME*) echo sda ;;
        *TRAN*FSTYPE*) echo fixture-layout ;;
        *TRAN*) echo "${DEVICE_TRAN:-usb}" ;;
        *PTTYPE*) echo "${PARTITION_TABLE:-gpt}" ;;
        *-dnro*MAJ:MIN*11111111*) echo 8:1 ;;
        *MAJ:MIN*11111111*) printf '  8:1  \n' ;;
        *MOUNTPOINTS*11111111*) printf '%s' "$PAYLOAD_MOUNTS" ;;
    esac ;;
blockdev) case "$last" in */22222222*) echo "${ROOT_SIZE:-60000000000}";; *) echo 64000000000;; esac ;;
blkid)
    case "$*" in
        *PART_ENTRY_UUID*22222222*)
            if [ -n "$CHANGED_ROOT_ID" ] && [ "$(grep -c 'PART_ENTRY_UUID.*22222222' "$LOG")" -gt 1 ]; then
                echo "$CHANGED_ROOT_ID"
            else
                echo "${last##*/}"
            fi;;
        *PART_ENTRY_UUID*) echo "${last##*/}";;
        *LABEL*11111111*) echo ORDOPAYLOAD;; *TYPE*11111111*) echo vfat;;
        *LABEL*22222222*) echo ORDOZFS;; *TYPE*22222222*) echo exfat;; *) exit 1;; esac ;;
mount)
    case "$last" in
        */system) mkdir -p "$last/m1n1" "$last/vendorfw"; echo test > "$last/m1n1/boot.bin"; echo test > "$last/vendorfw/firmware.cpio";;
        */boot) mkdir -p "$last/extlinux"; touch "$last/extlinux/ordo-manual.conf"; mkdir -p "$last/live"; printf %s "${DIRECT_DATA:-test}" > "$last/live/ordo-$DIGEST.efi"; printf test > "$last/live/zbm-$DIGEST.efi"; printf test > "$last/live/system-$DIGEST.img"; printf %s "${BUNDLE_DATA:-test}" > "$last/desktop-$DIGEST.tar.gz"; printf %s "${NATIVE_DATA:-test}" > "$last/native-$DIGEST.tar.gz"; printf test > "$last/live/vmlinuz-7.0.9-asahi-2-$DIGEST";;
    esac ;;
mountpoint) exit 1 ;;
modprobe|zpool|umount) exit 0 ;;
wipefs|zfs|mkswap) exit 99 ;;
*) exit 99 ;;
esac
''')
    fake.chmod(0o755)
    for name in ('id','findmnt','lsblk','blockdev','blkid','mount','mountpoint','modprobe','zpool','umount','wipefs','zfs','mkswap'):
        (base/'bin'/name).symlink_to('fixture')
    env=dict(os.environ,DIGEST=digest,PATH=str(base/'bin')+':'+os.environ['PATH'],LOG=str(base/'events'))
    def run(mode, updates=None, answer=None):
        (base/'events').write_text('')
        result=subprocess.run(['/bin/sh',str(base/'installer'),mode,*ids[:2]],text=True,input=answer,capture_output=True,env={**env,**(updates or {})})
        logs=(base/'events').read_text()
        assert not any(action in logs for action in ('wipefs -a','zpool create','mount -o remount,rw')), logs
        return result,logs
    result,log=run('--check')
    assert result.returncode==0 and log.count('-o ro ') == 2,(result.stdout,result.stderr,log)
    result,_=run('--check',{'ROOT_PARENT':'sdb'})
    assert result.returncode==1 and '同一块外接盘' in result.stderr,result.stderr
    result,_=run('--check',{'DEVICE_TRAN':'sata'})
    assert result.returncode==1 and 'USB' in result.stderr,result.stderr
    result,_=run('--check',{'PARTITION_TABLE':'dos'})
    assert result.returncode==1 and 'GPT' in result.stderr,result.stderr
    result,_=run('--check',{'ROOT_SIZE':'16000000000'})
    assert result.returncode==1 and '32 GiB' in result.stderr,result.stderr
    result,_=run('--apply',{'CHANGED_ROOT_ID':ids[0]},answer='INSTALL 2222\n')
    assert result.returncode==1 and 'PARTUUID 已变化' in result.stderr,result.stderr
    result,_=run('--apply',{'BUNDLE_DATA':'changed'},answer='INSTALL 2222\n')
    assert result.returncode != 0 and '桌面安装包校验失败' in result.stderr
    result,_=run('--apply',{'DIRECT_DATA':'changed'},answer='INSTALL 2222\n')
    assert result.returncode != 0 and 'Ordo EFI 校验失败' in result.stderr
    with tarfile.open(base/'barefiles.tar.gz', 'w:gz') as archive:
        service_state = tarfile.TarInfo('var/lib/example-service')
        service_state.type = tarfile.DIRTYPE
        service_state.uid = service_state.gid = 120
        archive.addfile(service_state)
    result,_=run('--apply',answer='INSTALL 2222\n')
    assert result.returncode != 0 and '真机软件包校验失败' in result.stderr
    (base/'barefiles.tar.gz').write_bytes(b'test')
    result,_=run('--apply',answer='yes\n')
    assert result.returncode==1 and '已取消' in result.stderr,result.stderr
    (base/'installer').write_text(text.replace('@NATIVE_SHA@', digest))
    result,_=run('--check')
    assert result.returncode==0, (result.stdout,result.stderr)
    result,_=run('--apply',{'NATIVE_DATA':'changed'},answer='INSTALL 2222\n')
    assert result.returncode != 0 and '原生安装包校验失败' in result.stderr
    print('PASS: external target guards, typed UUID and native payload integrity before wipe.')

    (base/'live').mkdir()
    (base/'extlinux').mkdir()
    (base/'EFI/BOOT').mkdir(parents=True)
    boot_efi = base/'EFI/BOOT/BOOTAA64.EFI'
    boot_efi.write_bytes(b'initial portable Live EFI')
    public = base/'ordo-live-efi.pem'
    private = base/'test-private'
    subprocess.run(['openssl','ecparam','-name','prime256v1','-genkey','-noout','-out',str(private)], check=True)
    subprocess.run(['openssl','pkey','-in',str(private),'-pubout','-out',str(public)], check=True)
    subprocess.run(['openssl','dgst','-sha256','-sign',str(private),'-out',
                    str(base/'live/ordo-live.efi.sig'),str(boot_efi)], check=True)
    (base/'extlinux/ordo-manual.conf').touch()
    for file in ('desktop-HASH.tar.gz', 'live/ordo-HASH.efi', 'live/zbm-HASH.efi',
                 'live/system-HASH.img', 'live/vmlinuz-7.0.9-asahi-2-HASH', 'native-HASH.tar.gz'):
        (base/file.replace('HASH', digest)).write_bytes(b'test')
    hostid = base/'ordo-install-hostid'
    hostid.write_bytes(b'0001')
    (base/'kernel/hostid').unlink()
    portable = text.replace('@NATIVE_SHA@', digest).replace('@USB_PAYLOAD@', '1')
    portable = portable.replace('/ordo-install-hostid', str(hostid)).replace('/ordo-live-efi.pem', str(public))
    (base/'installer').write_text(portable.replace('@PAYLOAD_HASHES@', f'{digest}  rootfs.tar.gz.part01'))
    mounted = {'PAYLOAD_MOUNTS': str(base)}
    result,logs=run('--check', mounted)
    assert result.returncode == 0 and logs.count('-o ro ') == 1, (result.stdout, result.stderr, logs)
    (base/'tree/compatible').write_bytes(b'apple,j493\0')
    result,_=run('--apply', mounted, answer='INSTALL 2222\n')
    assert result.returncode != 0 and 'Mac14,2' in result.stderr
    (base/'tree/compatible').write_bytes(b'apple,j413\0')
    for updates, error in [
        ({'PAYLOAD_NUMBER': '8:3'}, '指定的外置启动分区'),
        ({'PAYLOAD_OPTIONS': 'rw'}, '只读'),
        ({'PAYLOAD_MOUNTS': f'{base}\n/other'}, '其他挂载'),
    ]:
        result,_=run('--apply', {**mounted, **updates}, answer='INSTALL 2222\n')
        assert result.returncode != 0 and error in result.stderr, (result.stdout, result.stderr)
    original_efi = boot_efi.read_bytes()
    boot_efi.write_bytes(b'already installed system')
    result,_=run('--apply', mounted, answer='INSTALL 2222\n')
    assert result.returncode != 0 and 'EFI 与本次 Live 镜像不匹配' in result.stderr
    boot_efi.write_bytes(original_efi)
    (base/'rootfs.tar.gz.part01').write_bytes(b'changed')
    result,_=run('--apply', mounted, answer='INSTALL 2222\n')
    assert result.returncode != 0 and '外置载荷校验失败' in result.stderr
    print('PASS: USB-only payload accepts exactly the selected read-only mount and verifies it before wipe.')

    # Exercise the packaged launcher with ordinary files standing in for devices.
    launcher = (installer.parent / 'launcher').read_text()
    launcher = launcher.replace('/dev/disk/by-partuuid/', str(base/'dev') + '/')
    launcher = launcher.replace('@BOOT_ID@', ids[0]).replace('@ROOT_ID@', ids[1])
    launcher = launcher.replace('[ -b ', '[ -f ').replace('/ordo-engine', str(base/'engine'))
    (base/'launcher').write_text(launcher)
    (base/'engine').write_text('echo "engine $*" >> "$LOG"\n')
    sleep = base/'bin/sleep'
    sleep.write_text('''#!/bin/sh
echo tick >> "$LOG"
if [ -n "$LATE" ] && [ "$(wc -l < "$LOG")" -eq 3 ]; then touch "$LATE"; fi
''')
    sleep.chmod(0o755)
    for late in (None, base/'dev'/ids[0], base/'dev'/ids[1]):
        for value in ids[:2]:
            (base/'dev'/value).touch()
        missing = late or base/'dev'/ids[1]
        missing.unlink()
        (base/'events').write_text('')
        result = subprocess.run(['sh', str(base/'launcher'), '--check'],
                                env={**env, 'LATE': str(late or '')}, capture_output=True, text=True)
        events = (base/'events').read_text().splitlines()
        if late:
            assert result.returncode == 0 and events == ['tick'] * 3 + ['engine --check ' + ' '.join(ids[:2])], events
        else:
            assert result.returncode == 1 and events.count('tick') == 45 and 'ordo-install --check' in result.stdout
            assert not any(line.startswith('engine ') for line in events)
    print('PASS: Live waits for both authorized partitions and stops on timeout.')

    # Only the opted-in internal FAT partition may receive diagnostic reports.
    mountdir = base/'log-volume'
    mountdir.mkdir()
    source = (installer.parent/'save-live-log.sh').read_text()
    logscript = base/'save-log'
    logscript.write_text(source.replace('/mnt/payload', str(mountdir)).replace('@LOG_ID@', ids[2]))
    for name, body in {
        'findmnt': 'case "$3" in SOURCE) echo "$LOG_SOURCE";; FSTYPE) echo vfat;; OPTIONS) echo ro,nosuid;; esac',
        'blkid': 'case "$2" in PARTUUID) echo "$LOG_UUID";; LABEL) echo ORDOINNER;; esac',
        'mount': 'echo "$2" >> "$LOG"',
        'sync': ':',
    }.items():
        command = base/'bin'/name
        if command.is_symlink():
            command.unlink()
        command.write_text('#!/bin/sh\n' + body + '\n')
        command.chmod(0o755)
    for dev, uid, expected in [('/dev/sda1', ids[2], False), ('/dev/nvme0n1p5', ids[1], False),
                                ('/dev/nvme0n1p5', ids[2], True)]:
        (base/'events').write_text('')
        proc = subprocess.run(['sh', str(logscript), 'start'], env={**env, 'LOG_SOURCE': dev, 'LOG_UUID': uid})
        events = (base/'events').read_text()
        assert (proc.returncode == 0) == expected
        assert ('remount,rw' in events) == expected and ('remount,ro' in events) == expected
        assert (mountdir/'ordo-live-start.log').exists() == expected

# A missing udev link must not turn disk order into an installation identity.
with tempfile.TemporaryDirectory() as directory:
    base = Path(directory)
    for disk in ("sda1", "sdb2"):
        (base / disk).touch()
    (base / "blkid").write_text('#!/bin/sh\nfor arg do last=$arg; done\ncase "$last" in */sdb2) echo "$TEST_UUID";; *) echo other;; esac\n')
    (base / "zpool").write_text('#!/bin/sh\n[ "$1" = import ] || exit 1\nprintf "%s\\n" "$*"\n')
    for command in ("blkid", "zpool"):
        (base / command).chmod(0o755)
    script = (installer.parent / "wait-usb.sh").read_text().replace("@ROOT_ID@", ids[1])
    script = script.replace("/dev/", str(base) + "/").replace(" -b ", " -f ").replace("sleep 1", ":")
    for probed_uuid in (ids[1], ids[0]):
        env = dict(os.environ, PATH=str(base) + ":" + os.environ["PATH"], TEST_UUID=probed_uuid)
        result = subprocess.run(["sh", "-c", script], capture_output=True, text=True, env=env, check=True)
        if probed_uuid == ids[1]:
            assert result.stdout.strip() == f"import -N -d {base}/sdb2 rpool"
        else:
            assert not result.stdout and "did not appear" in result.stderr
