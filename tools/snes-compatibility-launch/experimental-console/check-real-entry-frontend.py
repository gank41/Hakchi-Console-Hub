#!/usr/bin/env python3
"""Host-only end-to-end console-entry experiment; no console I/O."""
import gzip, hashlib, os, pathlib, re, shlex, shutil, signal, struct, subprocess, tempfile, sys
w=pathlib.Path(__file__).resolve().parent; repo=w.parents[2]; helper=w.parent; crypto=repo/'vendor/mbedtls'
allowed = {'--manager-prepare-crash', '--manager-save-crash-before', '--manager-save-crash-after', '--runtime-lock-manager-gameplay', '--runtime-lock-no-sram'}
if len(sys.argv) != 2 or sys.argv[1] not in allowed:
 raise SystemExit('Choose a documented synthetic host fixture mode.')
if not all(os.environ.get(k) for k in ('HC_HOST_FRONTEND', 'HC_HOST_CORE', 'HC_LIBRETRO_INCLUDE')):
 raise SystemExit('Set HC_HOST_FRONTEND, HC_HOST_CORE and HC_LIBRETRO_INCLUDE to local host build paths.')
frontend=pathlib.Path(os.environ['HC_HOST_FRONTEND']); core=pathlib.Path(os.environ['HC_HOST_CORE'])
postspawn_smoke = sys.argv[1:] in (['--postspawn-failure'], ['--postspawn-gameplay-owner'], ['--postspawn-manager-gameplay-owner'], ['--runtime-lock-postspawn-manager'])
ordered_image_no_sram = sys.argv[1:]==['--manager-screenshot-ordered-no-sram']
ordered_image_conflict = sys.argv[1:]==['--manager-screenshot-ordered-conflict']
actual_manager_tamper = sys.argv[1:]==['--manager-actual-request-time-tamper']
actual_manager_late_tamper = sys.argv[1:]==['--manager-actual-request-time-late-tamper']
actual_manager_resume = sys.argv[1:] in (['--manager-actual-request-resume'], ['--manager-native-state-resume'], ['--manager-native-state-resume-same'], ['--manager-native-state-resume-time-tamper'])
state_archive_wire = sys.argv[1:]==['--manager-actual-request-with-archive-wire']
state_archive_after_tamper = sys.argv[1:]==['--manager-actual-request-with-archive-tamper']
state_package_failure = sys.argv[1:]==['--manager-actual-request-with-archive-package-failure']
state_package_no_sram = sys.argv[1:]==['--manager-actual-request-with-archive-package-no-sram']
native_symlink = sys.argv[1:]==['--manager-native-state-symlink']
native_occupied = native_symlink or sys.argv[1:]==['--manager-native-state-occupied']
native_late_conflict = sys.argv[1:]==['--manager-native-state-late-conflict']
native_tamper = sys.argv[1:]==['--manager-native-state-tamper']
native_no_sram = sys.argv[1:]==['--manager-native-state-no-sram']
native_resume = sys.argv[1:] in (['--manager-native-state-resume'], ['--manager-native-state-resume-same'], ['--manager-native-state-resume-time-tamper'])
selected_foreign = sys.argv[1:]==['--manager-native-selected-foreign']
selected_wrong_prior = sys.argv[1:]==['--manager-native-selected-wrong-prior']
selected_symlink = sys.argv[1:] in (['--manager-native-selected-symlink'], ['--manager-native-selected-discover-symlink'])
selected_foreign_profiles = sys.argv[1:] in (['--manager-native-selected-foreign-profiles'], ['--manager-native-selected-discover-foreign-profiles'])
selected_before_start = sys.argv[1:] in (['--manager-native-selected-before-start'], ['--manager-native-selected-discover-before-start'])
selected_during_wait = sys.argv[1:]==['--manager-native-selected-during-wait']
selected_shared = sys.argv[1:]==['--manager-native-selected-shared-profiles']
selected_discover = sys.argv[1:] in (['--manager-native-selected-discover'], ['--manager-native-selected-discover-foreign'], ['--manager-native-selected-discover-incomplete'], ['--manager-native-selected-discover-ambiguous'], ['--manager-native-selected-discover-corrupt'], ['--manager-native-selected-discover-multiple'], ['--manager-native-selected-discover-symlink'], ['--manager-native-selected-discover-foreign-profiles'], ['--manager-native-selected-discover-before-start'], ['--manager-native-selected-discover-before-bind'], ['--manager-native-selected-discover-parent-symlink'], ['--manager-native-selected-discover-parent-writable'], ['--manager-native-selected-discover-many'], ['--manager-native-selected-discover-many-ambiguous'])
selected_discover_foreign = sys.argv[1:]==['--manager-native-selected-discover-foreign']
selected_discover_incomplete = sys.argv[1:]==['--manager-native-selected-discover-incomplete']
selected_discover_ambiguous = sys.argv[1:] in (['--manager-native-selected-discover-ambiguous'], ['--manager-native-selected-discover-many-ambiguous'])
selected_discover_many = sys.argv[1:] in (['--manager-native-selected-discover-many'], ['--manager-native-selected-discover-many-ambiguous'])
selected_discover_corrupt = sys.argv[1:]==['--manager-native-selected-discover-corrupt']
selected_discover_multiple = sys.argv[1:]==['--manager-native-selected-discover-multiple']
selected_discover_bind_race = sys.argv[1:]==['--manager-native-selected-discover-before-bind']
selected_discover_parent_symlink = sys.argv[1:]==['--manager-native-selected-discover-parent-symlink']
selected_discover_parent_writable = sys.argv[1:]==['--manager-native-selected-discover-parent-writable']
native_selected = selected_foreign or selected_wrong_prior or selected_symlink or selected_foreign_profiles or selected_before_start or selected_during_wait or selected_shared or selected_discover or sys.argv[1:]==['--manager-native-selected-load']
native_mode_unsupported = sys.argv[1:]==['--manager-native-state-mode-unsupported']
native_interrupt = {'--manager-native-state-interrupt-binding':1,'--manager-native-state-interrupt-intent':2,'--manager-native-state-interrupt-publish':3}.get(sys.argv[1] if len(sys.argv)==2 else '')
native_state = native_selected or native_occupied or native_late_conflict or native_tamper or native_no_sram or native_resume or native_mode_unsupported or bool(native_interrupt) or sys.argv[1:]==['--manager-native-state']
actual_manager_state = native_state or state_archive_wire or state_archive_after_tamper or state_package_failure or state_package_no_sram or sys.argv[1:] in (['--manager-actual-request-with-archive'], ['--manager-actual-request-with-archive-no-sram'], ['--manager-actual-request-with-archive-interrupt'])
actual_manager_request = actual_manager_tamper or actual_manager_late_tamper or actual_manager_resume or actual_manager_state or sys.argv[1:] in (['--manager-actual-request-time'], ['--manager-actual-request-time-no-sram'])
ordered_time_no_sram = native_no_sram or state_package_no_sram or sys.argv[1:] in (['--manager-screenshot-time-ordered-no-sram'], ['--manager-actual-request-time-no-sram'], ['--manager-actual-request-with-archive-no-sram'])
ordered_time_conflict = sys.argv[1:]==['--manager-screenshot-time-ordered-conflict']
resume_no_sram = sys.argv[1:] in (['--manager-resumed-time-no-sram'],['--manager-resumed-time-same-no-sram'])
resume_tamper = sys.argv[1:] in (['--manager-resumed-time-tamper'],['--manager-resumed-time-same-tamper'],['--manager-native-state-resume-time-tamper'])
resume_swap = sys.argv[1:] in (['--manager-resumed-time-swap'],['--manager-resumed-time-same-swap'])
resume_early = sys.argv[1:] in (['--manager-resumed-time-before-launch-change'],['--manager-resumed-time-same-before-launch-change'])
resume_target_conflict = sys.argv[1:]==['--manager-resumed-time-target-conflict']
seed_backup_conflict = sys.argv[1:]==['--manager-resumed-time-backup-conflict']
seed_backup_early = sys.argv[1:]==['--manager-resumed-time-backup-before-launch-change']
seed_backup_late = sys.argv[1:]==['--manager-resumed-time-backup-after-game-change']
seed_backup_interrupt = sys.argv[1:]==['--manager-resumed-time-backup-interrupt']
resume_same_format = sys.argv[1:] in (['--manager-resumed-time-same-preserve-format'],['--manager-resumed-time-same-format-after-rename'])
same_time_rename = {'--manager-resumed-time-same-before-rename':'before','--manager-resumed-time-same-after-rename':'after','--manager-resumed-time-same-format-after-rename':'after'}.get(sys.argv[1] if len(sys.argv)==2 else '')
resume_same = bool(same_time_rename) or resume_same_format or sys.argv[1:] in (['--manager-resumed-time-same-target'],['--manager-resumed-time-same-no-sram'],['--manager-resumed-time-same-tamper'],['--manager-resumed-time-same-swap'],['--manager-resumed-time-same-before-launch-change'],['--manager-native-state-resume-same'])
resume_original = b'0043\n' if resume_same_format else b'43'
resume_interrupt = {'--manager-resumed-time-interrupt-intent':4,'--manager-resumed-time-interrupt-publish':5}.get(sys.argv[1] if len(sys.argv)==2 else '')
resume_invalid = {'--manager-resumed-time-missing':'missing','--manager-resumed-time-malformed':'malformed','--manager-resumed-time-symlink':'symlink'}.get(sys.argv[1] if len(sys.argv)==2 else '')
resumed_time = actual_manager_resume or seed_backup_interrupt or seed_backup_conflict or seed_backup_early or seed_backup_late or resume_same or bool(resume_interrupt) or bool(resume_invalid) or resume_target_conflict or resume_early or resume_swap or resume_no_sram or resume_tamper or sys.argv[1:]==['--manager-resumed-time']
ordered_time_interrupt = resume_interrupt or {'--manager-time-ordered-interrupt-intent':4,'--manager-time-ordered-interrupt-publish':5}.get(sys.argv[1] if len(sys.argv)==2 else '')
ordered_time = actual_manager_request or resumed_time or bool(ordered_time_interrupt) or ordered_time_no_sram or ordered_time_conflict or sys.argv[1:]==['--manager-screenshot-time-ordered']
ordered_image_interrupt = {'--manager-ordered-interrupt-binding':1,'--manager-ordered-interrupt-intent':2,'--manager-ordered-interrupt-publication':3}.get(sys.argv[1] if len(sys.argv)==2 else '')
ordered_image = ordered_time or bool(ordered_image_interrupt) or ordered_image_no_sram or ordered_image_conflict or sys.argv[1:]==['--manager-screenshot-ordered']
manager_time_journals = sys.argv[1:]==['--manager-screenshot-time-journals']
manager_time_no_sram = sys.argv[1:]==['--manager-screenshot-time-publish-no-sram']
manager_time_interrupt = ordered_time_interrupt or {'--manager-time-interrupt-intent':4,'--manager-time-interrupt-publish':5}.get(sys.argv[1] if len(sys.argv)==2 else '')
manager_time_publish = bool(manager_time_interrupt) or manager_time_no_sram or sys.argv[1:]==['--manager-screenshot-time-publish']
manager_no_sram = resume_no_sram or ordered_time_no_sram or manager_time_no_sram or ordered_image_no_sram or sys.argv[1:]==['--manager-screenshot-publication-no-sram']
retained_no_sram_crash = sys.argv[1:]==['--manager-screenshot-retained-no-sram-crash']
retained_no_sram = manager_no_sram or retained_no_sram_crash or sys.argv[1:]==['--manager-screenshot-retained-no-sram']
shared_no_sram = retained_no_sram or sys.argv[1:] in (['--runtime-lock-no-sram'], ['--shared-no-sram-cleanup'], ['--shared-no-sram-captured-snapshot'], ['--no-sram-gameplay-owner'])
no_sram_smoke = sys.argv[1:]==['--no-sram-cleanup'] or shared_no_sram
late_no_sram_smoke = sys.argv[1:]==['--late-nosram-loss']
runtime_lock_gameplay = sys.argv[1:] in (['--runtime-lock-no-sram'], ['--runtime-lock-orphan'], ['--runtime-lock-manager-gameplay'], ['--runtime-lock-postspawn-manager'], ['--manager-save-crash-before'], ['--manager-save-crash-after'], ['--manager-prepare-crash'])
manager_signal_wait = sys.argv[1:]==['--manager-signal-wait']
manager_signal_early = manager_signal_wait or sys.argv[1:]==['--manager-signal-early']
publication_crash = {'--manager-save-crash-before':'before','--manager-save-crash-after':'after','--manager-prepare-crash':'prepare'}.get(sys.argv[1] if len(sys.argv)==2 else '')
unsafe_screenshot_signal = sys.argv[1:]==['--manager-screenshot-unsafe-sigpipe']
unbound_screenshot = sys.argv[1:]==['--manager-screenshot-unbound']
retained_save_crash = sys.argv[1:]==['--manager-screenshot-retained-save-crash']
manager_image_interruption = ordered_image_interrupt or {'--manager-image-interrupt-binding':1,'--manager-image-interrupt-intent':2,'--manager-image-interrupt-publication':3}.get(sys.argv[1] if len(sys.argv)==2 else '')
manager_image_publish = manager_time_publish or manager_time_journals or ordered_image or bool(manager_image_interruption) or manager_no_sram or sys.argv[1:]==['--manager-screenshot-publication']
retained_screenshot_conflict = sys.argv[1:]==['--manager-screenshot-retained-conflict']
retained_screenshot_crash = retained_no_sram_crash or retained_save_crash or sys.argv[1:]==['--manager-screenshot-retained-crash']
retained_screenshot = manager_image_publish or retained_no_sram or retained_screenshot_crash or retained_screenshot_conflict or sys.argv[1:]==['--manager-screenshot-retained']
manager_state_conflict = sys.argv[1:]==['--manager-checkpoint-conflict']
manager_bad_seed = sys.argv[1:]==['--manager-checkpoint-bad-seed']
manager_missing_seed = sys.argv[1:]==['--manager-checkpoint-missing-seed']
manager_tamper_seed = sys.argv[1:]==['--manager-checkpoint-tampered-seed']
manager_autoload = manager_bad_seed or manager_missing_seed or manager_tamper_seed or sys.argv[1:]==['--manager-checkpoint-autoload']
state_archive_conflict = sys.argv[1:]==['--manager-checkpoint-retained-conflict']
state_archive_tamper = sys.argv[1:]==['--manager-checkpoint-retained-tamper']
state_archive_crash = state_archive_wire or sys.argv[1:] in (['--manager-checkpoint-retained-interrupt'], ['--manager-actual-request-with-archive-interrupt'])
state_archive_partial = {'--manager-checkpoint-retained-dir-interrupt':1,'--manager-checkpoint-retained-binding-interrupt':2,'--manager-checkpoint-retained-intent-interrupt':3}.get(sys.argv[1] if len(sys.argv)==2 else '')
state_archive_reload = sys.argv[1:]==['--manager-checkpoint-archive-reload']
retained_state = actual_manager_state or state_archive_conflict or state_archive_tamper or state_archive_crash or state_archive_partial or state_archive_reload or sys.argv[1:]==['--manager-checkpoint-retained-state']
manager_state = retained_state or manager_autoload or manager_state_conflict or sys.argv[1:]==['--manager-checkpoint-gameplay']
manager_screenshot = manager_state or unsafe_screenshot_signal or unbound_screenshot or retained_screenshot or sys.argv[1:]==['--manager-screenshot-gameplay']
manager_signal = bool(publication_crash) or manager_signal_early or manager_screenshot or sys.argv[1:]==['--manager-signal-gameplay']
if manager_screenshot: frontend=w/('stock-state-receipt-frontend/retroarch' if manager_state else 'stock-screenshot-receipt-frontend/retroarch')
manager_gameplay = runtime_lock_gameplay or manager_signal or sys.argv[1:] in (['--manager-gameplay-owner'], ['--postspawn-manager-gameplay-owner'])
observed_stock_menu = sys.argv[1:]==['--observed-stock-menu']
unsupported_gameplay = sys.argv[1:]==['--unsupported-gameplay-owner'] or observed_stock_menu
stale_gameplay = sys.argv[1:]==['--stale-gameplay-owner']
gameplay_owner = unsupported_gameplay or stale_gameplay or manager_gameplay or sys.argv[1:] in (['--app-native-gameplay-owner'], ['--power-gameplay-owner'], ['--postspawn-gameplay-owner'], ['--no-sram-gameplay-owner'])
capture_prior = sys.argv[1:] in (['--app-native-captured-snapshot'], ['--shared-no-sram-captured-snapshot']) or gameplay_owner
shared_finalize = (manager_gameplay and not shared_no_sram) or sys.argv[1:] in (['--app-native-shared-finalize'], ['--app-native-captured-snapshot'], ['--app-native-gameplay-owner'], ['--power-gameplay-owner'], ['--postspawn-gameplay-owner'])
app_native_homebrew_save = sys.argv[1:]==['--app-native-homebrew-save'] or shared_finalize
replay_smoke = sys.argv[1:]==['--replay-session']
app_homebrew_save = sys.argv[1:]==['--app-homebrew-save'] or app_native_homebrew_save
app_library = sys.argv[1:] in (['--app-library'], ['--app-library-save'])
app_menu_save = sys.argv[1:] in (['--app-menu-save'], ['--app-library-save'], ['--app-homebrew-save'], ['--app-native-homebrew-save']) or shared_finalize
app_menu_smoke = sys.argv[1:]==['--app-menu'] or app_menu_save or app_library
no_sram = sys.argv[1:]==['--no-sram'] or no_sram_smoke or late_no_sram_smoke or (app_menu_smoke and not app_menu_save)
small_sram = sys.argv[1:]==['--small-sram']
size_2k = sys.argv[1:]==['--sram-2k']
size_64k = sys.argv[1:]==['--sram-64k']
size_128k = sys.argv[1:]==['--sram-128k']
bound_smoke = sys.argv[1:]==['--bound-smoke']
finish_smoke = sys.argv[1:]==['--finish-cleanup']
orphan_lock_smoke = sys.argv[1:] in (['--orphan-lock'], ['--runtime-lock-orphan'])
changed_save_smoke = sys.argv[1:]==['--changed-save'] or app_homebrew_save or orphan_lock_smoke or postspawn_smoke or unsupported_gameplay or stale_gameplay
late_input_smoke = sys.argv[1:]==['--late-input-loss']
late_cleanup_smoke = sys.argv[1:]==['--late-cleanup-loss']
late_power_smoke = sys.argv[1:]==['--late-power']
late_power_after_publish = sys.argv[1:]==['--late-power-after-publish']
if not manager_signal and sys.argv[1:] not in (['--observed-stock-menu'], ['--runtime-lock-no-sram'], ['--runtime-lock-orphan'], ['--runtime-lock-postspawn-manager'], ['--runtime-lock-manager-gameplay'], ['--postspawn-manager-gameplay-owner'], ['--manager-gameplay-owner'], ['--stale-gameplay-owner'], ['--unsupported-gameplay-owner'], ['--power-gameplay-owner'], ['--no-sram-gameplay-owner'], ['--postspawn-gameplay-owner'], ['--app-native-gameplay-owner'], ['--shared-no-sram-captured-snapshot'], ['--app-native-captured-snapshot'], ['--postspawn-failure'], [], ['--no-sram'], ['--no-sram-cleanup'], ['--shared-no-sram-cleanup'], ['--small-sram'], ['--sram-2k'], ['--sram-64k'], ['--sram-128k'], ['--bound-smoke'], ['--finish-cleanup'], ['--changed-save'], ['--orphan-lock'], ['--app-homebrew-save'], ['--app-native-homebrew-save'], ['--app-native-shared-finalize'], ['--late-input-loss'], ['--late-cleanup-loss'], ['--late-power'], ['--late-nosram-loss'], ['--late-power-after-publish'], ['--replay-session'], ['--app-menu'], ['--app-menu-save'], ['--app-library'], ['--app-library-save']): raise SystemExit('Unknown fixture mode')
expected_size = 0 if no_sram else 8192 if small_sram else 2048 if size_2k else 65536 if size_64k else 131072 if size_128k else 32768
rom=pathlib.Path('/nonexistent/synthetic-game')
assert frontend.is_file() and core.is_file() and (changed_save_smoke or shared_no_sram or rom.is_file())
root=pathlib.Path(tempfile.mkdtemp(prefix='hc-real-entry-'));objects=root/'objects';objects.mkdir(mode=0o700)
if changed_save_smoke or shared_no_sram:
 # A tiny original LoROM program increments battery RAM and loops.
 # It avoids relying on a proprietary game or synthetic frontend behavior.
 rom=root/'write-save.sfc'
 data=bytearray([0xff]*131072)
 data[:13]=bytes([0x78,0xaf,0x00,0x00,0x70,0x18,0x69,0x01,0x8f,0x00,0x00,0x70,0x80])
 data[13]=0xfe
 if shared_no_sram: data[:2]=bytes([0x80,0xfe])
 data[0x7fc0:0x7fd5]=b'HAKCHI SAVE TEST     '
 data[0x7fd5:0x7fdb]=bytes([0x20,0x02,0x07,0x05,0x01,0x33])
 if shared_no_sram: data[0x7fd5:0x7fdb]=bytes([0x20,0x00,0x07,0x00,0x01,0x33])
 data[0x7fdc:0x7fe0]=bytes([0xff,0xff,0x00,0x00])
 data[0x7ffc:0x7ffe]=bytes([0x00,0x80])
 rom.write_bytes(data)
game='CLV-U-ABCDE'; app_command=None
if app_menu_smoke:
 source_rom=rom
 app_exec=root/'app-exec';rom=root/('app-rom.sfc' if app_homebrew_save else 'app-rom.smc')
 library_game='CLV-U-ABCDE'
 filename='synthetic-game.sfc'
 source=source_rom
 source_hash=hashlib.sha256(source.read_bytes()).hexdigest()
 assert hashlib.sha256(source.read_bytes()).hexdigest()==source_hash
 if app_library:
  library_files=[source,source.parent/(library_game+'.desktop'),source.parent/(library_game+'.png')]
  library_hashes=[hashlib.sha256(p.read_bytes()).hexdigest() for p in library_files]
 env=dict(os.environ,HC_COMPAT_MENU_SOURCE_ROM=str(source),HC_COMPAT_MENU_EXEC_FIXTURE=str(app_exec),HC_COMPAT_MENU_ROM_FIXTURE=str(rom),CLANG_MODULE_CACHE_PATH='/private/tmp/hc-clang-cache',SWIFTPM_MODULECACHE_OVERRIDE='/private/tmp/hc-swift-cache')
 if app_library:
  env['HC_COMPAT_MENU_SOURCE_GAME']=str(source.parent)
  app_request=root/'app-request';env['HC_COMPAT_MENU_REQUEST_FIXTURE']=str(app_request)
 app_filter='SNESLibraryStartupScriptsTests/offlineCompatibilityVerifierChecksTheWholeMenu' if app_native_homebrew_save else 'SNESLibraryReviewDraftTests/mixedCompatibilityMenuCandidateIsVersionedAndCannotBeTransferred'
 swift_command=['swift','test','--package-path',str(repo),'--disable-sandbox']
 if os.environ.get('HC_SWIFT_SCRATCH'): swift_command += ['--scratch-path',os.environ['HC_SWIFT_SCRATCH']]
 app_test=subprocess.run(swift_command+['--filter',app_filter],env=env,check=True,stdout=subprocess.PIPE,text=True)
 assert app_filter.split('/')[-1] in app_test.stdout and 'Test run with 1 test' in app_test.stdout and 'failed' not in app_test.stdout, 'app fixture must report a completed passing test'
 assert hashlib.sha256(source.read_bytes()).hexdigest()==source_hash
 if app_library: assert [hashlib.sha256(p.read_bytes()).hexdigest() for p in library_files]==library_hashes, 'source library files must not change'
 assert app_exec.is_file() and rom.is_file()
 app_command=shlex.split(app_exec.read_text());game=library_game if app_library else 'CLV-U-A0001'
if size_128k:
 # Test-owned copy: change only the LoROM SRAM-size header, never the source.
 data=bytearray(rom.read_bytes());assert len(data)%1024==0 and data[0x7fd8]==3
 data[0x7fd8]=7;rom=root/'synthetic-128k.smc';rom.write_bytes(data)

digest=hashlib.sha256(rom.read_bytes()).hexdigest();extension=rom.suffix.lower();assert extension in ('.sfc','.smc');obj=objects/(digest+extension);shutil.copyfile(rom,obj);obj.chmod(0o600)
if app_menu_smoke:
 assert digest==source_hash, 'app candidate changed the reviewed ROM bytes'
 assert app_command==['/mnt/swifthakchi/hc-snes-superv','--game',game,'--rom','/var/lib/swifthakchi/snes-v2/objects/'+digest+extension]
# Build the native probe; the C entry runner, not this script, invokes it.
scratch=root/'probe-scratch';scratch.mkdir(mode=0o700);probe=root/'size-probe'
headers=pathlib.Path(os.environ['HC_LIBRETRO_INCLUDE'])
subprocess.run(['clang','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-I'+str(headers),str(w/'core-size-probe.c'),'-o',str(probe)],check=True)
sram_size=expected_size or 32768
binary=root/'entry';sources=['console-supervisor-main.c','stock-real-entry-driver.c','ram-menu-term.c','stock-session-signals.c','size-probe-runner.c','stock-exit-owner.c','stock-reset-input.c','stock-power-input.c','stock-power-open.c','stock-control-session.c','stock-reset-discovery.c','stock-reset-open.c','test-reset-discovery-shim.c','stock-runtime-bridge.c','stock-entry-finalize.c','stock-entry-start.c','stock-entry-failed-start.c','stock-previous-save.c','stock-gameplay.c','console-runtime.c','nonce-sequence.c','console-game.c','console-game-start.c','stock-game-session.c','stock-save-session.c','stock-screenshot-capture.c','stock-retained-image.c','stock-manager-image.c','stock-manager-state.c','stock-state-capture.c','stock-state-seed.c','stock-selected-state.c','stock-config.c','verified-launch.c','periodic-owner.c','recovery-binding.c','recovery-observer.c','session-owner.c','hc-intent-v2.c','launch-request.c']
cmd=['clang','-std=c11','-O1','-D_DARWIN_C_SOURCE','-DHC_HOST_GAME_RUNNER','-DHC_TEST_INPUT_DISCOVERY','-DHC_UNPUBLISHED_ERROR_TEST_HOOK',f'-DHC_TEST_OBJECT_DIRECTORY="{objects}"','-I'+str(w),'-I'+str(helper),'-I'+str(crypto/'include'),'-fsanitize=address,undefined','-ffunction-sections','-fdata-sections']+[str(w/s) for s in sources]+[str(helper/s) for s in (['arguments.c','isolated_saves.c','child_process.c','control_pipe.c','autosave_target.c','autosave_publish.c','owned_directory.c','checkpoint_receipt.c','control_command.c','screenshot_png.c','state_codec.c'] + ([] if manager_gameplay else ['transitions.c']))]+[str(crypto/'library'/s) for s in ['sha256.c','platform_util.c']]+['-lz','-Wl,-dead_strip','-o',str(binary)]
if retained_screenshot or retained_state: cmd.insert(1,'-DHC_STOCK_RETAINED_TEST_HOOK')
if selected_discover_bind_race: cmd.insert(1,'-DHC_STOCK_SELECTED_BIND_TEST_HOOK')
if retained_state: cmd.insert(1,'-DHC_STOCK_STATE_ARCHIVE_TEST_HOOK')
if native_interrupt: cmd.insert(1,'-DHC_STOCK_MANAGER_STATE_TEST_HOOK')
cmd.insert(-4,str(helper/'playtime.c'))
if manager_image_publish:
 cmd.insert(1,f'-DHC_STOCK_MANAGER_HOST_ROOT="{root / "manager"}"')
 cmd.insert(1,'-DHC_STOCK_MANAGER_TEST_HOOK')
if publication_crash or same_time_rename:
 cmd.insert(1,'-DHC_STOCK_PREPARE_TEST_HOOK')
 publish_object=root/'injected-publish.o'
 subprocess.run(['clang','-std=c11','-D_DARWIN_C_SOURCE','-Drenameat=hc_test_crash_rename','-fsanitize=address,undefined','-ffunction-sections','-fdata-sections','-I'+str(helper),'-c',str(helper/'autosave_publish.c'),'-o',str(publish_object)],check=True)
 cmd.remove(str(helper/'autosave_publish.c'))
 cmd.insert(-2,str(publish_object));cmd.insert(-2,str(w/'test-stock-publication-crash.c'))
if manager_gameplay: cmd.insert(-2,str(w/'test-entry-transition-shim.c'))
if postspawn_smoke: cmd.insert(1,'-DHC_TEST_POSTSPAWN_FAILURE')
subprocess.run(cmd,check=True)
pattern=bytes((n*13+97)%256 for n in range(sram_size))
seed_payload=None
prior_request_path=None
prior_profiles_path=None
def run(name,report,mode="normal",inject=True):
 runroot=root/name
 if mode not in ('repeat','finish-repeat'): runroot.mkdir(mode=0o700)
 stage=runroot/('stage-repeat' if mode in ('repeat','finish-repeat') else 'stage');stage.mkdir(mode=0o700)
 shared_profiles=native_state and mode=='autoload' and not selected_foreign_profiles
 profiles=prior_profiles_path if shared_profiles else runroot/'profiles';saved=profiles/game/'hakchi'/'snes9x2010-fe690dd3-armhf-glibc223'/digest
 if mode not in ('repeat','finish-repeat') and not shared_profiles: saved.mkdir(mode=0o700,parents=True)
 if runtime_lock_gameplay or retained_screenshot or retained_state:
  (saved.parent.parent).chmod(0o700);saved.parent.chmod(0o700)
 if mode not in ('no-battery','first-save','created-target','repeat','finish-repeat'): (saved/'battery.srm').write_bytes(pattern)
 if mode=='autoload': (saved/'battery.srm').write_bytes(bytes([(pattern[0]+30)%256])+pattern[1:])
 if mode=='conflict': (stage/'210.srm').write_bytes(b'KEEP')
 cfg=stage/'retroarch.cfg';cfg.write_text('video_driver = "null"\naudio_driver = "null"\ninput_driver = "null"\nmenu_driver = "rgui"\nconfig_save_on_exit = "false"\nsavestate_auto_save = "false"\nsavestate_auto_load = "false"\nautosave_interval = "0"\nsavefile_directory = "'+str(stage)+'"\nsavestate_directory = "'+str(stage)+'"\nsavefiles_in_content_dir = "false"\nsavestates_in_content_dir = "false"\nsort_savefiles_enable = "false"\nsort_savestates_enable = "false"\n')
 env=dict(os.environ);env.update(HC_ENTRY_ROOT=str(runroot),HC_ENTRY_FRONTEND=str(frontend),HC_ENTRY_CORE=str(core),HC_ENTRY_CONFIG=str(cfg),HC_ENTRY_FRONTEND_SHA=hashlib.sha256(frontend.read_bytes()).hexdigest(),HC_ENTRY_CORE_SHA=hashlib.sha256(core.read_bytes()).hexdigest(),HC_ENTRY_CONFIG_SHA=hashlib.sha256(cfg.read_bytes()).hexdigest(),HC_STOCK_TRIAL_ROOT=str(runroot),HC_ENTRY_PROBE=str(probe),HC_ENTRY_PROBE_SHA=hashlib.sha256(probe.read_bytes()).hexdigest())
 if shared_profiles: env['HC_ENTRY_CURRENT_PROFILES']=str(profiles)
 if postspawn_smoke: env['HC_ENTRY_TEST_POSTSPAWN']='1'
 if shared_finalize: env['HC_ENTRY_SHARED_FINALIZE']='1'
 if capture_prior: env['HC_ENTRY_CAPTURE_PRIOR']='1'
 if gameplay_owner: env['HC_ENTRY_GAMEPLAY_OWNER']='1'
 if actual_manager_request: env['HC_ENTRY_ACTUAL_MANAGER_REQUEST']='1'
 if actual_manager_tamper: env['HC_ENTRY_TAMPER_ACTUAL_MANAGER_RECORD']='1'
 if actual_manager_late_tamper: env['HC_ENTRY_TAMPER_ACTUAL_MANAGER_RECORD_LATE']='1'
 if manager_gameplay: env['HC_ENTRY_MANAGER_TRANSITIONS']='1'
 if manager_signal: env['HC_ENTRY_MANAGER_SIGNAL']='1'
 if publication_crash and inject: env['HC_ENTRY_INJECT_PUBLICATION_CRASH']=publication_crash
 if manager_screenshot:
  env['HC_ENTRY_MANAGER_SCREENSHOT']='1';env['HC_ENTRY_CREATE_CONFIG']='1'
  if retained_screenshot: env['HC_ENTRY_RETAIN_SCREENSHOT']='1'
  if retained_no_sram: env['HC_ENTRY_RETAIN_NO_SRAM']='1'
  if retained_screenshot_conflict: env['HC_ENTRY_RETAIN_CONFLICT']='1'
  if retained_save_crash: env['HC_ENTRY_CRASH_AFTER_RETAINED_SAVE']='1'
  elif retained_screenshot_crash: env['HC_ENTRY_CRASH_AFTER_SCREENSHOT_RETAINED']='1'
  if manager_state: env['HC_ENTRY_MANAGER_STATE']='1'
  if retained_state: env['HC_ENTRY_RETAIN_STATE']='1'
  if state_archive_reload or state_package_failure or state_package_no_sram or native_state: env['HC_ENTRY_PACKAGE_RETAINED_STATE']='1'
  if state_package_failure: env['HC_ENTRY_PACKAGE_OCCUPIED']='1'
  if state_archive_conflict: env['HC_ENTRY_STATE_ARCHIVE_CONFLICT']='1'
  if state_archive_tamper: env['HC_ENTRY_STATE_ARCHIVE_TAMPER']='1'
  if state_archive_crash: env['HC_ENTRY_STATE_ARCHIVE_CRASH']='1'
  if state_archive_after_tamper: env['HC_ENTRY_STATE_ARCHIVE_TAMPER_AFTER']='1'
  if state_archive_partial: env['HC_ENTRY_STATE_ARCHIVE_PARTIAL']=str(state_archive_partial)
  if manager_state_conflict: env['HC_ENTRY_STATE_CONFLICT']='1'
  if unsafe_screenshot_signal: env['HC_ENTRY_UNSAFE_SCREENSHOT_SIGPIPE']='1'
  if unbound_screenshot: env['HC_ENTRY_UNBOUND_SCREENSHOT']='1'
  (stage/'shots').mkdir(mode=0o700);cfg.unlink()
  if manager_image_publish:
   manager_parent=root/'manager'/game/'suspendpoint0';manager_parent.mkdir(parents=True,mode=0o700)
   env['HC_ENTRY_TEST_MANAGER_IMAGE']='1';env['HC_ENTRY_MANAGER_IMAGE_PARENT']=str(manager_parent)
   if native_state:
    state_parent=manager_parent/'rollback';state_parent.mkdir(mode=0o700)
    env['HC_ENTRY_NATIVE_STATE_PARENT']=str(state_parent)
    if native_symlink: (state_parent/'savestate').symlink_to('other')
    elif native_occupied: (state_parent/'savestate').write_bytes(b'KEEP')
    if native_late_conflict: env['HC_ENTRY_NATIVE_STATE_CONFLICT_LATE']='1'
    if native_tamper: env['HC_ENTRY_NATIVE_STATE_TAMPER']='1'
    if native_interrupt: env['HC_ENTRY_NATIVE_STATE_INTERRUPT']=str(native_interrupt)
   if ordered_image: env['HC_ENTRY_ORDERED_MANAGER_IMAGE']='1'
   if ordered_time: env['HC_ENTRY_ORDERED_MANAGER_TIME']='1'
   if resumed_time:
    env['HC_ENTRY_RESUMED_TIME']='1'
    source=manager_parent/('state.time' if resume_same else 'state.load.time')
    if resume_invalid=='symlink': (manager_parent/'source').write_bytes(b'43');source.symlink_to('source')
    elif resume_invalid!='missing': source.write_bytes(b'bad' if resume_invalid=='malformed' else resume_original)
   if resume_same: env['HC_ENTRY_RESUME_SAME_TARGET']='1'
   if same_time_rename: env['HC_ENTRY_INJECT_TIME_RENAME']=same_time_rename
   if resume_tamper: env['HC_ENTRY_RESUME_TAMPER']='1'
   if resume_swap: env['HC_ENTRY_RESUME_SWAP']='1'
   if resume_early: env['HC_ENTRY_RESUME_EARLY_TAMPER']='1'
   if resume_target_conflict: env['HC_ENTRY_RESUME_TARGET_CONFLICT']='1'
   if seed_backup_conflict: env['HC_ENTRY_SEED_BACKUP_CONFLICT']='1'
   if seed_backup_early: env['HC_ENTRY_SEED_BACKUP_EARLY_TAMPER']='1'
   if seed_backup_late: env['HC_ENTRY_SEED_BACKUP_LATE_TAMPER']='1'
   if seed_backup_interrupt: env['HC_ENTRY_MANAGER_IMAGE_INTERRUPT']='6'
   if ordered_time_conflict: env['HC_ENTRY_ORDERED_TIME_CONFLICT']='1'
   if manager_time_journals: env['HC_ENTRY_TEST_TIME_JOURNAL']='1'
   if manager_time_publish: env['HC_ENTRY_TEST_TIME_PUBLISH']='1'
   if manager_time_interrupt: env['HC_ENTRY_MANAGER_IMAGE_INTERRUPT']=str(manager_time_interrupt)
   if ordered_image_conflict: env['HC_ENTRY_ORDERED_IMAGE_CONFLICT']='1'
   if manager_image_interruption: env['HC_ENTRY_MANAGER_IMAGE_INTERRUPT']=str(manager_image_interruption)
 if mode=='autoload':
  assert seed_payload is not None
  if manager_missing_seed: env['HC_ENTRY_MISSING_AUTO']='1'
  elif native_state:
   selected_parent=root/'manager'/game/'suspendpoint1'/'rollback'
   if selected_discover_parent_symlink:
    real=selected_parent.parent/'real-rollback';real.mkdir(mode=0o700,parents=True);selected_parent.symlink_to('real-rollback')
   else: selected_parent.mkdir(mode=0o700,parents=True)
   if selected_discover_parent_writable: selected_parent.chmod(0o777)
   selected=selected_parent/'savestate'
   if selected_symlink:
    source=selected_parent/'other';source.write_bytes(seed_payload);source.chmod(0o600);selected.symlink_to('other')
   else: selected.write_bytes(gzip.compress(b'unrelated compatibility state') if selected_foreign or selected_discover_foreign else seed_payload);selected.chmod(0o600)
   env['HC_ENTRY_SELECTED_STATE_PARENT']=str(selected_parent)
   if selected_discover: env['HC_ENTRY_SELECTED_DISCOVER']='1'
   else: env['HC_ENTRY_PRIOR_STATE_FRAME']=str(prior_request_path)
   env['HC_ENTRY_PRIOR_STATE_PROFILES']=str(prior_profiles_path)
   if selected_wrong_prior: env['HC_ENTRY_SELECTED_WRONG_PRIOR']='1'
   if selected_before_start: env['HC_ENTRY_SELECTED_TAMPER_BEFORE']='1'
   if selected_discover_bind_race: env['HC_ENTRY_SELECTED_BIND_RACE']='1'
   if selected_during_wait: env['HC_ENTRY_SELECTED_TAMPER_DURING_WAIT']='1'
  else:
   seed=runroot/'fixture-state.gz';seed.write_bytes(seed_payload);env['HC_ENTRY_STATE_SEED']=str(seed)
   if manager_tamper_seed: env['HC_ENTRY_TAMPER_AUTO']='1'
 if manager_signal_wait: env['HC_ENTRY_MANAGER_SIGNAL_DURING_WAIT']='1'
 elif manager_signal_early: env['HC_ENTRY_MANAGER_SIGNAL_EARLY']='1'
 if runtime_lock_gameplay:
  env['HC_ENTRY_RUNTIME_LOCK']='1'
  env['HC_ENTRY_CREATE_CONFIG']='1'
  cfg.unlink()
 if stale_gameplay: env['HC_ENTRY_TEST_STALE_ARGS']='1'
 if sys.argv[1:]==['--power-gameplay-owner']: env['HC_ENTRY_POWER']='1'
 if shared_no_sram: env['HC_ENTRY_SHARED_NO_SRAM']='1'
 if orphan_lock_smoke: env['HC_ENTRY_TEST_ORPHAN_LOCK']='1'
 if replay_smoke: env['HC_ENTRY_TEST_REPLAY']='1'
 if bound_smoke:
  reviewed=runroot/'reviewed-request';session=os.urandom(16)
  assert any(session)
  requested_digest = '0'*64 if mode == 'bound-wrong' else digest
  reviewed.write_bytes(b'HCLREQ1\0'+b'CLV-U-ABCDE'+requested_digest.encode('ascii')+session+struct.pack('<Q',0x1234))
  env['HC_ENTRY_REQUEST_INPUT']=str(reviewed)
 if app_library:
  reviewed=runroot/'reviewed-request';frame=bytearray(app_request.read_bytes())
  if mode=='bound-wrong': frame[19:83]=b'0'*64
  if mode=='bound-wrong-game': frame[8:19]=b'CLV-U-ABCDE'
  if mode=='bound-empty-session': frame[83:99]=bytes(16)
  reviewed.write_bytes(frame);env['HC_ENTRY_REQUEST_INPUT']=str(reviewed)
 if mode in ('repeat','finish-repeat'): env['HC_ENTRY_STAGE']='stage-repeat'
 if changed_save_smoke and mode=='finish-repeat': env['HC_ENTRY_PREVIOUS_FIRST_INCREMENTED']='1'
 if mode in ('finish','finish-repeat','wrong-current','wrong-previous','wrong-absence','first-save','late-cleanup-loss','late-power-after-publish'): env['HC_ENTRY_FINISH_SAVE']='1'
 if name in ('finish-cleanup','captured-first-save','late-cleanup-loss','late-power-after-publish'): env['HC_ENTRY_CAPTURED_FINISH']='1'
 if mode=='late-cleanup-loss': env['HC_ENTRY_LATE_CLEANUP_LOSS']='1'
 if mode=='late-power': env['HC_ENTRY_LATE_POWER']='1'
 if mode=='late-power-after-publish': env['HC_ENTRY_LATE_POWER']='1';env['HC_ENTRY_LATE_POWER_AFTER_PUBLISH']='1'
 if name in ('finish-cleanup','no-sram-finish-cleanup','shared-first-save','shared-no-sram-no-prior'): env['HC_ENTRY_CLEAN_FINISHED']='1'
 if mode=='first-save': env['HC_ENTRY_FIRST_SAVE']='1'
 if mode=='changed-target': env['HC_ENTRY_CHANGE_TARGET']='1'
 if mode=='reset-disconnect': env['HC_ENTRY_DISCONNECT_RESET']='1'
 if mode=='late-input-loss': env['HC_ENTRY_LATE_RESET_LOSS']='1'
 if mode=='late-nosram-loss': env['HC_ENTRY_LATE_RESET_LOSS']='1'
 if mode=='power': env['HC_ENTRY_POWER']='1'
 if mode=='power-disconnect': env['HC_ENTRY_DISCONNECT_POWER']='1'
 if mode=='created-target': env['HC_ENTRY_CREATE_TARGET']='1'
 if mode=='wrong-current': env['HC_ENTRY_WRONG_CURRENT']='1'
 if mode=='wrong-previous': env['HC_ENTRY_WRONG_PREVIOUS']='1'
 if mode=='wrong-absence': env['HC_ENTRY_WRONG_ABSENCE']='1'
 if mode=='no-sram-wrong-absence': env['HC_ENTRY_NO_SRAM_WRONG_ABSENCE']='1'
 if mode=='tamper-stage': env['HC_ENTRY_TAMPER_STAGE']='1'
 if mode=='wrong-initial': env['HC_ENTRY_WRONG_INITIAL']='1'
 if mode=='alias-snapshot': env['HC_ENTRY_ALIAS_SNAPSHOT']='1'
 if mode=='retry-snapshot': env['HC_ENTRY_RETRY_SNAPSHOT']='1'
 if mode.startswith('retry-partial-'): env['HC_ENTRY_RETRY_PARTIAL']=mode[-1]
 if mode in ('no-battery','first-save','created-target'): env['HC_ENTRY_INITIAL_SAVE']='absent'
 else: env['HC_ENTRY_INITIAL_SAVE']='present'
 if report:env['HC_STOCK_SAVE_REPORT']='1'
 else:env.pop('HC_STOCK_SAVE_REPORT',None)
 entry=app_command[1:] if app_menu_smoke else ['--game',game,'--rom','/var/lib/swifthakchi/snes-v2/objects/'+digest+extension]
 args=[str(binary)]+entry+['--title-code',game,'--wait-transition-fd','28','--start-transition-fd','31','--finish-transition-fd','33','--save-data-backing-file','/var/lib/clover/profiles/0/'+game+'/cartridge.sram']
 if mode=='app-tamper': args[4]=args[4].replace(digest,'0'*64)
 if bound_smoke or (unsupported_gameplay and not observed_stock_menu): args+=['--rollback-output-dir','/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/rollback','--save-screenshot-on-quit','/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/state.png']
 if observed_stock_menu: args+=['--save-screenshot-on-quit','/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/state.png','--save-time-path','/var/cache/clover/volatile/CLV-U-ABCDE/suspendpoint0/state.time']
 if actual_manager_request: args+=['--save-screenshot-on-quit','/var/cache/clover/volatile/'+game+'/suspendpoint0/state.png','--save-time-path','/var/cache/clover/volatile/'+game+'/suspendpoint0/state.time']
 if native_state: args+=['--rollback-output-dir','/var/cache/clover/volatile/'+game+'/suspendpoint0/rollback']
 if native_state and mode=='autoload': args+=['--rollback-input-dir','/var/cache/clover/volatile/'+game+'/suspendpoint1/rollback']
 if native_mode_unsupported: args+=['--rollback-mode','record']
 if actual_manager_resume: args+=['--load-time-path','/var/cache/clover/volatile/'+game+'/suspendpoint0/'+('state.time' if resume_same else 'state.load.time')]
 if mode=='wronggame': args[2]='CLV-U-ABCDF'
 log=runroot/('entry-repeat.log' if mode in ('repeat','finish-repeat') else 'entry.log')
 with log.open('wb') as f:
  proc=subprocess.run(args,env=env,stdout=f,stderr=subprocess.STDOUT,timeout=20)
 return proc.returncode,log.read_text(errors='replace'),saved,stage
status,log,saved,stage=run('normal',True)
if native_interrupt:
 assert status==120+native_interrupt and 'HC-MANAGER-FINISH' not in log
 assert (saved/'battery.srm').read_bytes()==pattern
 archive=list((saved/'sessions').glob('checkpoint-*/state-archive/state-captured'))
 assert len(archive)==1 and archive[0].read_bytes()==(stage/'210.state').read_bytes()
 folder=root/'manager'/game/'suspendpoint0'/'rollback'
 assert (folder/'state-manager-binding').exists()
 assert len(list(folder.glob('intent2-*')))==(0 if native_interrupt==1 else 1)
 assert (folder/'savestate').exists()==(native_interrupt==3)
 if native_interrupt==3: assert gzip.decompress((folder/'savestate').read_bytes())==archive[0].read_bytes()
 records=list((saved/'sessions').glob('checkpoint-*/manager.meta'));assert len(records)==1
 request=records[0].read_bytes()[8:115];reader=root/'interrupted-state-reader'
 subprocess.run(['clang','-std=c11','-D_DARWIN_C_SOURCE','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-ffunction-sections','-fdata-sections','-I'+str(w),'-I'+str(helper),*[str(w/x) for x in ['test-stock-state-archive-reader.c','recovery-observer.c','recovery-binding.c','session-owner.c','hc-intent-v2.c','launch-request.c']],str(helper/'playtime.c'),str(helper/'screenshot_png.c'),'-lz','-Wl,-dead_strip','-o',str(reader)],check=True)
 observed=subprocess.run([str(reader),str(saved.parent.parent.parent.parent),str(root/'recovered-state')],input=request,capture_output=True)
 assert observed.returncode==0 and (root/'recovered-state').read_bytes()==archive[0].read_bytes()
 print('An interrupted state publication retained its archive and previous save without menu completion.')
 shutil.rmtree(root);sys.exit(0)
if native_mode_unsupported:
 assert status==3 and 'prepare game session' in log and 'HC-MANAGER-WAIT' not in log
 assert (saved/'battery.srm').read_bytes()==pattern and not (stage/'210.srm').exists()
 assert not (root/'manager'/game/'suspendpoint0'/'rollback'/'savestate').exists()
 print('Unsupported rollback-record mode stopped before launch.')
 shutil.rmtree(root);sys.exit(0)
if native_occupied:
 assert status==3 and 'HC-MANAGER-WAIT' not in log and 'HC-MANAGER-FINISH' not in log
 target=root/'manager'/game/'suspendpoint0'/'rollback'/'savestate'
 assert target.is_symlink() and os.readlink(target)=='other' if native_symlink else target.read_bytes()==b'KEEP'
 assert (saved/'battery.srm').read_bytes()==pattern and not (stage/'210.srm').exists()
 print('An occupied state target was preserved and stopped the game before launch.')
 shutil.rmtree(root);sys.exit(0)
if native_late_conflict or native_tamper:
 assert status==8 and 'HC-MANAGER-FINISH' not in log
 archives=list((saved/'sessions').glob('checkpoint-*/state-archive/state-captured'))
 assert len(archives)==1 and archives[0].read_bytes()==(stage/'210.state').read_bytes()
 if native_late_conflict:
  assert (root/'manager'/game/'suspendpoint0'/'rollback'/'savestate').read_bytes()==b'KEEP'
  assert (saved/'battery.srm').read_bytes()==pattern
 else:
  assert 'HC-STATE-PUBLISHED' in log and (saved/'battery.srm').read_bytes()==bytes([(pattern[0]+1)%256])+pattern[1:]
 print('A conflicting or altered state stopped menu completion and retained the captured state.')
 shutil.rmtree(root);sys.exit(0)
if state_package_failure:
 assert status==8 and 'HC-MANAGER-FINISH' not in log
 assert (saved/'battery.srm').read_bytes()==pattern, 'package failure must preserve the previous game save'
 archives=list((saved/'sessions').glob('checkpoint-*/state-archive/state-captured'))
 assert len(archives)==1 and archives[0].read_bytes()==(stage/'210.state').read_bytes(), 'captured state must remain recoverable'
 assert not (root/'manager'/game/'suspendpoint0'/'state.png').exists()
 print('A refused state package preserved the archive and previous save and withheld menu completion.')
 shutil.rmtree(root);sys.exit(0)
if state_archive_after_tamper:
 assert status==8 and 'HC-MANAGER-FINISH' not in log
 assert (saved/'battery.srm').read_bytes()==pattern, 'changed archived state must stop before battery publication'
 assert not (root/'manager'/game/'suspendpoint0'/'state.png').exists()
 print('A changed retained state stopped the session before save or menu publication.')
 shutil.rmtree(root);sys.exit(0)
if state_archive_conflict or state_archive_tamper or state_archive_crash or state_archive_partial:
 assert status==(104 if state_archive_crash else 104+state_archive_partial if state_archive_partial else 8) and 'HC-MANAGER-FINISH' not in log
 assert (saved/'battery.srm').read_bytes()==pattern, 'failed or interrupted state retention must preserve the prior game save'
 archives=list((saved/'sessions').glob('checkpoint-*/state-archive'))
 if state_archive_conflict: assert len(archives)==1 and (archives[0]/'KEEP').read_bytes()==b'keep' and not (archives[0]/'state-captured').exists()
 elif state_archive_tamper: assert not archives, 'changed capture must be refused before creating recovery files'
 elif state_archive_partial:
  assert len(archives)==1 and not (archives[0]/'state-captured').exists()
  assert (archives[0]/'state-binding').exists()==(state_archive_partial>=2)
  assert len(list(archives[0].glob('intent2-*')))==(1 if state_archive_partial>=3 else 0)
  records=list((saved/'sessions').glob('checkpoint-*/manager.meta'));assert len(records)==1
  request=records[0].read_bytes()[8:115];reader=root/'partial-state-reader'
  subprocess.run(['clang','-std=c11','-D_DARWIN_C_SOURCE','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-ffunction-sections','-fdata-sections','-I'+str(w),'-I'+str(helper),*[str(w/x) for x in ['test-stock-state-archive-reader.c','recovery-observer.c','recovery-binding.c','session-owner.c','hc-intent-v2.c','launch-request.c']],str(helper/'playtime.c'),str(helper/'screenshot_png.c'),'-lz','-Wl,-dead_strip','-o',str(reader)],check=True)
  refused=subprocess.run([str(reader),str(saved.parent.parent.parent.parent),str(root/'incomplete-state')],input=request,capture_output=True)
  assert refused.returncode!=0 and not (root/'incomplete-state').exists(), 'an incomplete archive must not be returned as a complete state'
 else:
  assert len(archives)==1 and (archives[0]/'state-captured').read_bytes()==(stage/'210.state').read_bytes()
  assert (archives[0]/'state-binding').is_file() and len(list(archives[0].glob('intent2-*')))==1
  records=list((saved/'sessions').glob('checkpoint-*/manager.meta'));assert len(records)==1
  request=records[0].read_bytes()[8:115];reader=root/'state-archive-reader'
  subprocess.run(['clang','-std=c11','-D_DARWIN_C_SOURCE','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-ffunction-sections','-fdata-sections','-I'+str(w),'-I'+str(helper),*[str(w/x) for x in ['test-stock-state-archive-reader.c','recovery-observer.c','recovery-binding.c','session-owner.c','hc-intent-v2.c','launch-request.c']],str(helper/'playtime.c'),str(helper/'screenshot_png.c'),'-lz','-Wl,-dead_strip','-o',str(reader)],check=True)
  wrong=bytearray(request);wrong[83]^=1
  refused=subprocess.run([str(reader),str(saved.parent.parent.parent.parent),str(root/'wrong-state')],input=wrong,capture_output=True)
  assert refused.returncode!=0 and not (root/'wrong-state').exists()
  observed=subprocess.run([str(reader),str(saved.parent.parent.parent.parent),str(root/'recovered-state')],input=request,capture_output=True)
  assert observed.returncode==0 and (root/'recovered-state').read_bytes()==(stage/'210.state').read_bytes()
  observer=root/'state-archive-observer';profiles=saved.parent.parent.parent.parent
  subprocess.run(['clang','-std=c11','-D_DARWIN_C_SOURCE','-DHC_ENABLE_RECOVERY_OBSERVER','-DHC_ENABLE_STATE_ARCHIVE',f'-DHC_TEST_PROFILES_DIRECTORY="{profiles}"','-Wall','-Wextra','-Werror','-Wno-unused-parameter','-fsanitize=address,undefined','-ffunction-sections','-fdata-sections','-I'+str(w),'-I'+str(helper),'-I'+str(crypto/'include'),*[str(w/x) for x in ['console-supervisor-main.c','console-game.c','verified-launch.c','launch-request.c','recovery-clock-wire.c','recovery-observer.c','recovery-binding.c','session-owner.c','hc-intent-v2.c']],*[str(helper/x) for x in ['arguments.c','playtime.c','screenshot_png.c']],*[str(crypto/'library'/x) for x in ['sha256.c','platform_util.c']],'-lz','-Wl,-dead_strip','-o',str(observer)],check=True)
  reply=subprocess.run([str(observer),'--observe-state-archive'],input=request,capture_output=True)
  assert reply.returncode==0 and reply.stdout.startswith(b'HC-STATE-ARCHIVE-1\n') and reply.stdout.endswith((stage/'210.state').read_bytes()+b'HC-STATE-ARCHIVE-END\n')
  refused=subprocess.run([str(observer),'--observe-state-archive'],input=wrong,capture_output=True)
  assert refused.returncode!=0 and not refused.stdout
  if state_archive_wire:
   # This fixture remaps only the private host profiles prefix to the console
   # profiles root; all other bytes come from the actual C observer response.
   prefix=b'HC-STATE-ARCHIVE-1\n';line_end=reply.stdout.index(b'\n',len(prefix));fields=reply.stdout[len(prefix):line_end].split(b' ')
   assert len(fields)==5;size=int(fields[2]);start=line_end+1;descriptor=reply.stdout[start:start+size]
   host_prefix=str(profiles).encode();assert descriptor.count(host_prefix)==1
   descriptor=descriptor.replace(host_prefix,b'/var/lib/clover/profiles/0');fields[2]=str(len(descriptor)).encode()
   wire=prefix+b' '.join(fields)+b'\n'+descriptor+reply.stdout[start+size:]
   fixture=root/'wire-fixture';fixture.mkdir();rom_dir=fixture/game;rom_dir.mkdir();shutil.copyfile(rom,rom_dir/'fixture.sfc')
   (fixture/'manager.meta').write_bytes(records[0].read_bytes());(fixture/'expected-state').write_bytes((stage/'210.state').read_bytes());(fixture/'reply').write_bytes(wire)
   swift_env=dict(os.environ,HC_STATE_ARCHIVE_WIRE_FIXTURE=str(fixture),CLANG_MODULE_CACHE_PATH='/private/tmp/hc-clang-cache',SWIFTPM_MODULECACHE_OVERRIDE='/private/tmp/hc-swift-cache')
   tested=subprocess.run(['swift','test','--package-path',str(repo),'--disable-sandbox','--filter','SNESCompatibilityBackupEvidenceTests/archivedStateRequiresMatchingSessionAndIndependentDigest'],env=swift_env,text=True,stdout=subprocess.PIPE,check=True)
   assert 'Test run with 1 test' in tested.stdout and 'failed' not in tested.stdout
  archived=archives[0]/'state-captured';moved=archives[0]/'state-fixture';archived.rename(moved);archived.symlink_to(moved.name)
  refused=subprocess.run([str(reader),str(saved.parent.parent.parent.parent),str(root/'linked-state')],input=request,capture_output=True)
  assert refused.returncode!=0 and not (root/'linked-state').exists()
  archived.unlink();moved.rename(archived)
 print('A conflict, changed capture or interrupted session preserved its prior save and withheld menu completion.')
 shutil.rmtree(root);sys.exit(0)
if actual_manager_tamper:
 assert status==4 and 'HC-MANAGER-WAIT' not in log and 'HC-MANAGER-FINISH' not in log
 assert (saved/'battery.srm').read_bytes()==pattern and not (stage/'210.srm').exists()
 assert not (root/'manager'/game/'suspendpoint0'/'state.png').exists()
 print('A changed real launch record was rejected before manager handoff or save seeding.')
 shutil.rmtree(root);sys.exit(0)
if actual_manager_late_tamper:
 assert status==8 and 'HC-MANAGER-FINISH' not in log and 'MANAGER SESSION REQUIRES RECOVERY' in log
 assert (saved/'battery.srm').read_bytes()==pattern
 assert not (root/'manager'/game/'suspendpoint0'/'state.png').exists()
 print('A changed launch record after gameplay prevented save and menu publication.')
 shutil.rmtree(root);sys.exit(0)
if retained_screenshot:
 if manager_image_publish:
  if seed_backup_interrupt:
   assert status==101 and 'HC-MANAGER-WAIT' not in log and not (stage/'210.srm').exists() and (saved/'battery.srm').read_bytes()==pattern
   persistent=list((saved/'sessions').glob('checkpoint-*/time-original'));assert len(persistent)==1 and persistent[0].read_bytes()==resume_original
   records=list((saved/'sessions').glob('checkpoint-*/manager.meta'));assert len(records)==1
   request=records[0].read_bytes()[8:115];assert len(request)==107
   seed_reader=root/'time-seed-reader'
   subprocess.run(['clang','-std=c11','-D_DARWIN_C_SOURCE','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-ffunction-sections','-fdata-sections','-I'+str(w),'-I'+str(helper),*[str(w/x) for x in ['test-stock-time-seed-reader.c','recovery-observer.c','recovery-binding.c','session-owner.c','hc-intent-v2.c','launch-request.c']],str(helper/'playtime.c'),str(helper/'screenshot_png.c'),'-lz','-Wl,-dead_strip','-o',str(seed_reader)],check=True)
   (root/'manager').rename(root/'manager-offline')
   collected=subprocess.run([str(seed_reader),str(saved.parent.parent.parent.parent),str(root/'collected-time')],input=request,capture_output=True)
   assert collected.returncode==0 and (root/'collected-time').read_bytes()==resume_original
   profiles=saved.parent.parent.parent.parent;supervisor=root/'time-observer'
   subprocess.run(['clang','-std=c11','-D_DARWIN_C_SOURCE','-DHC_ENABLE_RECOVERY_OBSERVER','-DHC_ENABLE_RETAINED_TIME',f'-DHC_TEST_PROFILES_DIRECTORY="{profiles}"','-Wall','-Wextra','-Werror','-Wno-unused-parameter','-fsanitize=address,undefined','-ffunction-sections','-fdata-sections','-I'+str(w),'-I'+str(helper),'-I'+str(crypto/'include'),*[str(w/x) for x in ['console-supervisor-main.c','console-game.c','verified-launch.c','launch-request.c','recovery-clock-wire.c','recovery-observer.c','recovery-binding.c','session-owner.c','hc-intent-v2.c']],*[str(helper/x) for x in ['arguments.c','playtime.c','screenshot_png.c']],*[str(crypto/'library'/x) for x in ['sha256.c','platform_util.c']],'-lz','-Wl,-dead_strip','-o',str(supervisor)],check=True)
   observation=subprocess.run([str(supervisor),'--observe-retained-time'],input=request,capture_output=True)
   assert observation.returncode==0 and observation.stdout.startswith(b'HC-RETAINED-TIME-1\n') and observation.stdout.endswith(resume_original+b'HC-RETAINED-TIME-END\n')
   wrong_request=bytearray(request);wrong_request[83]^=1
   refused=subprocess.run([str(supervisor),'--observe-retained-time'],input=wrong_request,capture_output=True)
   assert refused.returncode!=0 and not refused.stdout, 'another session must not receive a time observation'
   print('The prior time remained readable after an interrupted prelaunch session without the menu directory.')
   shutil.rmtree(root);sys.exit(0)
  if seed_backup_conflict or seed_backup_early or seed_backup_late:
   backups=list((saved/'sessions').glob('checkpoint-*/time-original'))
   assert len(backups)==1 and backups[0].read_bytes()==(b'KEEP' if seed_backup_conflict else b'99')
   assert status==(3 if seed_backup_conflict else 4 if seed_backup_early else 8) and 'HC-MANAGER-FINISH' not in log
   assert (saved/'battery.srm').read_bytes()==pattern
   if not seed_backup_late: assert 'HC-MANAGER-WAIT' not in log and not (stage/'210.srm').exists()
   else: assert not (root/'manager'/game/'suspendpoint0'/'state.png').exists()
   print('A conflicting or changed retained time backup stopped the session without changing the game save.')
   shutil.rmtree(root);sys.exit(0)
  if same_time_rename:
   assert status==(101 if same_time_rename=='before' else 102) and 'HC-MANAGER-FINISH' not in log
   published=root/'manager'/game/'suspendpoint0'/'state.png';retained=list(saved.glob('shot-*.png'));timer=published.parent/'state.time'
   assert len(retained)==1 and published.read_bytes()==retained[0].read_bytes() and (saved/'battery.srm').read_bytes()==bytes([(pattern[0]+1)%256])+pattern[1:]
   previous=list(published.parent.glob('checkpoint-*/previous'));assert len(previous)==1 and previous[0].read_bytes()==resume_original
   if same_time_rename=='before': assert timer.read_bytes()==resume_original
   else: assert timer.read_bytes().isdigit() and int(timer.read_bytes())>=43
   assert len(list(published.parent.glob('intent2-*')))==2
   records=list((saved/'sessions').glob('checkpoint-*/manager.meta'));assert len(records)==1
   request=records[0].read_bytes()[8:115];assert len(request)==107
   backup=root/'independent-time-backup';backup.write_bytes(resume_original)
   wrong=root/'wrong-time-backup';wrong.write_bytes(b'99')
   recovery=root/'time-recovery'
   subprocess.run(['clang','-std=c11','-D_DARWIN_C_SOURCE','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-ffunction-sections','-fdata-sections','-I'+str(w),'-I'+str(helper),*[str(w/x) for x in ['test-stock-time-recovery.c','recovery-binding.c','session-owner.c','hc-intent-v2.c','launch-request.c']],'-Wl,-dead_strip','-o',str(recovery)],check=True)
   before=timer.read_bytes()
   rejected=subprocess.run([str(recovery),str(saved),str(published.parent),str(wrong)],input=request,capture_output=True)
   assert rejected.returncode!=0 and timer.read_bytes()==before, 'an incorrect independent time backup must not change the target'
   restored=subprocess.run([str(recovery),str(saved),str(published.parent),str(backup)],input=request,capture_output=True)
   assert restored.returncode==0 and timer.read_bytes()==resume_original, f'prior time was not restored: {restored.stderr.decode(errors="replace")}'
   retry=subprocess.run([str(recovery),str(saved),str(published.parent),str(backup)],input=request,capture_output=True)
   assert retry.returncode==0 and timer.read_bytes()==resume_original and published.read_bytes()==retained[0].read_bytes(), 'time restoration must be retryable and preserve the screenshot'
   persistent=list((saved/'sessions').glob('checkpoint-*/time-original'));assert len(persistent)==1 and persistent[0].read_bytes()==resume_original
   seed_reader=root/'time-seed-reader'
   subprocess.run(['clang','-std=c11','-D_DARWIN_C_SOURCE','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-ffunction-sections','-fdata-sections','-I'+str(w),'-I'+str(helper),*[str(w/x) for x in ['test-stock-time-seed-reader.c','recovery-observer.c','recovery-binding.c','session-owner.c','hc-intent-v2.c','launch-request.c']],str(helper/'playtime.c'),str(helper/'screenshot_png.c'),'-lz','-Wl,-dead_strip','-o',str(seed_reader)],check=True)
   (root/'manager').rename(root/'manager-offline')
   wrong_request=bytearray(request);wrong_request[83]^=1
   rejected=subprocess.run([str(seed_reader),str(saved.parent.parent.parent.parent),str(root/'wrong-seed')],input=wrong_request,capture_output=True)
   assert rejected.returncode!=0 and not (root/'wrong-seed').exists(), 'another session must not collect this time seed'
   collected=subprocess.run([str(seed_reader),str(saved.parent.parent.parent.parent),str(root/'collected-time')],input=request,capture_output=True)
   assert collected.returncode==0 and (root/'collected-time').read_bytes()==resume_original, f'persisted seed was not readable without the menu directory: {collected.stderr.decode(errors="replace")}'
   persistent[0].write_bytes(b'bad')
   refused=subprocess.run([str(seed_reader),str(saved.parent.parent.parent.parent),str(root/'bad-seed')],input=request,capture_output=True)
   assert refused.returncode!=0 and not (root/'bad-seed').exists(), 'malformed retained time must not be returned'
   persistent[0].write_bytes(resume_original);moved=persistent[0].with_name('time-original.fixture');persistent[0].rename(moved);persistent[0].symlink_to(moved.name)
   refused=subprocess.run([str(seed_reader),str(saved.parent.parent.parent.parent),str(root/'linked-seed')],input=request,capture_output=True)
   assert refused.returncode!=0 and not (root/'linked-seed').exists(), 'a linked retained time must not be returned'
   persistent[0].unlink();moved.rename(persistent[0])
   print('A fresh host process restored the prior time from an independent backup after interrupted publication.')
   shutil.rmtree(root);sys.exit(0)
  if resume_early:
   assert status==4 and 'HC-MANAGER-WAIT' not in log and 'ROM: "' not in log
   assert (saved/'battery.srm').read_bytes()==pattern and not (stage/'210.srm').exists(), 'changed prior time must stop before manager handoff and save seeding'
   print('Changed prior time was refused again immediately before game launch.')
   shutil.rmtree(root);sys.exit(0)
  if resume_invalid:
   assert status==3 and 'HC-MANAGER-WAIT' not in log and 'ROM: "' not in log
   assert (saved/'battery.srm').read_bytes()==pattern and not (stage/'210.srm').exists(), 'invalid resumed time must be refused before save seeding'
   print('Invalid, missing, linked or same-target resume time was refused before game launch.')
   shutil.rmtree(root);sys.exit(0)
  if manager_time_interrupt:
   assert status==95+manager_time_interrupt, f'time interruption not reached (status {status}; log {root}/normal/entry.log)'
   retained=list(saved.glob('shot-*.png'));published=root/'manager'/game/'suspendpoint0'/'state.png';timer=published.parent/'state.time'
   assert len(retained)==1 and published.read_bytes()==retained[0].read_bytes()
   assert (saved/'battery.srm').read_bytes()==bytes([(pattern[0]+1)%256])+pattern[1:]
   assert len(list(published.parent.glob('intent2-*')))==2 and timer.exists()==(manager_time_interrupt==5)
   if timer.exists():
    value=timer.read_bytes();assert (value.isdigit() and (43 if resumed_time else 0)<=int(value)<(343 if resumed_time else 300)) if ordered_time else value==b'43'
   if resumed_time: assert (published.parent/'state.load.time').read_bytes()==b'43'
   if ordered_time: assert 'HC-MANAGER-FINISH' not in log, 'interrupted time output must not signal menu completion'
   records=list((saved/'sessions').glob('checkpoint-*/manager.meta'));assert len(records)==1
   request=records[0].read_bytes()[8:115];assert len(request)==107
   recover=root/'retained-reader'
   subprocess.run(['clang','-std=c11','-D_DARWIN_C_SOURCE','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-ffunction-sections','-fdata-sections','-I'+str(w),'-I'+str(helper),*[str(w/x) for x in ['test-stock-retained-recovery.c','recovery-observer.c','recovery-binding.c','recovery-clock-wire.c','session-owner.c','hc-intent-v2.c','launch-request.c']],str(helper/'screenshot_png.c'),str(helper/'owned_directory.c'),'-lz','-Wl,-dead_strip','-o',str(recover)],check=True)
   observed=subprocess.run([str(recover),str(saved.parent.parent.parent.parent),str(root/'recovered.png')],input=request,capture_output=True)
   assert observed.returncode==0 and (root/'recovered.png').read_bytes()==retained[0].read_bytes(), 'retained image must remain recoverable after a time-output interruption'
   print('A simulated time-output interruption preserved the screenshot and game save.')
   shutil.rmtree(root);sys.exit(0)
  if ordered_image and not manager_image_interruption:
   if resume_target_conflict:
    published=root/'manager'/game/'suspendpoint0'/'state.png';retained=list(saved.glob('shot-*.png'))
    assert status==8 and (published.parent/'state.time').read_bytes()==b'KEEP' and (published.parent/'state.load.time').read_bytes()==b'43'
    assert len(retained)==1 and published.read_bytes()==retained[0].read_bytes() and 'HC-MANAGER-FINISH' not in log
    assert (saved/'battery.srm').read_bytes()==bytes([(pattern[0]+1)%256])+pattern[1:]
    print('An occupied resumed-time target was preserved and prevented menu completion.')
    shutil.rmtree(root);sys.exit(0)
   if resume_tamper or resume_swap:
    published=root/'manager'/game/'suspendpoint0'/'state.png'
    source=published.parent/('state.time' if resume_same else 'state.load.time')
    assert status==8 and source.read_bytes()==(b'99' if resume_tamper else b'43') and not published.exists()
    assert (saved/'battery.srm').read_bytes()==pattern and 'HC-MANAGER-FINISH' not in log, 'a changed resume value must stop before save or menu publication'
    print('A changed resume-time file stopped publication and preserved the original game save.')
    shutil.rmtree(root);sys.exit(0)
   retained=list(saved.glob('shot-*.png'));published=root/'manager'/game/'suspendpoint0'/'state.png'
   assert len(retained)==1 and retained[0].read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
   expected_save=pattern if manager_no_sram else bytes([(pattern[0]+1)%256])+pattern[1:]
   pending_images=1 if ordered_time_conflict or ordered_image_conflict else 0
   assert (saved/'battery.srm').read_bytes()==expected_save and len(list(saved.glob('intent2-*')))==pending_images
   if ordered_time_conflict:
    assert status==8 and published.read_bytes()==retained[0].read_bytes() and (published.parent/'state.time').read_bytes()==b'KEEP'
    assert 'HC-IMAGE-PUBLISHED' in log and 'HC-TIME-PUBLISHED' not in log and 'HC-MANAGER-FINISH' not in log, f'occupied time must stop completion (status {status}; log {root}/normal/entry.log)'
    print('Occupied play-time output stopped completion and preserved the screenshot and finalized save.')
   elif ordered_image_conflict:
    assert status==8 and published.read_bytes()==b'KEEP' and 'HC-IMAGE-PUBLISHED' not in log and 'HC-MANAGER-FINISH' not in log, f'occupied screenshot must stop the menu handoff (status {status}; log {root}/normal/entry.log)'
    print('Occupied menu image stopped completion and preserved the retained screenshot and finalized save.')
   else:
    assert status==0 and 'ORDERED MANAGER SCREENSHOT PUBLISHED IN HOST FIXTURE' in log, f'ordered publication failed (status {status}; log {root}/normal/entry.log)'
    assert published.read_bytes()==retained[0].read_bytes() and len(list(published.parent.glob('intent2-*')))==(2 if ordered_time else 1)
    assert 'HC-IMAGE-PUBLISHED' in log and 'HC-MANAGER-FINISH' in log and log.index('HC-IMAGE-PUBLISHED')<log.index('HC-MANAGER-FINISH'), 'the image must be published before the manager completion signal'
    if actual_manager_state:
     archive=list((saved/'sessions').glob('checkpoint-*/state-archive/state-captured'))
     assert len(archive)==1 and archive[0].read_bytes()==(stage/'210.state').read_bytes()
     assert log.index('SESSION STATE RETAINED BEFORE MANAGER COMPLETION')<log.index('HC-IMAGE-PUBLISHED')
     if native_state:
      published_state=root/'manager'/game/'suspendpoint0'/'rollback'/'savestate'
      assert gzip.decompress(published_state.read_bytes())==archive[0].read_bytes()
      assert log.index('HC-STATE-PUBLISHED')<log.index('HC-IMAGE-PUBLISHED')<log.index('HC-MANAGER-FINISH')
     if state_package_no_sram:
      assert gzip.decompress((stage/'210.state.pack').read_bytes())==archive[0].read_bytes()
      assert log.index('SESSION ARCHIVE PACKAGED')<log.index('HC-IMAGE-PUBLISHED')
    if ordered_time:
     time_bytes=(published.parent/'state.time').read_bytes()
     assert time_bytes.isdigit() and int(time_bytes)<300 and 'HC-TIME-PUBLISHED' in log
     clock=re.search(r'HC-CLOCK-START (\d+) (\d+) END (\d+) (\d+)',log);assert clock, 'the owner must report both monotonic instants in this host fixture'
     start_s,start_ns,end_s,end_ns=map(int,clock.groups());elapsed=(end_s-start_s)-(end_ns<start_ns)
     assert elapsed>=0 and int(time_bytes)==elapsed+(43 if resumed_time else 0), 'published time must match the prior value plus owner-measured whole seconds'
     if resumed_time:
      session_backups=list((saved/'sessions').glob('checkpoint-*/time-original'));assert len(session_backups)==1 and session_backups[0].read_bytes()==resume_original
      if resume_same:
       previous=list(published.parent.glob('checkpoint-*/previous'));assert len(previous)==1 and previous[0].read_bytes()==resume_original
      else: assert (published.parent/'state.load.time').read_bytes()==resume_original
      assert 'RESUME TIME CAPTURED BEFORE FRONTEND START' in log and log.index('RESUME TIME CAPTURED BEFORE FRONTEND START')<log.index('HC-MANAGER-WAIT')
      assert 'RESUME TIME RETAINED IN SESSION BEFORE START' in log and log.index('RESUME TIME RETAINED IN SESSION BEFORE START')<log.index('HC-MANAGER-WAIT')
     assert log.index('HC-IMAGE-PUBLISHED')<log.index('HC-TIME-PUBLISHED')<log.index('HC-MANAGER-FINISH')
    if native_state and not native_no_sram and not native_resume:
     seed_payload=published_state.read_bytes()
     records=list((saved/'sessions').glob('checkpoint-*/manager.meta'));assert len(records)==1
     prior_request_path=records[0];prior_profiles_path=saved.parent.parent.parent.parent
     if selected_discover_many:
      # These records exercise inventory size only; they are not completed gameplay sessions.
      for number in range(1,19):
       token=number.to_bytes(16,'big');folder=records[0].parent.parent/('checkpoint-'+token.hex())
       folder.mkdir(mode=0o700)
       meta=bytearray(records[0].read_bytes());meta[91:107]=token
       (folder/'manager.meta').write_bytes(meta);(folder/'manager.meta').chmod(0o600)
     if selected_discover_incomplete:
      (records[0].parent.parent/'checkpoint-ffffffffffffffffffffffffffffffff').mkdir(mode=0o700)
     if selected_discover_ambiguous or selected_discover_corrupt or selected_discover_multiple:
      original=records[0].parent;old=original.name[11:];new='ffffffffffffffffffffffffffffffff';duplicate=original.parent/('checkpoint-'+new)
      shutil.copytree(original,duplicate)
      meta=bytearray((duplicate/'manager.meta').read_bytes());meta[91:107]=bytes.fromhex(new);(duplicate/'manager.meta').write_bytes(meta)
      copied=duplicate/'state-archive';binding=copied/'state-binding'
      if selected_discover_corrupt: binding.write_bytes(b'not a valid binding')
      else:
       data=binding.read_text().replace(old,new);lines=data.splitlines();st=copied.stat();parts=lines[6].split(' ',3);parts[1]=str(st.st_dev);parts[2]=str(st.st_ino);lines[6]=' '.join(parts);binding.write_text('\n'.join(lines)+'\n')
       for intent in copied.glob('intent2-*'):
        fields=intent.read_text().splitlines();fields[1]=new;prefix=('\n'.join(fields[:-1])+'\n').encode();h=14695981039346656037
        for byte in prefix:h=((h^byte)*1099511628211)&((1<<64)-1)
        intent.write_bytes(prefix+f'{h:016x}\n'.encode())
       if selected_discover_multiple:
        captured=copied/'state-captured';captured.write_bytes(captured.read_bytes()+b'not the selected state')
     (root/'manager').rename(root/'manager-first')
     again,again_log,reloaded,staged=run('autoload',True,'autoload')
     if selected_foreign or selected_discover_foreign or selected_discover_incomplete or selected_discover_ambiguous or selected_discover_corrupt or selected_discover_bind_race or selected_discover_parent_symlink or selected_discover_parent_writable or selected_wrong_prior or selected_symlink or selected_foreign_profiles or selected_before_start or selected_during_wait:
      assert again==(4 if selected_before_start or selected_during_wait else 6) and 'HC-MANAGER-FINISH' not in again_log
      assert ('HC-MANAGER-WAIT' in again_log)==bool(selected_during_wait)
      assert (reloaded/'battery.srm').read_bytes()==bytes([(pattern[0]+30)%256])+pattern[1:]
      assert not (staged/'210.srm').exists()
      if selected_foreign or selected_discover_foreign or selected_discover_incomplete or selected_discover_ambiguous or selected_discover_corrupt or selected_discover_parent_symlink or selected_discover_parent_writable or selected_wrong_prior or selected_symlink or selected_foreign_profiles: assert not (staged/'210.state.auto').exists()
      if selected_discover_ambiguous: assert 'identify prior session: File exists' in again_log
      if selected_discover_bind_race: assert 'STAGED STATE RETAINED FOR RECOVERY' in again_log and (staged/'210.state.auto').exists()
      print('Untrusted or changed selected state was refused before the game started.')
      shutil.rmtree(root);sys.exit(0)
     assert again==0 and 'SESSION AUTOLOAD STATE SEEDED' in again_log and 'HC_TEST_STATE_LOAD OK' in again_log
     if selected_discover: assert 'PRIOR SESSION DISCOVERED BY STATE' in again_log
     assert 'SESSION MANAGER-SELECTED STATE VERIFIED' in again_log
     assert (staged/'210.state.auto').read_bytes()==gzip.decompress(seed_payload)
     result=(reloaded/'battery.srm').read_bytes()
     assert result[0]==(pattern[0]+1)%256 and result[1:]==pattern[1:]
     print('A fresh host session loaded the state published to the simulated menu.')
    print('The real host emulator screenshot was published before the simulated menu completion.')
   shutil.rmtree(root);sys.exit(0)
  if manager_image_interruption:
   assert status==95+manager_image_interruption, f'manager interruption not reached (status {status}; log {root}/normal/entry.log)'
   retained=list(saved.glob('shot-*.png'));published=root/'manager'/game/'suspendpoint0'/'state.png'
   assert len(retained)==1 and retained[0].read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
   assert (saved/'battery.srm').read_bytes()==bytes([(pattern[0]+1)%256])+pattern[1:]
   assert len(list(saved.glob('shot-manager-*')))==1 and len(list(saved.glob('intent2-*')))==1
   assert len(list(published.parent.glob('intent2-*')))==(0 if manager_image_interruption==1 else 1)
   assert published.exists()==(manager_image_interruption==3)
   if ordered_image: assert 'HC-MANAGER-FINISH' not in log, 'interrupted publication must not signal menu completion'
   if published.exists(): assert published.read_bytes()==retained[0].read_bytes()
   records=list((saved/'sessions').glob('checkpoint-*/manager.meta'));assert len(records)==1
   request=records[0].read_bytes()[8:115];assert len(request)==107
   recover=root/'retained-reader'
   subprocess.run(['clang','-std=c11','-D_DARWIN_C_SOURCE','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-ffunction-sections','-fdata-sections','-I'+str(w),'-I'+str(helper),*[str(w/x) for x in ['test-stock-retained-recovery.c','recovery-observer.c','recovery-binding.c','recovery-clock-wire.c','session-owner.c','hc-intent-v2.c','launch-request.c']],str(helper/'screenshot_png.c'),str(helper/'owned_directory.c'),'-lz','-Wl,-dead_strip','-o',str(recover)],check=True)
   observed=subprocess.run([str(recover),str(saved.parent.parent.parent.parent),str(root/'recovered.png')],input=request,capture_output=True)
   assert observed.returncode==0 and (root/'recovered.png').read_bytes()==retained[0].read_bytes(), f'retained image was not readable after manager interruption: {observed.stderr.decode(errors="replace")}'
   print(f'After simulated manager-image interruption {manager_image_interruption}, a fresh reader recovered the retained PNG and SRAM remained intact.')
   shutil.rmtree(root);sys.exit(0)
  assert status==0 and 'MANAGER SCREENSHOT PUBLISHED IN HOST FIXTURE' in log, f'manager image publication failed (status {status}; log {root}/normal/entry.log)'
  retained=list(saved.glob('shot-*.png'));published=root/'manager'/game/'suspendpoint0'/'state.png'
  assert len(retained)==1 and published.read_bytes()==retained[0].read_bytes() and published.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
  expected_save=pattern if manager_no_sram else bytes([(pattern[0]+1)%256])+pattern[1:]
  assert (saved/'battery.srm').read_bytes()==expected_save and len(list(saved.glob('intent2-*')))==1
  assert len(list(published.parent.glob('intent2-*')))==(2 if manager_time_journals or manager_time_publish else 1), 'all expected manager journals must remain pending'
  if manager_time_journals: assert 'TIME AND IMAGE JOURNALS RECOGNIZED TOGETHER' in log
  if manager_time_publish:
   assert 'VERIFIED PLAY-TIME PUBLISHED IN HOST FIXTURE' in log and (published.parent/'state.time').read_bytes()==b'43'
  print('The verified host screenshot was published to the simulated menu path while its recovery copy remained intact.')
  shutil.rmtree(root);sys.exit(0)
 if retained_no_sram and not retained_screenshot_crash:
  assert status==0 and 'SESSION SCREENSHOT RETAINED' in log and 'ENTRY NO SRAM CLEAN' in log, f'no-SRAM screenshot session failed (status {status}; log {root}/normal/entry.log)'
  images=list(saved.glob('shot-*.png'));assert len(images)==1 and images[0].read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
  assert (saved/'battery.srm').read_bytes()==pattern and len(list(saved.glob('intent2-*')))==1, 'the existing save must stay unchanged while the image remains recoverable'
  absent_status,absent_log,absent_saved,_=run('no-prior-save',True,'no-battery')
  assert absent_status==0 and 'SESSION SCREENSHOT RETAINED' in absent_log and not (absent_saved/'battery.srm').exists(), 'a no-SRAM game must not create a battery save when none existed'
  assert len(list(absent_saved.glob('intent2-*')))==1 and len(list(absent_saved.glob('shot-*.png')))==1
  print('A real host emulator without SRAM retained a PNG and preserved the existing save.')
  shutil.rmtree(root);sys.exit(0)
 if retained_screenshot_conflict:
  images=list(saved.glob('shot-*.png'))
  assert status==8 and len(images)==1 and images[0].read_bytes()==b'KEEP', 'an existing retained image must be preserved'
  assert (saved/'battery.srm').read_bytes()==pattern and len(list(saved.glob('intent2-*')))==1, 'a screenshot conflict must leave the original save and recovery record intact'
  assert 'HC-MANAGER-FINISH' not in log, 'a failed image handoff must not signal completion'
  print('An existing image blocked the retained-image handoff without changing the prior save.')
  shutil.rmtree(root);sys.exit(0)
 if retained_screenshot_crash:
  expected=bytes([(pattern[0]+1)%256])+pattern[1:] if retained_save_crash else pattern
  assert status==(95 if retained_save_crash else 94) and (saved/'battery.srm').read_bytes()==expected, 'the interrupted session must leave the expected save state'
  assert len(list(saved.glob('intent2-*')))==2 and len(list(saved.glob('shot-*.png')))==1
  records=list((saved/'sessions').glob('checkpoint-*/manager.meta'));assert len(records)==1
  request=records[0].read_bytes()[8:115];assert len(request)==107
  recover=root/'retained-reader'
  subprocess.run(['clang','-std=c11','-D_DARWIN_C_SOURCE','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-ffunction-sections','-fdata-sections','-I'+str(w),'-I'+str(helper),*[str(w/x) for x in ['test-stock-retained-recovery.c','recovery-observer.c','recovery-binding.c','recovery-clock-wire.c','session-owner.c','hc-intent-v2.c','launch-request.c']],str(helper/'screenshot_png.c'),str(helper/'owned_directory.c'),'-lz','-Wl,-dead_strip','-o',str(recover)],check=True)
  if retained_save_crash:
   backup=root/'independent-backup.srm';backup.write_bytes(pattern)
   wrong=root/'wrong-backup.srm';wrong.write_bytes(bytes([pattern[0]^1])+pattern[1:])
   binding=next(saved.glob('shot-retained-*'));original_binding=binding.read_bytes();binding.write_bytes(b'X'+original_binding[1:])
   rejected=subprocess.run([str(recover),str(saved.parent.parent.parent.parent),str(root/'bad-binding.png'),str(backup)],input=request,capture_output=True)
   assert rejected.returncode!=0 and (saved/'battery.srm').read_bytes()==expected, 'a damaged combined binding must not fall back to another record'
   binding.write_bytes(original_binding)
   rejected=subprocess.run([str(recover),str(saved.parent.parent.parent.parent),str(root/'wrong-backup.png'),str(wrong)],input=request,capture_output=True)
   assert rejected.returncode!=0 and (saved/'battery.srm').read_bytes()==expected, 'a wrong independent backup must not change SRAM'
   stale_env=dict(os.environ,HC_FIXTURE_STALE_CURRENT='1')
   rejected=subprocess.run([str(recover),str(saved.parent.parent.parent.parent),str(root/'stale-current.png'),str(backup)],input=request,capture_output=True,env=stale_env)
   assert rejected.returncode!=0 and (saved/'battery.srm').read_bytes()==expected, 'stale current-save evidence must not change SRAM'
  observed=subprocess.run([str(recover),str(saved.parent.parent.parent.parent),str(root/'recovered.png')]+([str(backup)] if retained_save_crash else []),input=request,capture_output=True)
  assert observed.returncode==0, f'retained image was not readable after interruption: {observed.stderr.decode(errors="replace")}'
  assert (root/'recovered.png').read_bytes()==next(saved.glob('shot-*.png')).read_bytes()
  if retained_save_crash:
   retry=subprocess.run([str(recover),str(saved.parent.parent.parent.parent),str(root/'recovered-again.png'),str(backup)],input=request,capture_output=True)
   assert retry.returncode==0 and (root/'recovered-again.png').read_bytes()==(root/'recovered.png').read_bytes(), 'recovery must be safely retryable'
  wrong_request=bytearray(request);wrong_request[83]^=1
  refused=subprocess.run([str(recover),str(saved.parent.parent.parent.parent),str(root/'wrong.png')],input=wrong_request,capture_output=True)
  assert refused.returncode!=0 and not (root/'wrong.png').exists(), 'another session must not read the retained image'
  image=next(saved.glob('shot-*.png'));original=image.read_bytes();image.write_bytes(bytes([original[0]^1])+original[1:])
  refused=subprocess.run([str(recover),str(saved.parent.parent.parent.parent),str(root/'corrupt.png')],input=request,capture_output=True)
  assert refused.returncode!=0 and not (root/'corrupt.png').exists(), 'a damaged retained PNG must be refused'
  image.write_bytes(original)
  assert (saved/'battery.srm').read_bytes()==pattern and len(list(saved.glob('intent2-*')))==2
  print('After a simulated process interruption, a fresh reader recovered the retained PNG and '+('restored SRAM from an independent backup.' if retained_save_crash else 'the old SRAM remained intact.'))
  shutil.rmtree(root);sys.exit(0)
 assert status==0 and 'SESSION SCREENSHOT RETAINED' in log and 'SHARED SAVE FINALIZATION VERIFIED' in log, f'retained screenshot session failed (status {status}; log {root}/normal/entry.log)'
 images=list(saved.glob('shot-*.png'));assert len(images)==1 and images[0].read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
 assert len(list(saved.glob('intent2-*')))==1, 'the image recovery record must remain for later publication'
 assert (saved/'battery.srm').read_bytes()[0]==(pattern[0]+1)%256
 print('Real host emulator captured a PNG, retained it for recovery, and finalized the same game save.')
 shutil.rmtree(root);sys.exit(0)
if publication_crash:
 expected_status={'before':91,'after':92,'prepare':93}[publication_crash]
 assert status==expected_status and (publication_crash=='prepare' or 'MANAGER SIGNAL RESET DISPATCHED' in log), f'game session did not reach the selected interruption (status {status}; log {root}/normal/entry.log)'
 current=(saved/'battery.srm').read_bytes()
 expected_current=pattern if publication_crash in ('before','prepare') else bytes([(pattern[0]+1)%256])+pattern[1:]
 assert current==expected_current, 'the current save must reflect the interruption point'
 if publication_crash=='prepare':
  assert not list(saved.glob('intent2-*')) and 'ROM: "' not in log, 'setup interruption must happen before the save intent or frontend launch'
 else:
  assert len(list(saved.glob('intent2-*')))==1 and len(list(saved.glob('checkpoint-*/previous')))==1, 'recovery evidence must remain after interruption'
 bindings=list(saved.glob('bind-*'));assert len(bindings)==1
 records=list((saved/'sessions').glob('checkpoint-*/manager.meta'))
 assert len(records)==1 and records[0].read_bytes()[:8]==b'HCSESS1\0', 'a battery-only interrupted session must be discoverable without a screenshot request'
 library=root/'fixture-library'/game;library.mkdir(mode=0o700,parents=True)
 library_rom=library/'game.sfc';shutil.copyfile(rom,library_rom)
 swift_env=dict(os.environ,HC_REAL_STOCK_BINDING=str(bindings[0]),HC_REAL_STOCK_META=str(records[0]),HC_REAL_STOCK_ROM=str(library_rom),HC_REAL_STOCK_GAME=game,CLANG_MODULE_CACHE_PATH='/private/tmp/hc-clang-cache',SWIFTPM_MODULECACHE_OVERRIDE='/private/tmp/hc-swift-cache')
 swift_check=['swift','test','--package-path',str(repo),'--disable-sandbox']
 if os.environ.get('HC_SWIFT_SCRATCH'): swift_check+=['--scratch-path',os.environ['HC_SWIFT_SCRATCH']]
 checked=subprocess.run(swift_check+['--filter','SNESCompatibilityBackupEvidenceTests/observesActualStockSessionBindingFixture'],env=swift_env,check=True,stdout=subprocess.PIPE,text=True)
 assert 'observesActualStockSessionBindingFixture' in checked.stdout and 'Test run with 1 test' in checked.stdout and 'failed' not in checked.stdout, 'the app must validate the actual interrupted game session binding'
 if publication_crash=='prepare':
  existing_sessions={p.name for p in (saved/'sessions').glob('checkpoint-*')}
  retry_status,retry_log,retry_saved,retry_stage=run('normal',True,'repeat',inject=False)
  assert retry_status!=0 and 'ROM: "' not in retry_log and not (retry_stage/'210.srm').exists(), 'an interrupted session without a save intent must block another launch'
  assert (retry_saved/'battery.srm').read_bytes()==pattern, 'the refused retry must preserve the existing save'
  assert {p.name for p in (retry_saved/'sessions').glob('checkpoint-*')}==existing_sessions, 'the refused retry must not create another session'
  print('Interrupted setup preserved the existing save and blocked a second launch before recovery.')
  shutil.rmtree(root);sys.exit(0)
 backup=root/'independent-before.srm';backup.write_bytes(pattern)
 recover=root/'recover-fixture'
 recover_sources=['test-stock-publication-recover.c','console-game-start.c','recovery-clock-wire.c','recovery-observer.c','recovery-binding.c','session-owner.c','hc-intent-v2.c','launch-request.c']
 subprocess.run(['clang','-std=c11','-D_DARWIN_C_SOURCE','-Wall','-Wextra','-Werror','-fsanitize=address,undefined','-ffunction-sections','-fdata-sections','-I'+str(w),'-I'+str(helper),*[str(w/s) for s in recover_sources],str(helper/'autosave_verify.c'),str(helper/'owned_directory.c'),'-Wl,-dead_strip','-o',str(recover)],check=True)
 wrong_backup=root/'wrong-before.srm';wrong_backup.write_bytes(bytes([pattern[0]^1])+pattern[1:])
 refused=subprocess.run([str(recover),str(saved),game,digest,str(wrong_backup)],capture_output=True)
 assert refused.returncode!=0, 'recovery must reject a backup that does not match the retained previous save'
 assert (saved/'battery.srm').read_bytes()==expected_current and len(list(saved.glob('intent2-*')))==1, 'rejected recovery must preserve the current save and recovery evidence'
 stale_env=dict(os.environ,HC_FIXTURE_STALE_CURRENT='1')
 refused=subprocess.run([str(recover),str(saved),game,digest,str(backup)],env=stale_env,capture_output=True)
 assert refused.returncode!=0 and (saved/'battery.srm').read_bytes()==expected_current, 'recovery must reject stale current-save evidence before writing'
 subprocess.run([str(recover),str(saved),game,digest,str(backup)],check=True)
 assert (saved/'battery.srm').read_bytes()==pattern, 'recovery must restore the independently retained previous bytes'
 assert len(list(saved.glob('intent2-*')))==1, 'recovery must retain evidence for later review'
 subprocess.run([str(recover),str(saved),game,digest,str(backup)],check=True)
 assert (saved/'battery.srm').read_bytes()==pattern and len(list(saved.glob('intent2-*')))==1, 'retrying recovery must leave the restored save and evidence intact'
 existing_sessions={p.name for p in (saved/'sessions').glob('checkpoint-*')}
 retry_status,retry_log,retry_saved,retry_stage=run('normal',True,'repeat',inject=False)
 assert retry_status!=0 and 'ROM: "' not in retry_log and not (retry_stage/'210.srm').exists(), 'unresolved recovery must prevent another game launch'
 assert (retry_saved/'battery.srm').read_bytes()==pattern and len(list(retry_saved.glob('intent2-*')))==1, 'refused launch must preserve the restored save and recovery evidence'
 assert {p.name for p in (retry_saved/'sessions').glob('checkpoint-*')}==existing_sessions, 'a refused launch must not create another abandoned session workspace'
 print('A second game launch was refused while the recovery record remained unresolved.')
 print('A real host game-session save was interrupted '+publication_crash+' publication and its independently retained previous save was restored.')
 shutil.rmtree(root);sys.exit(0)
if manager_state_conflict:
 assert status!=0 and 'MANAGER SIGNAL RESET DISPATCHED' in log, f'conflicting state should quarantine the session (status {status}; log {root}/normal/entry.log)'
 assert (saved/'battery.srm').read_bytes()==pattern, 'state failure must preserve the prior battery save'
 assert 'SESSION SCREENSHOT VERIFIED' not in log and not list((stage/'shots').glob('*.png')), 'a failed state must not produce a screenshot'
 assert (stage/'210.state').read_bytes()==b'conflict', 'the conflicting file must be preserved'
 print('Conflicting state quarantined the session before screenshot or save publication; prior save preserved.')
 shutil.rmtree(root);sys.exit(0)
if unsafe_screenshot_signal or unbound_screenshot:
 assert status!=0 and 'HC-MANAGER-WAIT' not in log and 'ROM: "' not in log, f'incomplete screenshot setup must be rejected before manager handoff or frontend launch (status {status}; log {root}/normal/entry.log)'
 assert (saved/'battery.srm').read_bytes()==pattern and not (stage/'210.srm').exists(), 'incomplete screenshot setup must preserve prior SRAM and avoid staging a save'
 print('Incomplete screenshot setup rejected before handoff, staging, or emulator startup.')
 shutil.rmtree(root);sys.exit(0)
if manager_signal_early:
 marker='HC-MANAGER-WAIT-SIGNAL' if manager_signal_wait else 'EARLY MANAGER RESET OBSERVED'
 assert status==4 and marker in log and 'ROM: "' not in log, f'early manager RESET must stop before frontend launch (status {status}; log {root}/normal/entry.log)'
 assert (saved/'battery.srm').read_bytes()==pattern and not (stage/'210.srm').exists(), 'early RESET must preserve prior SRAM and avoid seeding the frontend'
 print('Early manager RESET stopped the host launch before SRAM staging or emulator start; prior save preserved.')
 shutil.rmtree(root);sys.exit(0)
if runtime_lock_gameplay:
 assert 'RUNTIME LOCK SHARED' in log, f'the runtime lock must reach the game session (status {status}; log {root}/normal/entry.log)'
if manager_gameplay and not orphan_lock_smoke:
 assert all(marker in log for marker in ('HC-MANAGER-WAIT','HC-MANAGER-START','HC-MANAGER-FINISH')), f'the real frontend must run with the simulated manager handoff (status {status}; log {root}/normal/entry.log)'
 assert log.index('HC-MANAGER-WAIT') < log.index('HC-MANAGER-START') < log.index('HC-MANAGER-FINISH')
if manager_signal:
 assert 'MANAGER RESET WITHOUT PHYSICAL INPUT' in log and 'MANAGER SIGNAL RESET DISPATCHED' in log and status==0, f'manager signal must drive the real frontend save handoff (status {status}; log {root}/normal/entry.log)'
if manager_screenshot:
 assert 'SESSION SCREENSHOT VERIFIED' in log, f'reviewed game session must capture its screenshot (status {status}; log {root}/normal/entry.log)'
 if manager_state: assert 'SESSION STATE CAPTURED BEFORE SCREENSHOT' in log, f'state capture must finish first (status {status}; log {root}/normal/entry.log)'
 if manager_state:
  marker=next(x for x in log.splitlines() if x.startswith('SESSION STATE CAPTURED BEFORE SCREENSHOT '))
  reported_hash,reported_length=marker.rsplit(' ',2)[1:]
  state=(stage/'210.state').read_bytes()
  assert len(state)==int(reported_length) and hashlib.sha256(state).hexdigest()==reported_hash, 'retained session bytes must match the generated state file'
  if retained_state:
   candidates=list((saved/'sessions').glob('checkpoint-*/state-archive/state-captured'))
   assert len(candidates)==1 and candidates[0].read_bytes()==state, 'captured state must be retained with the same game session'
  assert gzip.decompress((stage/'210.state.gz').read_bytes())==state, 'compressed state must reproduce the captured game state'
  assert not (stage/'210.state.auto').exists(), 'a fresh session must not write an unsupervised automatic state on exit'
if retained_state:
 assert status==0 and 'SESSION STATE RETAINED BEFORE MANAGER COMPLETION' in log
 assert log.index('SESSION STATE RETAINED BEFORE MANAGER COMPLETION')<log.index('HC-MANAGER-FINISH')
 assert (saved/'battery.srm').read_bytes()==bytes([(pattern[0]+1)%256])+pattern[1:]
 if state_archive_reload:
  seed_payload=(stage/'210.state.pack').read_bytes()
  assert gzip.decompress(seed_payload)==candidates[0].read_bytes(), 'the verified archive must produce the reloadable package'
  assert 'SESSION ARCHIVE PACKAGED' in log and log.index('SESSION ARCHIVE PACKAGED')<log.index('HC-MANAGER-FINISH')
  status,log,reloaded,staged=run('autoload',True,'autoload')
  assert status==0 and 'SESSION AUTOLOAD STATE SEEDED' in log and 'HC_TEST_STATE_LOAD OK' in log
  assert (staged/'210.state.auto').read_bytes()==gzip.decompress(seed_payload)
  result=(reloaded/'battery.srm').read_bytes()
  assert result[0]==(pattern[0]+1)%256 and result[1:]==pattern[1:], 'reload must restore the earlier state instead of newer fixture SRAM'
  print('A fresh host emulator restored the retained session state.')
 print('The captured state was retained in the game session before simulated menu completion.')
 shutil.rmtree(root);sys.exit(0)
if manager_autoload:
 seed_payload=(stage/'210.state.gz').read_bytes()
 if manager_bad_seed:
  corrupted=bytearray(seed_payload);corrupted[-8]^=1;seed_payload=bytes(corrupted)
 status,log,reloaded,staged=run('autoload',True,'autoload')
 if manager_bad_seed:
  expected=bytes([(pattern[0]+30)%256])+pattern[1:]
  assert status==6 and 'SESSION AUTOLOAD STATE SEEDED' not in log and 'HC-MANAGER-WAIT' not in log
  assert (reloaded/'battery.srm').read_bytes()==expected and not (staged/'210.srm').exists() and not (staged/'210.state.auto').exists()
  print('Corrupt compressed state refused before menu handoff or SRAM staging; prior save preserved.')
  shutil.rmtree(root);sys.exit(0)
 if manager_missing_seed or manager_tamper_seed:
  expected=bytes([(pattern[0]+30)%256])+pattern[1:]
  assert status==4 and 'HC-MANAGER-WAIT' not in log, f'bad autoload must be refused before the menu handoff (status {status}; log {root}/autoload/entry.log)'
  assert (reloaded/'battery.srm').read_bytes()==expected and not (staged/'210.srm').exists(), 'bad autoload must preserve the prior battery save'
  print('Missing or changed autoload state refused before menu handoff and SRAM staging; prior save preserved.')
  shutil.rmtree(root);sys.exit(0)
 assert status==0 and 'SESSION AUTOLOAD STATE SEEDED' in log and 'HC_TEST_STATE_LOAD OK' in log, f'fresh emulator did not autoload the staged state (status {status}; log {root}/autoload/entry.log)'
 assert (staged/'210.state.auto').read_bytes()==gzip.decompress(seed_payload), 'exit must not overwrite the staged restore state'
 result=(reloaded/'battery.srm').read_bytes()
 assert result[0]==(pattern[0]+1)%256 and result[1:]==pattern[1:], 'autoload must restore the earlier game state instead of the deliberately different starting SRAM'
 print('The next real host session automatically loaded the privately staged gzip state and restored the earlier game memory.')
 shutil.rmtree(root);sys.exit(0)
if unsupported_gameplay or stale_gameplay:
 assert status==3 and 'prepare game session' in log and 'ROM: "' not in log, f'unsupported manager request must stop before gameplay (status {status}; log {root}/normal/entry.log)'
 assert (saved/'battery.srm').read_bytes()==pattern, 'the existing save must remain unchanged'
 assert not list(saved.glob('intent2-*')) and not list(saved.glob('bind-*')) and not list(saved.glob('checkpoint-*')), 'the refusal must precede save journal and binding creation'
 assert not (stage/'210.srm').exists(), 'the refusal must precede save staging'
 assert not (saved/'sessions').exists(), 'stale or unsupported requests must be rejected before temporary workspace creation'
 print('Unsupported or stale game request refused before save journal, binding, staging or game launch; the prior save is unchanged.')
 shutil.rmtree(root);sys.exit(0)
if postspawn_smoke:
 assert status==4 and 'FAILED START CHILD REAPED' in log and (saved/'battery.srm').read_bytes()==pattern and list(saved.glob('intent2-*')), f'failed start must reap frontend and retain save and recovery (status {status}; log {root}/normal/entry.log)'
 if gameplay_owner: assert 'GAMEPLAY OWNER ABORTED' in log, 'unified owner must handle startup failure'
 if runtime_lock_gameplay: assert 'RUNTIME LOCK RETAINED THROUGH REAP' in log, 'save lock must remain held through failed-start cleanup'
 print('Post-spawn failure reaped the real frontend and retained the prior save and recovery.')
 shutil.rmtree(root);sys.exit(0)
if replay_smoke:
 status,log,saved,stage=run('finish',True,'finish')
 assert status==0 and 'REPLAYED SESSION REFUSED' in log, 'a completed runtime must not create a second save session with the same session identifier'
 print('Completed runtime rejected a second save session.')
 sys.exit(0)
if orphan_lock_smoke:
 assert status==0 and 'FRONTEND HELD LOCK UNTIL EXIT' in log and (saved/'battery.srm').read_bytes()==pattern, f'frontend lock handoff failed (status {status}; log {root}/normal/entry.log)'
 print('The real Mac frontend retained the save lock after its supervisor closed its copy; recovery stayed blocked until the frontend exited.')
 shutil.rmtree(root);sys.exit(0)
if app_menu_smoke and not app_homebrew_save:
 marker='ENTRY REAL FRONTEND SAVE VERIFIED' if app_menu_save else 'ENTRY NO SRAM CLEAN'
 assert status==0 and 'ROM: "' in log and marker in log and (saved/'battery.srm').read_bytes()==pattern, f'app-generated menu did not reach the real frontend (status {status}; log {root}/normal/entry.log)'
 if app_menu_save:
  assert (stage/'210.srm').read_bytes()==pattern and list(saved.glob('intent2-*')), 'real frontend save must match the fixture and retain recovery intent'
  status,log,finished,stage=run('finish-cleanup',True,'finish')
  assert status==0 and marker in log and (finished/'battery.srm').read_bytes()==pattern and not list(finished.glob('intent2-*')), 'checked save finalization must preserve the verified fixture save'
 status,log,saved,stage=run('app-tamper',True,'app-tamper')
 assert status==2 and 'ROM: "' not in log and (saved/'battery.srm').read_bytes()==pattern, 'changed app menu ROM digest must be refused before frontend launch'
 if app_library:
  for mode in ('bound-wrong','bound-wrong-game','bound-empty-session'):
   status,log,saved,stage=run('app-request-'+mode,True,mode)
   assert status!=0 and 'ROM: "' not in log and (saved/'battery.srm').read_bytes()==pattern, f'{mode} must be refused before frontend launch'
 print('App-generated menu command and reviewed ROM copy reached the real frontend; a changed digest was refused before launch and the fixture saves were preserved.')
 sys.exit(0)
if late_input_smoke:
 status,log,saved,stage=run('late-input-loss',True,'late-input-loss')
 assert status==8 and 'LATE INPUT LOSS ACCEPTED' not in log and (saved/'battery.srm').read_bytes()==pattern and list(saved.glob('intent2-*')), 'lost RESET input after frontend exit must preserve the prior save and recovery intent'
 print('Late RESET input loss refused publication and preserved prior save.')
 sys.exit(0)
if late_cleanup_smoke:
 status,log,saved,stage=run('late-cleanup-loss',True,'late-cleanup-loss')
 assert status==8 and 'LATE CLEANUP LOSS ACCEPTED' not in log and list(saved.glob('intent2-*')) and list(saved.glob('checkpoint-*/previous')), 'lost RESET input after publication must retain recovery intent and prior save'
 print('Late RESET input loss retained the previous save and recovery intent.')
 sys.exit(0)
if late_power_smoke:
 status,log,saved,stage=run('late-power',True,'late-power')
 assert status==0 and 'LATE POWER OBSERVED' in log and 'ENTRY REAL FRONTEND SAVE VERIFIED' in log, 'late power event must override RESET before the save handoff'
 print('Late power event observed after real frontend exit in the Mac fixture.')
 sys.exit(0)
if late_power_after_publish:
 status,log,saved,stage=run('late-power-after-publish',True,'late-power-after-publish')
 assert status==0 and 'POWER AFTER PUBLICATION OBSERVED' in log and not list(saved.glob('intent2-*')), 'power after publication must be observed before recovery finalization'
 print('Power after publication observed before recovery finalization in the Mac fixture.')
 sys.exit(0)
if late_no_sram_smoke:
 status,log,saved,stage=run('late-nosram-loss',True,'late-nosram-loss')
 assert status==8 and (saved/'battery.srm').read_bytes()==pattern and list(saved.glob('intent2-*')), 'lost RESET input must prevent no-SRAM session finalization'
 print('Late RESET input loss retained the no-SRAM recovery intent.')
 sys.exit(0)
if finish_smoke:
 status,log,saved,stage=run('finish-cleanup',True,'finish')
 assert status==0 and 'ENTRY REAL FRONTEND SAVE VERIFIED' in log and not list((saved/'sessions').glob('checkpoint-*')) and (saved/'battery.srm').read_bytes()==pattern
 status,log,saved,stage=run('captured-first-save',True,'first-save')
 assert status==0 and 'ENTRY REAL FRONTEND SAVE VERIFIED' in log and (saved/'battery.srm').read_bytes()==(stage/'210.srm').read_bytes() and not list(saved.glob('intent2-*'))
 print('Captured published bytes finalized existing and first saves; no-checkpoint cleanup passed.')
 sys.exit(0)
if changed_save_smoke:
 if app_homebrew_save: assert app_command is not None, 'homebrew test must use the app-generated menu command'
 status,log,saved,stage=run('finish-cleanup',True,'finish')
 result=(saved/'battery.srm').read_bytes()
 if manager_signal: assert 'MANAGER SIGNAL RESET DISPATCHED' in log, 'the save-producing session must end through the manager signal'
 if manager_screenshot: assert 'SESSION SCREENSHOT VERIFIED' in log, 'the saved session must capture a screenshot'
 if shared_finalize: assert 'SHARED SAVE FINALIZATION VERIFIED' in log, 'shared production finalization was not reached'
 if capture_prior: assert 'CAPTURED PRIOR SAVE USED' in log, 'previous save was not captured from the game session'
 if gameplay_owner: assert 'GAMEPLAY OWNER COMPLETED' in log, 'unified gameplay owner was not used'
 if runtime_lock_gameplay: assert 'RUNTIME LOCK SHARED' in log and 'SESSION LOCK SURVIVED RUNTIME CLOSE' in log, 'session must retain the runtime lock through cleanup'
 assert status==0 and 'ENTRY REAL FRONTEND SAVE VERIFIED' in log, f'changed-save session failed (status {status}; log {root}/finish-cleanup/entry.log)'
 assert result[0]==(pattern[0]+1)%256 and result[1:]==pattern[1:] and result==(stage/'210.srm').read_bytes(), 'game-modified SRAM must be published byte-for-byte'
 assert not list((saved/'sessions').glob('checkpoint-*')), 'successful completion must retire the session'
 status,log,saved,stage=run('finish-cleanup',True,'finish-repeat')
 result=(saved/'battery.srm').read_bytes()
 if manager_signal: assert 'MANAGER SIGNAL RESET DISPATCHED' in log, 'the reload session must also end through the manager signal'
 if manager_screenshot: assert 'SESSION SCREENSHOT VERIFIED' in log, 'the reload session must capture a screenshot'
 if shared_finalize: assert 'SHARED SAVE FINALIZATION VERIFIED' in log, 'shared finalization was not reached in the second session'
 if capture_prior: assert 'CAPTURED PRIOR SAVE USED' in log, 'reloaded session did not capture its prior save'
 if runtime_lock_gameplay: assert 'RUNTIME LOCK SHARED' in log and 'SESSION LOCK SURVIVED RUNTIME CLOSE' in log, 'reloaded session must retain its runtime lock through cleanup'
 assert status==0 and 'ENTRY REAL FRONTEND SAVE VERIFIED' in log, f'reloaded-save session failed (status {status}; log {root}/finish-cleanup/entry.log)'
 assert result[0]==(pattern[0]+2)%256 and result[1:]==pattern[1:] and result==(stage/'210.srm').read_bytes(), 'the next session must load and increment the previously published save'
 assert not list((saved/'sessions').glob('checkpoint-*')), 'second session must retire cleanly'
 if shared_finalize:
  status,log,first,first_stage=run('shared-first-save',True,'first-save')
  assert status==0 and 'SHARED SAVE FINALIZATION VERIFIED' in log and 'ENTRY REAL FRONTEND SAVE VERIFIED' in log, 'shared finalization did not complete the first save'
  if capture_prior: assert 'CAPTURED PRIOR SAVE USED' in log, 'first-save session did not capture prior absence'
  assert (first/'battery.srm').read_bytes()==(first_stage/'210.srm').read_bytes() and not list((first/'sessions').glob('checkpoint-*')), 'first save must be published and its session retired'
 if app_homebrew_save:
  status,log,saved,stage=run('app-tamper',True,'app-tamper')
  assert status==2 and 'ROM: "' not in log and (saved/'battery.srm').read_bytes()==pattern, 'a changed app-generated ROM digest must be refused before launch'
 if app_native_homebrew_save: print('The app-generated native-artwork compatibility menu passed its host verifier and launched the homebrew ROM.')
 elif app_homebrew_save: print('The app-generated compatibility menu launched the homebrew ROM.')
 print('A homebrew SNES ROM changed SRAM in the real host emulator; the next session loaded and changed the published save again.')
 # Keep failed runs for diagnosis; a successful homebrew run has no user data.
 shutil.rmtree(root)
 sys.exit(0)
if bound_smoke:
 assert status==0 and 'ROM: "' in log and 'ENTRY REAL FRONTEND SAVE VERIFIED' in log, f'bound real-core launch failed (status {status}; log {root}/normal/entry.log)'
 reviewed=(root/'normal'/'reviewed-request').read_bytes();token=reviewed[83:99].hex()
 binding=(saved/('bind-'+token)).read_bytes()
 assert token.encode('ascii') in binding and b'\n4660\n' in binding
 assert (saved/'sessions'/('checkpoint-'+token)).is_dir()
 assert (saved/'sessions'/('checkpoint-'+token)/'manager.meta').read_bytes()[8:115]==reviewed
 assert (saved/'battery.srm').read_bytes()==(stage/'210.srm').read_bytes()
 bad_status,bad_log,bad_saved,_=run('wrong-request',True,'bound-wrong')
 assert bad_status!=0 and 'ROM: "' not in bad_log
 assert (bad_saved/'battery.srm').read_bytes()==pattern
 print('Reviewed session and epoch reached the real host frontend and matching save binding; game identity remains a fixture.')
 print('Mismatched reviewed ROM digest was refused before frontend launch; existing save was unchanged.')
 sys.exit(0)
if small_sram or size_2k or size_64k or size_128k:
 assert status==0 and 'ROM: "' in log and 'ENTRY REAL FRONTEND SAVE VERIFIED' in log
 staged=(stage/'210.srm').read_bytes();published=(saved/'battery.srm').read_bytes()
 assert len(staged)==sram_size and published==staged, 'the completed save must be published byte-for-byte'
 previous=list(saved.glob('checkpoint-*/previous'))
 assert len(previous)==1 and previous[0].read_bytes()==pattern, 'the original save must remain recoverable'
 print(f'Real-core {sram_size}-byte save copied without truncation; original retained for recovery')
 sys.exit(0)
if no_sram:
 if shared_no_sram: assert 'SHARED NO-SRAM FINALIZATION VERIFIED' in log
 if capture_prior: assert 'CAPTURED PRIOR SAVE USED' in log, 'no-SRAM path must use the session snapshot'
 if gameplay_owner: assert 'GAMEPLAY OWNER COMPLETED' in log, 'no-SRAM path must use the unified session owner'
 assert status==0 and 'ENTRY NO SRAM CLEAN' in log and (saved/'battery.srm').read_bytes()==pattern, f'no-SRAM game should finish and preserve an existing save (status {status}; log {root}/normal/entry.log)'
 status,log,cleaned,stage=run('no-sram-finish-cleanup',True)
 assert status==0 and 'ENTRY NO SRAM CLEAN' in log and not list((cleaned/'sessions').glob('checkpoint-*')) and (cleaned/'battery.srm').read_bytes()==pattern
 if runtime_lock_gameplay: assert 'RUNTIME LOCK SHARED' in log and 'SESSION LOCK SURVIVED RUNTIME CLOSE' in log
 if shared_no_sram: assert 'SHARED NO-SRAM FINALIZATION VERIFIED' in log
 if shared_no_sram:
  status,log,empty,_=run('shared-no-sram-no-prior',True,'no-battery')
  assert status==0 and 'SHARED NO-SRAM FINALIZATION VERIFIED' in log and not (empty/'battery.srm').exists(), 'no-SRAM launch must preserve the absence of a prior save'
  if capture_prior: assert 'CAPTURED PRIOR SAVE USED' in log, 'no-SRAM session did not capture prior absence'
  assert not list((empty/'sessions').glob('checkpoint-*')), 'completed no-SRAM session should retire safely'
 if no_sram_smoke:
  print('No-SRAM cleanup refused failed/timed-out shutdown and preserved the existing save.')
  sys.exit(0)
 assert not list(saved.glob('intent2-*')) and not list(saved.glob('checkpoint-*'))
 status,log,saved,stage=run('normal',True,'repeat')
 assert status==0 and 'ENTRY NO SRAM CLEAN' in log and (saved/'battery.srm').read_bytes()==pattern, 'second launch must preserve the same existing save'
 assert not list(saved.glob('intent2-*')) and not list(saved.glob('checkpoint-*'))
 status,log,saved,stage=run('no-prior-save',True,'no-battery')
 assert status==0 and 'ENTRY NO SRAM CLEAN' in log and not (saved/'battery.srm').exists()
 assert not list(saved.glob('intent2-*')) and not list(saved.glob('checkpoint-*'))
 status,log,saved,stage=run('no-sram-wrong-absence',True,'no-sram-wrong-absence')
 assert status==8 and list(saved.glob('intent2-*')), 'an unexpectedly missing prior save must retain recovery evidence'
 status,log,saved,stage=run('changed-stage',True,'tamper-stage')
 assert status==8 and (saved/'battery.srm').read_bytes()==pattern and list(saved.glob('intent2-*')), 'unexpected stage change must stop cleanup and preserve recovery evidence'
 status,log,saved,stage=run('wrong-initial',True,'wrong-initial')
 assert status==8 and (saved/'battery.srm').read_bytes()==pattern and list(saved.glob('intent2-*')), 'wrong independent snapshot must not authorize cleanup'
 status,log,saved,stage=run('alias-snapshot',True,'alias-snapshot')
 assert status==0 and 'ENTRY NO SRAM CLEAN' in log and (saved/'battery.srm').read_bytes()==pattern, f'session-owned snapshot must remain valid during cleanup (status {status}; log {root}/alias-snapshot/entry.log)'
 status,log,saved,stage=run('retry-snapshot',True,'retry-snapshot')
 assert status==0 and 'ENTRY NO SRAM CLEAN' in log and (saved/'battery.srm').read_bytes()==pattern, f'corrected snapshot should permit a safe retry (status {status}; log {root}/retry-snapshot/entry.log)'
 for mode in ('retry-partial-1','retry-partial-2'):
  status,log,saved,stage=run(mode,True,mode)
  assert status==0 and 'ENTRY NO SRAM CLEAN' in log and (saved/'battery.srm').read_bytes()==pattern, f'partial cleanup retry failed (status {status}; log {root}/{mode}/entry.log)'
 print('No-SRAM game finished with and without a previous save; prior state preserved')
 sys.exit(0)
assert status==0 and 'ROM: "' in log and 'ENTRY REAL FRONTEND SAVE VERIFIED' in log
assert (saved/'battery.srm').read_bytes()==pattern and (stage/'210.srm').read_bytes()==pattern
status,log,saved,stage=run('normal',True,'repeat')
assert status==3 and 'prepare game session: Resource busy' in log and (saved/'battery.srm').read_bytes()==pattern and list(saved.glob('intent2-*')), 'unresolved prior publication must block a second SRAM session without changing the save'
print('Second SRAM launch safely blocked by retained recovery evidence; completion remains required')
status,log,saved,stage=run('finish-cleanup',True,'finish')
assert status==0 and 'ENTRY REAL FRONTEND SAVE VERIFIED' in log and not list((saved/'sessions').glob('checkpoint-*')) and (saved/'battery.srm').read_bytes()==pattern, 'verified finished session workspace should be removed without changing its save'
status,log,saved,stage=run('finish',True,'finish')
assert status==0 and 'ENTRY REAL FRONTEND SAVE VERIFIED' in log and not list(saved.glob('intent2-*')), 'verified finalization should retire the completed intent'
status,log,saved,stage=run('finish',True,'finish-repeat')
assert status==0 and 'ENTRY REAL FRONTEND SAVE VERIFIED' in log and (saved/'battery.srm').read_bytes()==pattern and not list(saved.glob('intent2-*')), 'a finalized SRAM game should be playable again'
status,log,saved,stage=run('first-save',True,'first-save')
assert status==0 and 'ENTRY REAL FRONTEND SAVE VERIFIED' in log and (saved/'battery.srm').is_file() and not list(saved.glob('intent2-*')), 'first save should publish and retire the verified intent'
status,log,saved,stage=run('created-target',True,'created-target')
assert status==8 and (saved/'battery.srm').read_bytes()==b'new' and list(saved.glob('intent2-*')), 'newly appeared save must remain untouched'
status,log,saved,stage=run('changed-target',True,'changed-target')
assert status==8 and (saved/'battery.srm').read_bytes()==b'X'+pattern[1:] and list(saved.glob('intent2-*')), 'save changed during play must remain untouched'
status,log,saved,stage=run('wrong-absence',True,'wrong-absence')
assert status==8 and (saved/'battery.srm').read_bytes()==pattern and list(saved.glob('intent2-*')), 'captured previous save must not be replaced by an absent marker after partial cleanup'
for mode in ('wrong-current','wrong-previous'):
 status,log,saved,stage=run(mode,True,mode)
 assert status==8 and (saved/'battery.srm').read_bytes()==pattern and list(saved.glob('intent2-*')) and list(saved.glob('checkpoint-*/previous')), 'wrong snapshot must preserve save and recovery evidence'
status,log,saved,stage=run('power',True,'power')
assert status==0, 'simulated power event must complete the normal frontend exit'
status,log,saved,stage=run('power-disconnect',True,'power-disconnect')
assert status==5 and (saved/'battery.srm').read_bytes()==pattern and list(saved.glob('intent2-*')), 'lost power input must retain the prior save and recovery'
status,log,saved,stage=run('reset-disconnect',True,'reset-disconnect')
assert status==5 and (saved/'battery.srm').read_bytes()==pattern and list(saved.glob('intent2-*')), 'lost RESET input must stop the child without publishing and retain recovery'
status,log,saved,stage=run('missing-report',False)
assert status!=0 and 'ROM: "' not in log and (saved/'battery.srm').read_bytes()==pattern
status,log,saved,stage=run('conflicting-stage',True,'conflict')
assert status!=0 and 'ROM: "' not in log and (saved/'battery.srm').read_bytes()==pattern and (stage/'210.srm').read_bytes()==b'KEEP'
assert not list(saved.glob('intent2-*')) and not list(saved.glob('bind-*')), 'an invalid stage must be rejected before creating save recovery records'
status,log,saved,stage=run('wrong-game',True,'wronggame')
assert status!=0 and 'ROM: "' not in log and (saved/'battery.srm').read_bytes()==pattern
print('Host console entry to real frontend: save, missing report, conflict and identity checks passed')
print('Private fixture:',root)
